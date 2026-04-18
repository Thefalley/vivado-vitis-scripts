/*
 * crc32.c -- CRC32 IEEE 802.3 (compatible with zlib.crc32).
 *
 * Copied from P_18, unchanged.
 */
#include "eth_protocol.h"

static uint32_t crc32_table[256];

void p18_crc32_init(void)
{
    for (uint32_t i = 0; i < 256; i++) {
        uint32_t c = i;
        for (int k = 0; k < 8; k++) {
            c = (c & 1) ? (0xEDB88320u ^ (c >> 1)) : (c >> 1);
        }
        crc32_table[i] = c;
    }
}

uint32_t p18_crc32_update(uint32_t crc, const void *data, uint32_t len)
{
    const uint8_t *p = (const uint8_t *)data;
    crc = ~crc;
    while (len--) {
        crc = crc32_table[(crc ^ *p++) & 0xFF] ^ (crc >> 8);
    }
    return ~crc;
}

uint32_t p18_crc32(const void *data, uint32_t len)
{
    return p18_crc32_update(0, data, len);
}
