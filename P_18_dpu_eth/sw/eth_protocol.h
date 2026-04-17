/*
 * eth_protocol.h -- Constantes compartidas del protocolo TCP P_18.
 *
 * Este header existe en C (ARM) y tiene espejo en Python (yolov4_host.py).
 * Mantener sincronizados los opcodes / status codes.
 */
#ifndef ETH_PROTOCOL_H
#define ETH_PROTOCOL_H

#include <stdint.h>

/* Puerto TCP bulk (el echo server de P_400 sigue en puerto 7) */
#define ETH_CTRL_PORT         7001

/* Commands PC -> board */
#define CMD_PING              0x01
#define CMD_WRITE_DDR         0x02
#define CMD_READ_DDR          0x03
#define CMD_EXEC_LAYER        0x04
#define CMD_RUN_NETWORK       0x05
#define CMD_DPU_INIT          0x06
#define CMD_DPU_RESET         0x07
#define CMD_CLOSE             0xFF

/* Responses board -> PC */
#define RSP_PONG              0x81
#define RSP_ACK               0x82
#define RSP_DATA              0x83
#define RSP_ERROR             0x8E

/* Status codes (dentro del payload de ACK) */
#define STATUS_OK                 0x00000000u
#define STATUS_ERR_INVALID_CMD    0x00000001u
#define STATUS_ERR_INVALID_ADDR   0x00000002u
#define STATUS_ERR_DPU_TIMEOUT    0x00000003u
#define STATUS_ERR_DPU_FAULT      0x00000004u
#define STATUS_ERR_BUFFER_OVERRUN 0x00000005u

/* Header 8 bytes: little-endian */
typedef struct __attribute__((packed)) {
    uint8_t  opcode;
    uint8_t  flags;
    uint16_t tag;
    uint32_t payload_len;
} eth_hdr_t;

#define ETH_HDR_SIZE 8

/* Safety: DDR windows permitidas para write/read. Cualquier addr fuera de
 * estos ranges retorna STATUS_ERR_INVALID_ADDR.
 */
#define DDR_SAFE_LO_1  0x10000000u  /* buffers DPU + mailbox */
#define DDR_SAFE_HI_1  0x10FFFFFFu
#define DDR_SAFE_LO_2  0x11000000u  /* activation pool + weights + heads */
#define DDR_SAFE_HI_2  0x1FFFFFFFu

static inline int eth_addr_is_safe(uint32_t addr, uint32_t len)
{
    uint32_t hi = addr + len - 1;
    if (len == 0) return 0;
    if (hi < addr) return 0; /* overflow */
    if (addr >= DDR_SAFE_LO_1 && hi <= DDR_SAFE_HI_1) return 1;
    if (addr >= DDR_SAFE_LO_2 && hi <= DDR_SAFE_HI_2) return 1;
    return 0;
}

/* ============================================================================
 * Extensión V0+: layer_cfg_t + EXEC_LAYER real.
 * NO se añade CRC en el on_recv callback (eso rompió V1).
 * El cliente pone el cfg en DDR via WRITE_DDR antes de EXEC_LAYER.
 * ========================================================================= */

/* OpType — prefijo PRO_ para no chocar con layer_configs.h del runtime v0 */
#define PRO_OP_CONV      0
#define PRO_OP_LEAKY     1
#define PRO_OP_POOL_MAX  2
#define PRO_OP_ELEM_ADD  3
#define PRO_OP_CONCAT    4
#define PRO_OP_RESIZE    5

#define PRO_ACT_NONE     0
#define PRO_ACT_LEAKY    1

/* Direcciones acordadas del mapa de memoria (espejo de p18eth/proto.py).
 * El cliente Python es la autoridad; estas macros solo ayudan. */
#define ADDR_INPUT         0x10000000u
#define ADDR_MAILBOX       0x10100000u
#define ADDR_CFG_ARRAY     0x11000000u
#define ADDR_WEIGHTS_BASE  0x12000000u
#define ADDR_ACTIV_POOL    0x16000000u

/* layer_cfg_t (72 bytes). Sincronizado con p18eth/proto.py */
typedef struct __attribute__((packed)) {
    uint8_t  op_type;
    uint8_t  act_type;
    uint16_t layer_idx;
    uint32_t in_addr;
    uint32_t in_b_addr;
    uint32_t out_addr;
    uint32_t w_addr;
    uint32_t b_addr;
    uint16_t c_in;
    uint16_t c_out;
    uint16_t h_in;
    uint16_t w_in;
    uint16_t h_out;
    uint16_t w_out;
    uint8_t  kh;
    uint8_t  kw;
    uint8_t  stride_h;
    uint8_t  stride_w;
    uint8_t  pad_top;
    uint8_t  pad_bottom;
    uint8_t  pad_left;
    uint8_t  pad_right;
    uint8_t  ic_tile_size;
    uint8_t  post_shift;
    int16_t  leaky_alpha_q;
    int32_t  a_scale_m;
    int32_t  b_scale_m;
    int8_t   a_scale_s;
    int8_t   b_scale_s;
    int8_t   out_zp;
    int8_t   out_scale_s;
    uint32_t reserved0;
    uint32_t reserved1;
    uint32_t reserved2;
} layer_cfg_t;

#define LAYER_CFG_SIZE 72
_Static_assert(sizeof(layer_cfg_t) == 72, "layer_cfg_t must be 72 bytes");

#define N_LAYERS_MAX 255

/* CRC32 IEEE 802.3 (mismo que zlib.crc32) — tabla estática inicializada
 * al arrancar main(). NO llamar desde on_recv con payloads grandes. */
uint32_t p18_crc32(const void *data, uint32_t len);
uint32_t p18_crc32_update(uint32_t crc, const void *data, uint32_t len);
void     p18_crc32_init(void);   /* llamar UNA VEZ al arrancar, no lazy */

#endif /* ETH_PROTOCOL_H */
