//=============================================================================
// layer_mac.cpp — MAC (Ethernet) layer — AXI-Stream + VLAN support
//=============================================================================
// RX: hls::stream<gmii_byte_t> → parsed frame metadata + buffer payload
// TX: buffer data → hls::stream<gmii_byte_t> (preamble + MAC header + CRC)
//
// VLAN (802.1Q / 802.1ad): auto-detect TPID 0x8100/0x88A8, skip TCI bytes,
// read the real EtherType after the tag(s). Supports up to 2 tags (QinQ).
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

enum { MAC_RX_IDLE, MAC_RX_PREAMBLE, MAC_RX_HEADER, MAC_RX_VLAN, MAC_RX_PAYLOAD };
enum { MAC_TX_IDLE, MAC_TX_SEND55, MAC_TX_SENDMAC, MAC_TX_SENDDATA, MAC_TX_SENDCRC };

//=============================================================================
// MAC RX — parse incoming GMII stream, write payload to buffer
//=============================================================================
static void mac_rx_process(
    bool                      reset_n,
    hls::stream<gmii_byte_t> &rx_stream,
    hls::stream<uint32_t>    &frame_fifo,   // out: frame payload words (race-free)
    mac_rx_t                 &rx
) {
    static uint8_t  state        = MAC_RX_IDLE;
    static uint8_t  byte_cnt     = 0;
    static uint64_t dst_mac_acc  = 0;
    static uint64_t src_mac_acc  = 0;
    static uint16_t eth_acc      = 0;    // EtherType accumulator
    static ap_uint<16> saved_ethertype = 0;
    static mac_addr_t  saved_dst_mac   = 0;
    static mac_addr_t  saved_src_mac   = 0;
    static uint32_t wr_word      = 0;
    static uint8_t  wr_byte      = 0;
    static ap_uint<10> nwords    = 0;    // words pushed this frame
    static uint8_t  vlan_hdr_rem = 0;    // remaining VLAN tag bytes to skip

    rx.valid        = false;
    rx.ethertype    = 0;
    rx.src_mac      = 0;
    rx.dst_mac      = 0;
    rx.is_broadcast = false;
    rx.is_unicast   = false;
    rx.buf_base     = 0;
    rx.nwords       = 0;

    if (!reset_n) {
        state         = MAC_RX_IDLE;
        byte_cnt      = 0;
        dst_mac_acc   = 0;
        src_mac_acc   = 0;
        eth_acc       = 0;
        saved_ethertype = 0;
        saved_dst_mac   = 0;
        saved_src_mac   = 0;
        wr_word       = 0;
        wr_byte       = 0;
        nwords        = 0;
        vlan_hdr_rem  = 0;
        return;
    }

    // Check if stream has data
    if (rx_stream.empty()) return;

    gmii_byte_t rx_byte = rx_stream.read();
    uint8_t data = rx_byte.data;
    bool    last = rx_byte.last;

    switch (state) {
        case MAC_RX_IDLE:
            byte_cnt     = 0;
            dst_mac_acc  = 0;
            src_mac_acc  = 0;
            eth_acc      = 0;
            wr_word      = 0;
            wr_byte      = 0;
            nwords       = 0;
            vlan_hdr_rem = 0;
            if (data == 0x55) { state = MAC_RX_PREAMBLE; byte_cnt = 1; }
            break;

        case MAC_RX_PREAMBLE:
            byte_cnt++;
            if (data == 0xD5 && byte_cnt >= 8) { state = MAC_RX_HEADER; byte_cnt = 0; }
            else if (data != 0x55 && byte_cnt < 7) { state = MAC_RX_IDLE; }
            break;

        case MAC_RX_HEADER:
            if (byte_cnt < 6) {
                dst_mac_acc = (dst_mac_acc << 8) | data;
            } else if (byte_cnt < 12) {
                src_mac_acc = (src_mac_acc << 8) | data;
            } else if (byte_cnt == 12) {
                eth_acc = ((uint16_t)data) << 8;
            } else if (byte_cnt == 13) {
                eth_acc |= data;
                // Check for VLAN tag
                uint16_t tpid = eth_acc;
                if (tpid == TPID_VLAN || tpid == TPID_QINQ) {
                    state    = MAC_RX_VLAN;
                    byte_cnt = 0;
                    vlan_hdr_rem = 2;  // skip 2-byte TCI
                    break;
                }
                // No VLAN — normal flow
                saved_dst_mac   = (mac_addr_t)dst_mac_acc;
                saved_src_mac   = (mac_addr_t)src_mac_acc;
                saved_ethertype = eth_acc;
                rx.is_broadcast = (saved_dst_mac == 0xFFFFFFFFFFFFULL);
                rx.is_unicast   = (saved_dst_mac == 0x000A3501FEC0ULL);
                if (rx.is_unicast || rx.is_broadcast) {
                    state    = MAC_RX_PAYLOAD;
                    byte_cnt = 0;
                } else {
                    state = MAC_RX_IDLE;
                }
            }
            byte_cnt++;
            break;

        case MAC_RX_VLAN:
            // Skip TCI bytes, then read next TPID or real EtherType
            vlan_hdr_rem--;
            if (vlan_hdr_rem == 0) {
                // Just consumed 2-byte TCI. The next 2 bytes are the
                // real EtherType (or another VLAN TPID for QinQ)
                state    = MAC_RX_HEADER;
                byte_cnt = 12;  // re-enter EtherType parsing
                eth_acc  = 0;
            }
            break;

        case MAC_RX_PAYLOAD:
            // Accumulate into 32-bit word, push to the frame FIFO. The FIFO
            // decouples producer (here) from consumer (protocol layers) with a
            // proper handshake — this is the race-free replacement for the old
            // shared buffer[] (UG1399: never share a raw array between
            // concurrent producer/consumer). Deep enough to hold a max frame.
            {
                wr_word = (wr_word << 8) | data;
                wr_byte++;
                if (wr_byte == 4) {
                    frame_fifo.write(wr_word);
                    nwords++;
                    wr_byte = 0;
                    wr_word = 0;
                }

                if (last) {
                    // End of frame — flush partial word
                    if (wr_byte > 0) {
                        frame_fifo.write(wr_word << ((4 - wr_byte) * 8));
                        nwords++;
                    }
                    rx.ethertype = saved_ethertype;
                    rx.dst_mac   = saved_dst_mac;
                    rx.src_mac   = saved_src_mac;
                    rx.valid     = true;
                    rx.nwords    = nwords;
                    state = MAC_RX_IDLE;
                }
            }
            break;

        default:
            state = MAC_RX_IDLE;
            break;
    }
}

//=============================================================================
// MAC TX — read buffer, assemble frame, write to AXI-Stream
//=============================================================================
static void mac_tx_process(
    bool                      reset_n,
    mac_tx_req_t             &tx_req,
    uint32_t                 *buffer,
    hls::stream<gmii_byte_t> &tx_stream,
    bool                     &tx_busy        // out: MAC is (or is about to
                                             // be) reading the shared buffer
) {
    static uint8_t  state         = MAC_TX_IDLE;
    static uint8_t  byte_cnt      = 0;
    static uint16_t sent_bytes    = 0;
    static uint32_t crc_reg       = 0xFFFFFFFF;
    static mac_addr_t  dst_mac    = 0;
    static ap_uint<16> ethertype  = 0;
    static ap_uint<10> req_wbase  = 0;
    static ap_uint<16> req_bytes  = 0;
    static bool        do_vlan    = false;
    static ap_uint<16> vlan_tci   = 0;

    // FIX 2026-08-18: frame builders (UDP/TCP write the TX buffer while the
    // MAC may be streaming a frame from it). Expose "MAC busy" so builders
    // only touch the buffer when no frame is being sent/queued.
    tx_busy = (state != MAC_TX_IDLE) || tx_req.request;

    if (!reset_n) {
        state      = MAC_TX_IDLE;
        byte_cnt   = 0;
        sent_bytes = 0;
        crc_reg    = 0xFFFFFFFF;
        tx_req.request = false;
        tx_busy    = false;
        return;
    }

    switch (state) {
        case MAC_TX_IDLE:
            crc_reg = 0xFFFFFFFF;
            if (tx_req.request) {
                dst_mac    = tx_req.dst_mac;
                ethertype  = tx_req.ethertype;
                req_wbase  = tx_req.buf_addr;
                req_bytes  = tx_req.buf_len;
                do_vlan    = tx_req.insert_vlan;
                vlan_tci   = tx_req.vlan_tci;
                sent_bytes = 0;
                tx_req.request = false;
                state     = MAC_TX_SEND55;
                byte_cnt  = 0;
            }
            break;

        case MAC_TX_SEND55:
            {
                static const uint8_t preamble[8] = {
                    0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0x55, 0xD5
                };
                gmii_byte_t b; b.data = preamble[byte_cnt]; b.last = false;
                tx_stream.write(b);
                byte_cnt++;
                if (byte_cnt == 8) { byte_cnt = 0; state = MAC_TX_SENDMAC; }
            }
            break;

        case MAC_TX_SENDMAC:
            {
                static const uint8_t src_mac[6] = {
                    BOARD_MAC_BYTE0, BOARD_MAC_BYTE1, BOARD_MAC_BYTE2,
                    BOARD_MAC_BYTE3, BOARD_MAC_BYTE4, BOARD_MAC_BYTE5
                };
                uint8_t hdr_total = do_vlan ? 18 : 14;  // 14 + 4 VLAN tag
                uint8_t bd;

                if (byte_cnt < 6) {
                    bd = (uint8_t)((dst_mac >> ((5 - byte_cnt) * 8)) & 0xFF);
                } else if (byte_cnt < 12) {
                    bd = src_mac[byte_cnt - 6];
                } else if (do_vlan && byte_cnt < 16) {
                    // Insert 4-byte VLAN tag: TPID(2) + TCI(2)
                    uint8_t vlan_pos = byte_cnt - 12;
                    if (vlan_pos == 0)      bd = (TPID_VLAN >> 8) & 0xFF;
                    else if (vlan_pos == 1) bd = TPID_VLAN & 0xFF;
                    else if (vlan_pos == 2) bd = (vlan_tci >> 8) & 0xFF;
                    else                    bd = vlan_tci & 0xFF;
                } else if ((do_vlan && byte_cnt == 16) || (!do_vlan && byte_cnt == 12)) {
                    bd = (ethertype >> 8) & 0xFF;
                } else {
                    bd = ethertype & 0xFF;
                }

                gmii_byte_t b; b.data = bd; b.last = false;
                tx_stream.write(b);
                crc_reg = crc32_byte(bd, crc_reg);
                byte_cnt++;
                if (byte_cnt == hdr_total) { byte_cnt = 0; state = MAC_TX_SENDDATA; }
            }
            break;

        case MAC_TX_SENDDATA:
            {
                uint8_t bd;
                if (sent_bytes < req_bytes) {
                    uint16_t word_idx = req_wbase + (sent_bytes >> 2);
                    uint8_t  byte_off = sent_bytes & 0x3;
                    uint32_t w = buffer[word_idx];
                    bd = (w >> ((3 - byte_off) * 8)) & 0xFF;
                } else {
                    bd = 0;  // zero-pad: 46-byte min payload for a 64-byte frame
                }

                gmii_byte_t b; b.data = bd; b.last = false;
                tx_stream.write(b);
                crc_reg = crc32_byte(bd, crc_reg);   // pad bytes ARE part of the frame
                sent_bytes++;
                uint16_t tx_payload = (req_bytes < 46) ? (uint16_t)46 : (uint16_t)req_bytes;
                if (sent_bytes == tx_payload) { byte_cnt = 0; state = MAC_TX_SENDCRC; }
            }
            break;

        case MAC_TX_SENDCRC:
            {
                uint32_t fcs = crc_reg ^ 0xFFFFFFFF;
                uint8_t bd;
                // FIX 2026-08-18: FCS bytes LSB-first (byte0 = fcs[7:0]) to
                // match this board's PHY/PC chain (k720 demo emits CA A3 F9 63;
                // MSB-first FCS is silently dropped by the PC NIC).
                if (byte_cnt == 0)      bd = fcs & 0xFF;
                else if (byte_cnt == 1) bd = (fcs >> 8) & 0xFF;
                else if (byte_cnt == 2) bd = (fcs >> 16) & 0xFF;
                else                    bd = (fcs >> 24) & 0xFF;

                bool is_last = (byte_cnt == 3);
                gmii_byte_t b; b.data = bd; b.last = is_last;
                tx_stream.write(b);
                byte_cnt++;
                if (byte_cnt == 4) { byte_cnt = 0; state = MAC_TX_IDLE; }
            }
            break;

        default:
            state = MAC_TX_IDLE;
            break;
    }
}
