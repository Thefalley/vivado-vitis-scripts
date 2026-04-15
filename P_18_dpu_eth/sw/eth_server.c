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
    /* Non-streaming path: small commands con buffer */
    uint8_t     payload[64];    /* commands pequeñitos */
} eth_conn_t;

/* Una sola conexion activa */
static eth_conn_t g_conn;

/* ========================================================================= */
/* Helpers TX                                                                 */
/* ========================================================================= */
static err_t eth_send_raw(struct tcp_pcb *tpcb, const void *buf, uint32_t len)
{
    err_t err;
    const uint8_t *p = (const uint8_t *)buf;
    while (len > 0) {
        uint32_t snd = len;
        uint32_t avail = tcp_sndbuf(tpcb);
        if (avail == 0) {
            tcp_output(tpcb);
            return ERR_MEM;  /* caller should retry */
        }
        if (snd > avail) snd = avail;
        err = tcp_write(tpcb, p, snd, TCP_WRITE_FLAG_COPY);
        if (err != ERR_OK) return err;
        p += snd;
        len -= snd;
    }
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

static err_t handle_cmd_exec_layer(struct tcp_pcb *tpcb, eth_conn_t *c)
{
    /* payload: u32 layer_idx, u32 in_addr, u32 out_addr,
                u32 w_addr, u32 b_addr, u32 in_b_addr */
    if (c->hdr.payload_len < 24)
        return eth_send_error(tpcb, c->hdr.tag, STATUS_ERR_INVALID_CMD, 0);
    uint32_t layer_idx, in_a, out_a, w_a, b_a, in_b;
    memcpy(&layer_idx, c->payload + 0,  4);
    memcpy(&in_a,      c->payload + 4,  4);
    memcpy(&out_a,     c->payload + 8,  4);
    memcpy(&w_a,       c->payload + 12, 4);
    memcpy(&b_a,       c->payload + 16, 4);
    memcpy(&in_b,      c->payload + 20, 4);

    /* TODO: llamar dpu_exec_* segun LAYERS[layer_idx].op_type */
    (void)layer_idx; (void)in_a; (void)out_a; (void)w_a; (void)b_a; (void)in_b;

    uint32_t cycles = 0;
    return eth_send_ack(tpcb, c->hdr.tag, STATUS_OK, &cycles, 4);
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
    return eth_send_raw(tpcb, (const void *)(uintptr_t)addr, len);
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

static err_t on_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    (void)arg; (void)err;
    /* Inicializa estado — una sola conexion permitida */
    memset(&g_conn, 0, sizeof(g_conn));
    g_conn.state = ST_IDLE;
    tcp_arg(newpcb, &g_conn);
    tcp_recv(newpcb, on_recv);
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
