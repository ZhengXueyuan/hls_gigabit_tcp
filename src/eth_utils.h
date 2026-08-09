//=============================================================================
// eth_utils.h — Common utility functions for Ethernet IP stack
//=============================================================================
// CRC32 (Ethernet standard), IP/ICMP checksum, bit manipulation helpers.
//=============================================================================

#ifndef ETH_UTILS_H
#define ETH_UTILS_H

#include <stdint.h>

//=============================================================================
// Bit reverse (byte level)
//=============================================================================
static uint8_t bit_reverse(uint8_t x) {
    uint8_t r = 0;
    r |= ((x & 0x01) << 7);
    r |= ((x & 0x02) << 5);
    r |= ((x & 0x04) << 3);
    r |= ((x & 0x08) << 1);
    r |= ((x & 0x10) >> 1);
    r |= ((x & 0x20) >> 3);
    r |= ((x & 0x40) >> 5);
    r |= ((x & 0x80) >> 7);
    return r;
}

//=============================================================================
// CRC32 per byte — Ethernet standard (PKZIP/CRC-32)
//=============================================================================
// Reflected polynomial 0xEDB88320. Init=0xFFFFFFFF, no final XOR.
// Verified: CRC("123456789") = 0xCBF43926 (with final XOR ^ 0xFFFFFFFF).
//=============================================================================
static uint32_t crc32_byte(uint8_t data, uint32_t crc) {
    crc ^= data;
    for (int i = 0; i < 8; i++) {
        if (crc & 1) {
            crc = (crc >> 1) ^ 0xEDB88320;
        } else {
            crc = crc >> 1;
        }
    }
    return crc;
}

//=============================================================================
// IP/ICMP checksum — 16-bit one's complement sum over 16-bit words
//=============================================================================
// Returns the complemented sum (ready to insert into header).
// Pass an array of uint16_t words.
//=============================================================================
static uint16_t ones_complement_checksum(const uint16_t *words, int num_words) {
    uint32_t sum = 0;
    for (int i = 0; i < num_words; i++) {
        sum += words[i];
    }
    // Fold 32-bit carry into 16 bits
    while (sum >> 16) {
        sum = (sum & 0xFFFF) + (sum >> 16);
    }
    return (uint16_t)(~sum);
}

//=============================================================================
// Extract uint16_t from byte buffer (big-endian)
//=============================================================================
static inline uint16_t buf_to_u16(const uint8_t *buf, int offset) {
    return ((uint16_t)buf[offset] << 8) | buf[offset + 1];
}

//=============================================================================
// Extract uint32_t from byte buffer (big-endian)
//=============================================================================
static inline uint32_t buf_to_u32(const uint8_t *buf, int offset) {
    return ((uint32_t)buf[offset]     << 24) |
           ((uint32_t)buf[offset + 1] << 16) |
           ((uint32_t)buf[offset + 2] << 8)  |
           ((uint32_t)buf[offset + 3]);
}

//=============================================================================
// Write uint16_t to byte buffer (big-endian)
//=============================================================================
static inline void u16_to_buf(uint16_t val, uint8_t *buf, int offset) {
    buf[offset]     = (val >> 8) & 0xFF;
    buf[offset + 1] = val & 0xFF;
}

//=============================================================================
// Write uint32_t to byte buffer (big-endian)
//=============================================================================
static inline void u32_to_buf(uint32_t val, uint8_t *buf, int offset) {
    buf[offset]     = (val >> 24) & 0xFF;
    buf[offset + 1] = (val >> 16) & 0xFF;
    buf[offset + 2] = (val >> 8)  & 0xFF;
    buf[offset + 3] = val & 0xFF;
}

#endif // ETH_UTILS_H
