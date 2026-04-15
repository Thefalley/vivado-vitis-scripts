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

#endif /* ETH_PROTOCOL_H */
