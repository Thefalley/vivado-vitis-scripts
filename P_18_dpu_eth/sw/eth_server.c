/*
 * eth_server.c -- Servidor TCP bare-metal P_18 sobre lwIP.
 *
 * Corre en la ZedBoard y acepta conexiones en el puerto ETH_CTRL_PORT.
 * Parsea el protocolo binario definido en docs/ETH_PROTOCOL.md y:
 *   - Escribe/lee DDR directamente (con validacion de rango)
 *   - Lanza layers individuales via dpu_exec_*
 *   - Lanza la inferencia completa YOLOv4 via yolov4_runtime()
 *
 * Diseño: single-connection at-a-time (no concurrencia). lwIP raw API.
 *
 * Conversion endianness: Cortex-A9 y x86 ambos little-endian, no hace
 * falta htole/letoh. Solo hay que ser cuidadoso con structs packed.
 */

#include "lwip/tcp.h"
#include "lwip/err.h"
#include "lwip/pbuf.h"
#include "xil_io.h"
#include "xil_cache.h"
#include "xil_printf.h"

#include "eth_protocol.h"
#include "dpu_api.h"   /* dpu_exec_*, yolov4_runtime() para task #27 */

#include <string.h>

/* ========================================================================= */
/* Per-connection state machine                                               */
/* ========================================================================= */
typedef enum {
    ST_IDLE,           /* waiting for header */
    ST_RECV_PAYLOAD,   /* accumulating payload bytes */
    ST_SEND_RSP,       /* payload response in flight */
} eth_state_t;

/* RX buffer grande para comandos con payload (e.g. WRITE_DDR chunks de 1 MB).
 * Como lwIP puede fragmentar un comando TCP en varios pbuf, necesitamos
 * acumular hasta tener el mensaje completo ANTES de procesarlo.
 * Tamaño: 1 MB + header. Depende de heap LWIP; si no hay RAM,
 * procesamos WRITE_DDR en streaming (ver abajo streaming path). */
#define ETH_RX_CAP (1u << 20)   /* 1 MB — debe alinearse con chunk del client */

typedef struct {
    eth_state_t state;
    eth_hdr_t   hdr;
    uint32_t    hdr_got;        /* bytes del header acumulados */
    uint32_t    payload_got;    /* bytes del payload acumulados */
    /* Streaming WRITE_DDR state (sin buffer intermedio): */
    int         streaming;      /* 1 = escribiendo directo a DDR */
    uint32_t    stream_dst;     /* siguiente direccion DDR a escribir */
    uint32_t    stream_first4;  /* primeros 4 bytes del payload = addr */
    uint8_t     stream_addr_got; /* bytes del addr capturados (0..4) */
    /* Pending TX para RSP_DATA grandes (READ_DDR) */
    const uint8_t *pending_ptr;
    uint32_t       pending_len;
    /* Non-streaming path: small commands con buffer */
    uint8_t     payload[64];    /* commands pequeñitos */
} eth_conn_t;

/* Una sola conexion activa */
static eth_conn_t g_conn;

/* ========================================================================= */
/* Helpers TX                                                                 */
/* ========================================================================= */
/* Versión síncrona para headers/ACKs pequeños que siempre caben */
static err_t eth_send_raw(struct tcp_pcb *tpcb, const void *buf, uint32_t len)
{
    err_t err;
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        uint32_t snd = len;
        uint32_t avail = tcp_sndbuf(tpcb);
        if (avail == 0) {
            tcp_output(tpcb);
            return ERR_MEM;
        }
        if (snd > avail) snd = avail;
        err = tcp_write(tpcb, p, snd, TCP_WRITE_FLAG_COPY);
        if (err != ERR_OK) return err;
        p += snd;
        len -= snd;
    }
    return tcp_output(tpcb);
}

/* Versión async: si no cabe todo, deja pending en c->pending_* y continúa
 * desde on_sent() cuando lwIP libere espacio. Para READ_DDR grande. */
static err_t eth_send_raw_async(struct tcp_pcb *tpcb, eth_conn_t *c,
                                const void *buf, uint32_t len)
{
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        uint32_t avail = tcp_sndbuf(tpcb);
        if (avail == 0) {
            c->pending_ptr = p;
            c->pending_len = len;
            return tcp_output(tpcb);
        }
        uint32_t snd = (len < avail) ? len : avail;
        err_t err = tcp_write(tpcb, p, snd, TCP_WRITE_FLAG_COPY);
        if (err == ERR_MEM) {
            c->pending_ptr = p;
            c->pending_len = len;
            return tcp_output(tpcb);
        }
        if (err != ERR_OK) return err;
        p += snd;
        len -= snd;
    }
    c->pending_ptr = NULL;
    c->pending_len = 0;
    return tcp_output(tpcb);
}

static err_t eth_send_hdr(struct tcp_pcb *tpcb, uint8_t op,
                          uint16_t tag, uint32_t payload_len)
{
    eth_hdr_t h;
    h.opcode = op;
    h.flags  = 0;
    h.tag    = tag;
    h.payload_len = payload_len;
    return eth_send_raw(tpcb, &h, ETH_HDR_SIZE);
}

static err_t eth_send_ack(struct tcp_pcb *tpcb, uint16_t tag,
                          uint32_t status, const void *extra, uint32_t extra_len)
{
    uint8_t payload[64];
    if (4 + extra_len > sizeof(payload)) return ERR_MEM;
    memcpy(payload, &status, 4);
    if (extra_len > 0) memcpy(payload + 4, extra, extra_len);
    err_t e = eth_send_hdr(tpcb, RSP_ACK, tag, 4 + extra_len);
    if (e != ERR_OK) return e;
    return eth_send_raw(tpcb, payload, 4 + extra_len);
}

static err_t eth_send_error(struct tcp_pcb *tpcb, uint16_t tag,
                            uint32_t code, uint32_t aux)
{
    uint8_t payload[8];
    memcpy(payload + 0, &code, 4);
    memcpy(payload + 4, &aux,  4);
    err_t e = eth_send_hdr(tpcb, RSP_ERROR, tag, 8);
    if (e != ERR_OK) return e;
    return eth_send_raw(tpcb, payload, 8);
}

/* ========================================================================= */
/* Command dispatch                                                           */
/* ========================================================================= */
static err_t handle_cmd_ping(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    err_t e = eth_send_hdr(tpcb, RSP_PONG, c->hdr.tag, 8);
    if (e != ERR_OK) return e;
    return eth_send_raw(tpcb, "P_18 OK\0", 8);
}

/* EXEC_LAYER (real).
 *
 * Payload: u16 layer_idx, u16 flags  (4 bytes total).
 * El cliente Python ya escribió:
 *   - layer_cfg_t en DDR @ ADDR_CFG_ARRAY+idx*72 (solo direcciones relevantes)
 *   - pesos / input en sus direcciones asignadas
 *
 * El firmware es la autoridad del **tipo de capa** vía LAYERS[layer_idx]
 * (generado al cuantizar la red). El PC solo aporta las direcciones DDR.
 *
 * Despacha a dpu_exec_conv/leaky/pool/add (HW DPU) o arm_concat/upsample
 * (ARM puro), calcula CRC32 del output, responde ACK{cycles,out_crc,out_bytes}.
 */
static err_t handle_cmd_exec_layer(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    if (c->hdr.payload_len < 4)
        return eth_send_error(tpcb, c->hdr.tag, STATUS_ERR_INVALID_CMD, 0);

    uint16_t layer_idx, flags;
    memcpy(&layer_idx, c->payload + 0, 2);
    memcpy(&flags,     c->payload + 2, 2);
    (void)flags;

    if (layer_idx >= NUM_FPGA_LAYERS)
        return eth_send_error(tpcb, c->hdr.tag,
                              STATUS_ERR_INVALID_CMD, layer_idx);

    /* 1. Leer layer_cfg_t (direcciones) del PC */
    uint32_t cfg_addr = ADDR_CFG_ARRAY + layer_idx * LAYER_CFG_SIZE;
    if (!eth_addr_is_safe(cfg_addr, LAYER_CFG_SIZE))
        return eth_send_error(tpcb, c->hdr.tag,
                              STATUS_ERR_INVALID_ADDR, cfg_addr);

    Xil_DCacheInvalidateRange(cfg_addr, LAYER_CFG_SIZE);
    layer_cfg_t cfg;
    memcpy(&cfg, (const void *)(uintptr_t)cfg_addr, LAYER_CFG_SIZE);

    /* 2. L = LAYERS[] del firmware por defecto. Pero si el cfg del PC trae
     *    dimensiones distintas (h_in, w_in, c_in, c_out, h_out, w_out)
     *    override — util para test de sub-tile sin tiling ARM. */
    layer_config_t L_local = LAYERS[layer_idx];
    if (cfg.h_in != 0 && cfg.w_in != 0 && cfg.c_in != 0 && cfg.c_out != 0) {
        L_local.c_in   = cfg.c_in;
        L_local.c_out  = cfg.c_out;
        L_local.h_in   = cfg.h_in;
        L_local.w_in   = cfg.w_in;
        L_local.h_out  = cfg.h_out;
        L_local.w_out  = cfg.w_out;
        if (cfg.kh != 0)       L_local.kernel = cfg.kh;
        if (cfg.stride_h != 0) L_local.stride = cfg.stride_h;
        L_local.pad = cfg.pad_top;   /* usado por runtime; pads asim los maneja tiled */
    }
    const layer_config_t *L = &L_local;

    uint32_t out_bytes = (uint32_t)L->c_out * L->h_out * L->w_out;
    if (out_bytes == 0 || !eth_addr_is_safe(cfg.out_addr, out_bytes))
        return eth_send_error(tpcb, c->hdr.tag,
                              STATUS_ERR_INVALID_ADDR, cfg.out_addr);

    uint32_t in_bytes = (uint32_t)L->c_in * L->h_in * L->w_in;
    if (cfg.in_addr && in_bytes)
        Xil_DCacheInvalidateRange(cfg.in_addr, in_bytes);

    dpu_prof_t prof = {0};
    int rc = DPU_OK;

    /* 3. Dispatch según LAYERS[layer_idx].op_type (del runtime, no del cfg) */
    switch (L->op_type) {
    case OP_CONV:
        /* Usa la variante tiled: hace fast-path si cabe en BRAM, o strip
         * mining H+W en ARM si la layer es mas grande (todas en YOLOv4). */
        rc = dpu_exec_conv_tiled(L,
                           (const uint8_t *)(uintptr_t)cfg.in_addr,
                           (const int8_t  *)(uintptr_t)cfg.w_addr,
                           (const int32_t *)(uintptr_t)cfg.b_addr,
                           (uint8_t       *)(uintptr_t)cfg.out_addr,
                           &prof);
        break;
    case OP_LEAKY_RELU:
        rc = dpu_exec_leaky(L,
                            (const uint8_t *)(uintptr_t)cfg.in_addr,
                            (uint8_t       *)(uintptr_t)cfg.out_addr,
                            &prof);
        break;
    case OP_MAXPOOL:
        rc = dpu_exec_pool(L,
                           (const uint8_t *)(uintptr_t)cfg.in_addr,
                           (uint8_t       *)(uintptr_t)cfg.out_addr,
                           &prof);
        break;
    case OP_ADD:
        if (cfg.in_b_addr) {
            uint32_t b_bytes = in_bytes;  /* misma shape */
            Xil_DCacheInvalidateRange(cfg.in_b_addr, b_bytes);
        }
        rc = dpu_exec_add(L,
                          (const uint8_t *)(uintptr_t)cfg.in_addr,
                          (const uint8_t *)(uintptr_t)cfg.in_b_addr,
                          (uint8_t       *)(uintptr_t)cfg.out_addr,
                          &prof);
        break;
    case OP_CONCAT: {
        /* LAYERS[].c_in es canales del operando A; el B los inferimos de c_out */
        uint16_t c_a = L->c_in;
        uint16_t c_b = L->c_out - c_a;
        if (cfg.in_b_addr)
            Xil_DCacheInvalidateRange(cfg.in_b_addr,
                                      (uint32_t)c_b * L->h_in * L->w_in);
        rc = arm_concat(L,
                        (const uint8_t *)(uintptr_t)cfg.in_addr,   c_a,
                        (const uint8_t *)(uintptr_t)cfg.in_b_addr, c_b,
                        (uint8_t       *)(uintptr_t)cfg.out_addr,
                        &prof);
        break;
    }
    case OP_RESIZE:
        rc = arm_upsample(L,
                          (const uint8_t *)(uintptr_t)cfg.in_addr,
                          (uint8_t       *)(uintptr_t)cfg.out_addr,
                          &prof);
        break;
    default:
        return eth_send_error(tpcb, c->hdr.tag,
                              STATUS_ERR_INVALID_CMD, L->op_type);
    }

    /* 4. Traducir error code del runtime al protocolo */
    uint32_t status = STATUS_OK;
    if (rc != DPU_OK) {
        switch (rc) {
        case DPU_ERR_TIMEOUT:  status = STATUS_ERR_DPU_TIMEOUT;  break;
        case DPU_ERR_DM_FAULT: status = STATUS_ERR_DPU_FAULT;    break;
        case DPU_ERR_TILING:   status = STATUS_ERR_DPU_FAULT;    break;
        case DPU_ERR_PARAMS:   status = STATUS_ERR_INVALID_CMD;  break;
        default:               status = STATUS_ERR_DPU_FAULT;    break;
        }
        /* Responder error pero con 3 extras para layout consistente */
        uint32_t extra_err[3] = {prof.cycles_total, (uint32_t)rc, out_bytes};
        return eth_send_ack(tpcb, c->hdr.tag, status,
                            extra_err, sizeof(extra_err));
    }

    /* 5. CRC32 de la salida — fuera de on_recv, aquí es seguro */
    Xil_DCacheInvalidateRange(cfg.out_addr, out_bytes);
    uint32_t out_crc = p18_crc32((void *)(uintptr_t)cfg.out_addr, out_bytes);

    uint32_t extra[3] = {prof.cycles_total, out_crc, out_bytes};
    return eth_send_ack(tpcb, c->hdr.tag, status, extra, sizeof(extra));
}

static err_t handle_cmd_run_network(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    if (c->hdr.payload_len < 16)
        return eth_send_error(tpcb, c->hdr.tag, STATUS_ERR_INVALID_CMD, 0);
    uint32_t in_a, h0, h1, h2;
    memcpy(&in_a, c->payload + 0,  4);
    memcpy(&h0,   c->payload + 4,  4);
    memcpy(&h1,   c->payload + 8,  4);
    memcpy(&h2,   c->payload + 12, 4);

    /* TODO: llamar yolov4_runtime_run() que itera 255 layers */
    (void)in_a; (void)h0; (void)h1; (void)h2;

    uint32_t total_cycles = 0;
    return eth_send_ack(tpcb, c->hdr.tag, STATUS_OK, &total_cycles, 4);
}

static err_t handle_cmd_dpu_init(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    int r = dpu_init();
    uint32_t status = (r == DPU_OK) ? STATUS_OK : STATUS_ERR_DPU_FAULT;
    return eth_send_ack(tpcb, c->hdr.tag, status, NULL, 0);
}

static err_t handle_cmd_dpu_reset(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    dpu_reset();
    return eth_send_ack(tpcb, c->hdr.tag, STATUS_OK, NULL, 0);
}

/* READ_DDR: payload = u32 addr, u32 len. Response = RSP_DATA con los bytes. */
static err_t handle_cmd_read_ddr(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    if (c->hdr.payload_len < 8)
        return eth_send_error(tpcb, c->hdr.tag, STATUS_ERR_INVALID_CMD, 0);
    uint32_t addr, len;
    memcpy(&addr, c->payload + 0, 4);
    memcpy(&len,  c->payload + 4, 4);

    if (!eth_addr_is_safe(addr, len))
        return eth_send_error(tpcb, c->hdr.tag, STATUS_ERR_INVALID_ADDR, addr);

    /* Cache invalidate para ver lo escrito por DPU/DMA */
    Xil_DCacheInvalidateRange(addr, len);

    err_t e = eth_send_hdr(tpcb, RSP_DATA, c->hdr.tag, len);
    if (e != ERR_OK) return e;
    return eth_send_raw_async(tpcb, c, (const void *)(uintptr_t)addr, len);
}

/* WRITE_DDR: streaming path. El payload del command es:
 *    4 bytes addr + N bytes data  (donde N = hdr.payload_len - 4)
 * Para NO bufferizar N en RAM cuando N puede ser 1 MB, escribimos a DDR
 * directamente a medida que los bytes llegan de lwIP.
 */
static err_t eth_streaming_finalize(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    /* Flush del bloque de DDR escrito para que DMA/DPU lo vean coherentes */
    uint32_t addr = c->stream_first4;
    uint32_t len  = c->hdr.payload_len - 4;
    Xil_DCacheFlushRange(addr, len);
    return eth_send_ack(tpcb, c->hdr.tag, STATUS_OK, NULL, 0);
}

/* ========================================================================= */
/* lwIP recv callback — state machine                                         */
/* ========================================================================= */
static err_t on_recv(void *arg, struct tcp_pcb *tpcb, struct pbuf *p, err_t err)
{
    eth_conn_t *c = (eth_conn_t *)arg;

    if (p == NULL) {
        /* Peer closed */
        tcp_close(tpcb);
        c->state = ST_IDLE;
        c->hdr_got = 0;
        c->payload_got = 0;
        c->streaming = 0;
        c->stream_addr_got = 0;
        return ERR_OK;
    }
    if (err != ERR_OK) {
        pbuf_free(p);
        return err;
    }

    /* Itera sobre pbufs acumulados */
    struct pbuf *q = p;
    while (q != NULL) {
        const uint8_t *data = (const uint8_t *)q->payload;
        uint32_t left = q->len;

        while (left > 0) {
            switch (c->state) {
            case ST_IDLE: {
                /* Acumular header */
                uint32_t need = ETH_HDR_SIZE - c->hdr_got;
                uint32_t take = (left < need) ? left : need;
                memcpy(((uint8_t *)&c->hdr) + c->hdr_got, data, take);
                c->hdr_got += take;
                data += take;
                left -= take;
                if (c->hdr_got == ETH_HDR_SIZE) {
                    c->payload_got = 0;
                    c->streaming = 0;
                    c->stream_addr_got = 0;
                    if (c->hdr.payload_len == 0) {
                        /* Comandos sin payload */
                        switch (c->hdr.opcode) {
                        case CMD_PING:      handle_cmd_ping(tpcb, c); break;
                        case CMD_DPU_INIT:  handle_cmd_dpu_init(tpcb, c); break;
                        case CMD_DPU_RESET: handle_cmd_dpu_reset(tpcb, c); break;
                        case CMD_CLOSE:
                            tcp_close(tpcb);
                            pbuf_free(p);
                            return ERR_OK;
                        default:
                            eth_send_error(tpcb, c->hdr.tag,
                                           STATUS_ERR_INVALID_CMD, 0);
                        }
                        c->hdr_got = 0;
                    } else {
                        /* Si es WRITE_DDR, vamos a streaming */
                        if (c->hdr.opcode == CMD_WRITE_DDR) {
                            c->streaming = 1;
                            c->stream_addr_got = 0;
                        }
                        c->state = ST_RECV_PAYLOAD;
                    }
                }
                break;
            }

            case ST_RECV_PAYLOAD: {
                if (c->streaming) {
                    /* Los primeros 4 bytes del payload son el addr */
                    if (c->stream_addr_got < 4) {
                        uint32_t need = 4 - c->stream_addr_got;
                        uint32_t take = (left < need) ? left : need;
                        memcpy(((uint8_t *)&c->stream_first4) + c->stream_addr_got,
                               data, take);
                        c->stream_addr_got += take;
                        c->payload_got += take;
                        data += take;
                        left -= take;
                        if (c->stream_addr_got == 4) {
                            uint32_t len = c->hdr.payload_len - 4;
                            if (!eth_addr_is_safe(c->stream_first4, len)) {
                                eth_send_error(tpcb, c->hdr.tag,
                                               STATUS_ERR_INVALID_ADDR,
                                               c->stream_first4);
                                /* Abortar y continuar leyendo los bytes
                                 * restantes del payload para no desincronizar.
                                 * Aqui elegimos cerrar conexion — mas seguro. */
                                tcp_close(tpcb);
                                pbuf_free(p);
                                return ERR_OK;
                            }
                            c->stream_dst = c->stream_first4;
                        }
                    } else {
                        /* Escribir bytes directos a DDR */
                        uint32_t need = c->hdr.payload_len - c->payload_got;
                        uint32_t take = (left < need) ? left : need;
                        /* memcpy a direccion fisica */
                        memcpy((void *)(uintptr_t)c->stream_dst, data, take);
                        c->stream_dst += take;
                        c->payload_got += take;
                        data += take;
                        left -= take;
                    }
                    if (c->payload_got == c->hdr.payload_len) {
                        eth_streaming_finalize(tpcb, c);
                        c->state = ST_IDLE;
                        c->hdr_got = 0;
                        c->streaming = 0;
                    }
                } else {
                    /* Small command: bufferizar payload completo */
                    uint32_t need = c->hdr.payload_len - c->payload_got;
                    uint32_t take = (left < need) ? left : need;
                    if (c->payload_got + take > sizeof(c->payload)) {
                        eth_send_error(tpcb, c->hdr.tag,
                                       STATUS_ERR_BUFFER_OVERRUN,
                                       c->hdr.payload_len);
                        tcp_close(tpcb);
                        pbuf_free(p);
                        return ERR_OK;
                    }
                    memcpy(c->payload + c->payload_got, data, take);
                    c->payload_got += take;
                    data += take;
                    left -= take;
                    if (c->payload_got == c->hdr.payload_len) {
                        /* Dispatch */
                        switch (c->hdr.opcode) {
                        case CMD_READ_DDR:    handle_cmd_read_ddr(tpcb, c); break;
                        case CMD_EXEC_LAYER:  handle_cmd_exec_layer(tpcb, c); break;
                        case CMD_RUN_NETWORK: handle_cmd_run_network(tpcb, c); break;
                        default:
                            eth_send_error(tpcb, c->hdr.tag,
                                           STATUS_ERR_INVALID_CMD, 0);
                        }
                        c->state = ST_IDLE;
                        c->hdr_got = 0;
                    }
                }
                break;
            }

            default:
                /* unreachable */
                left = 0;
                break;
            }
        }

        q = q->next;
    }

    tcp_recved(tpcb, p->tot_len);
    pbuf_free(p);
    return ERR_OK;
}

/* Callback cuando lwIP libera espacio en el send buffer.
 * Si hay datos pendientes (READ_DDR grande), seguimos enviando. */
static err_t on_sent(void *arg, struct tcp_pcb *tpcb, u16_t len)
{
    eth_conn_t *c = (eth_conn_t *)arg;
    (void)len;
    if (c->pending_len > 0 && c->pending_ptr != NULL) {
        const uint8_t *p = c->pending_ptr;
        uint32_t rem = c->pending_len;
        c->pending_ptr = NULL;
        c->pending_len = 0;
        return eth_send_raw_async(tpcb, c, p, rem);
    }
    return ERR_OK;
}

static err_t on_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg; (void)err;
    /* Inicializa estado — una sola conexion permitida */
    memset(&g_conn, 0, sizeof(g_conn));
    g_conn.state = ST_IDLE;
    tcp_arg(newpcb, &g_conn);
    tcp_recv(newpcb, on_recv);
    tcp_sent(newpcb, on_sent);
    tcp_nagle_disable(newpcb);
    return ERR_OK;
}

/* ========================================================================= */
/* Init                                                                       */
/* ========================================================================= */
void eth_server_init(void)
{
    struct tcp_pcb *pcb = tcp_new();
    if (pcb == NULL) {
        xil_printf("eth_server: tcp_new failed\r\n");
        return;
    }
    if (tcp_bind(pcb, IP_ADDR_ANY, ETH_CTRL_PORT) != ERR_OK) {
        xil_printf("eth_server: tcp_bind %d failed\r\n", ETH_CTRL_PORT);
        return;
    }
    pcb = tcp_listen(pcb);
    tcp_accept(pcb, on_accept);
    xil_printf("eth_server: listening on port %d\r\n", ETH_CTRL_PORT);
}
