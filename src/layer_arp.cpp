//=============================================================================
// layer_arp.cpp — ARP with L1 cache (8-entry LRU) + L2 BRAM (256-entry)
//=============================================================================
// L1:  8 entries, fully unrolled, 1-cycle lookup, LRU replacement
// L2: 256 entries in BRAM, sequential scan (256 cycles worst case)
//
// Flow:
//   Lookup:  L1 hit  → return MAC (1 cycle)
//            L1 miss → scan L2 → L2 hit → promote to L1 (LRU eviction)
//   Update:  write L1, if full → evict LRU victim to L2
//=============================================================================

#include "eth_types.h"
#include "eth_utils.h"

#define L1_SIZE   8                          // L1 cache entries
#define L2_SIZE   256                        // L2 BRAM entries
#define L1_AGE_BITS 3                        // ceil(log2(8))

//=============================================================================
// L2 BRAM table (256 entries) — pragma applied in arp_rx_process via top-level
//=============================================================================
static arp_entry_t l2_table[L2_SIZE];

//=============================================================================
// L1 cache entry (fully unrolled, LUT-based)
//=============================================================================
static arp_entry_t l1_cache[L1_SIZE];
static ap_uint<L1_AGE_BITS> l1_age[L1_SIZE];  // 0=newest, 7=oldest

//=============================================================================
// Update LRU ages: accessed entry → age=0, all others → age++, max→evict
//=============================================================================
static void l1_lru_touch(int idx) {
    ap_uint<L1_AGE_BITS> old_age = l1_age[idx];
    for (int i = 0; i < L1_SIZE; i++) {
        #pragma HLS UNROLL
        if (i == idx) {
            l1_age[i] = 0;
        } else if (l1_age[i] <= old_age) {
            l1_age[i] = l1_age[i] + 1;   // age older entries
        }
    }
}

//=============================================================================
// L1 lookup: fully unrolled parallel compare (1 cycle)
//=============================================================================
static bool l1_lookup(ap_uint<32> ip, mac_addr_t &mac) {
    for (int i = 0; i < L1_SIZE; i++) {
        #pragma HLS UNROLL
        if (l1_cache[i].valid && l1_cache[i].ip == ip) {
            mac = l1_cache[i].mac;
            l1_lru_touch(i);
            return true;
        }
    }
    return false;
}

//=============================================================================
// L1 insert: write new entry. If full, evict LRU (max age) to L2.
//=============================================================================
static void l1_insert(ap_uint<32> ip, mac_addr_t mac) {
    // Find victim: highest age (oldest)
    ap_uint<L1_AGE_BITS> max_age = 0;
    int victim = 0;
    for (int i = 0; i < L1_SIZE; i++) {
        #pragma HLS UNROLL
        if (!l1_cache[i].valid) { victim = i; goto found; }
        if (l1_age[i] >= max_age) { max_age = l1_age[i]; victim = i; }
    }
    found:
    // Write-back victim to L2 (find a slot in L2)
    if (l1_cache[victim].valid) {
        for (int i = 0; i < L2_SIZE; i++) {
            if (!l2_table[i].valid) {
                l2_table[i] = l1_cache[victim];
                break;
            }
        }
    }
    // Insert new entry in L1
    l1_cache[victim].ip    = ip;
    l1_cache[victim].mac   = mac;
    l1_cache[victim].valid = true;
    l1_lru_touch(victim);
}

//=============================================================================
// Full lookup: L1 → (miss) L2 scan → (hit) promote to L1
//=============================================================================
bool arp_lookup(arp_entry_t *table_unused, ap_uint<32> ip, mac_addr_t &mac) {
    #pragma HLS RESOURCE variable=l2_table core=RAM_2P_BRAM
    // Quick L1 check
    if (l1_lookup(ip, mac)) return true;

    // L2 scan (sequential, BRAM access)
    for (int i = 0; i < L2_SIZE; i++) {
        // unrolled for BRAM access pattern
        if (l2_table[i].valid && l2_table[i].ip == ip) {
            mac = l2_table[i].mac;
            l1_insert(ip, mac);   // promote to L1
            return true;
        }
    }
    return false;
}

//=============================================================================
// ARP update: write to L1, LRU evicts to L2. Also called for learning.
//=============================================================================
static void arp_update(arp_entry_t *table_unused, ap_uint<32> ip, mac_addr_t mac) {
    // Check if already in L1 → refresh
    for (int i = 0; i < L1_SIZE; i++) {
        #pragma HLS UNROLL
        if (l1_cache[i].valid && l1_cache[i].ip == ip) {
            l1_cache[i].mac = mac;
            l1_lru_touch(i);
            return;
        }
    }
    // Not in L1 → insert (may evict to L2)
    l1_insert(ip, mac);
}

//=============================================================================
// ARP Request sender (unchanged — builds ARP Request frame)
//=============================================================================
static void arp_send_request(uint32_t* buf, mac_tx_req_t& tx_req, ap_uint<32> ip) {
    uint8_t req[28];
    req[0]=0x00;req[1]=0x01; req[2]=0x08;req[3]=0x00; req[4]=6;req[5]=4;
    req[6]=0x00;req[7]=0x01;
    req[8]=BOARD_MAC_BYTE0;req[9]=BOARD_MAC_BYTE1;req[10]=BOARD_MAC_BYTE2;
    req[11]=BOARD_MAC_BYTE3;req[12]=BOARD_MAC_BYTE4;req[13]=BOARD_MAC_BYTE5;
    req[14]=BOARD_IP_BYTE0;req[15]=BOARD_IP_BYTE1;req[16]=BOARD_IP_BYTE2;req[17]=BOARD_IP_BYTE3;
    req[18]=0;req[19]=0;req[20]=0;req[21]=0;req[22]=0;req[23]=0;
    req[24]=(ip>>24)&0xFF;req[25]=(ip>>16)&0xFF;req[26]=(ip>>8)&0xFF;req[27]=ip&0xFF;
    for(int i=0;i<7;i++){
        buf[TX_SCRATCH_BASE+i]=((uint32_t)req[i*4]<<24)|((uint32_t)req[i*4+1]<<16)|((uint32_t)req[i*4+2]<<8)|req[i*4+3];
    }
    tx_req.dst_mac=0xFFFFFFFFFFFFULL;tx_req.ethertype=ETHERTYPE_ARP;
    tx_req.buf_addr=TX_SCRATCH_BASE;tx_req.buf_len=ARP_PAYLOAD_BYTES;tx_req.request=true;
}

//=============================================================================
// ARP RX processing — Reply handling + learning
//=============================================================================
static void arp_rx_process(
    bool reset_n, mac_rx_t& mac_rx, uint32_t* buffer,
    mac_tx_req_t& tx_req, arp_entry_t *arp_table
) {
    if (!reset_n) {
        for (int i = 0; i < L1_SIZE; i++) {
            #pragma HLS UNROLL
            l1_cache[i].valid = false;
            l1_age[i] = 0;
        }
        for (int i = 0; i < L2_SIZE; i++) { l2_table[i].valid = false; }
        return;
    }
    if (!mac_rx.valid || mac_rx.ethertype != ETHERTYPE_ARP) return;

    uint8_t arp_bytes[28];
    for (int i = 0; i < 7; i++) {
        uint32_t w = frame_buf[i];   // staged frame (0-based); ARP body = 7 words
        arp_bytes[i*4]=(w>>24)&0xFF;arp_bytes[i*4+1]=(w>>16)&0xFF;
        arp_bytes[i*4+2]=(w>>8)&0xFF;arp_bytes[i*4+3]=w&0xFF;
    }

    uint16_t opcode = ((uint16_t)arp_bytes[6]<<8)|arp_bytes[7];
    mac_addr_t sender_mac = 0;
    for(int i=0;i<6;i++) sender_mac=(sender_mac<<8)|arp_bytes[8+i];
    uint32_t sender_ip = ((uint32_t)arp_bytes[14]<<24)|((uint32_t)arp_bytes[15]<<16)|
                         ((uint32_t)arp_bytes[16]<<8)|arp_bytes[17];
    uint32_t target_ip = ((uint32_t)arp_bytes[24]<<24)|((uint32_t)arp_bytes[25]<<16)|
                         ((uint32_t)arp_bytes[26]<<8)|arp_bytes[27];

    arp_update(arp_table, sender_ip, sender_mac);

    uint32_t board_ip = (BOARD_IP_BYTE0<<24)|(BOARD_IP_BYTE1<<16)|(BOARD_IP_BYTE2<<8)|BOARD_IP_BYTE3;
    if (opcode == ARP_REQUEST && target_ip == board_ip) {
        uint8_t reply[28];
        reply[0]=0x00;reply[1]=0x01;reply[2]=0x08;reply[3]=0x00;reply[4]=6;reply[5]=4;
        reply[6]=0x00;reply[7]=0x02;
        reply[8]=BOARD_MAC_BYTE0;reply[9]=BOARD_MAC_BYTE1;reply[10]=BOARD_MAC_BYTE2;
        reply[11]=BOARD_MAC_BYTE3;reply[12]=BOARD_MAC_BYTE4;reply[13]=BOARD_MAC_BYTE5;
        reply[14]=BOARD_IP_BYTE0;reply[15]=BOARD_IP_BYTE1;reply[16]=BOARD_IP_BYTE2;reply[17]=BOARD_IP_BYTE3;
        reply[18]=arp_bytes[8];reply[19]=arp_bytes[9];reply[20]=arp_bytes[10];
        reply[21]=arp_bytes[11];reply[22]=arp_bytes[12];reply[23]=arp_bytes[13];
        reply[24]=arp_bytes[14];reply[25]=arp_bytes[15];reply[26]=arp_bytes[16];reply[27]=arp_bytes[17];
        for(int i=0;i<7;i++){
            buffer[TX_SCRATCH_BASE+i]=((uint32_t)reply[i*4]<<24)|((uint32_t)reply[i*4+1]<<16)|((uint32_t)reply[i*4+2]<<8)|reply[i*4+3];
        }
        tx_req.dst_mac=sender_mac;tx_req.ethertype=ETHERTYPE_ARP;
        tx_req.buf_addr=TX_SCRATCH_BASE;tx_req.buf_len=ARP_PAYLOAD_BYTES;tx_req.request=true;
    }
}

// ARP dump to msg stream (for UART ?arp command)
static void arp_dump(hls::stream<gmii_byte_t> &msg) {
    auto e=[&](char c){gmii_byte_t b;b.data=c;b.last=false;if(!msg.full())msg.write(b);};
    auto ph=[&](uint8_t v){char h[]="0123456789ABCDEF";e(h[v>>4]);e(h[v&0xF]);};
    auto pi=[&](uint32_t ip){for(int i=24;i>=0;i-=8){uint8_t b=(ip>>i)&0xFF;if(b>99){e('0'+b/100);b%=100;}if(b>9){e('0'+b/10);b%=10;}e('0'+b);if(i>0)e('.');}};
    int cnt=0;
    for(int i=0;i<L1_SIZE;i++) if(l1_cache[i].valid){
        e(' '); pi(l1_cache[i].ip); e(' ');e('-');e('>');e(' ');
        for(int j=5;j>=0;j--){ph((l1_cache[i].mac>>(j*8))&0xFF);if(j>0)e(':');}
        e('\n'); cnt++;
    }
    if(cnt==0){e('(');e('e');e('m');e('p');e('t');e('y');e(')');e('\n');}
}
