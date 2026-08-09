//=============================================================================
// layer_tcp.cpp — TCP Echo Server (Phase 6d — full TCP)
//=============================================================================
// MAX_TCP_CONN connections (default 3). Port 7 echo.
// TCP Reno + sliding window + adaptive RTO + MSS/Window Scale options.
//=============================================================================
#include "eth_types.h"
#include "eth_utils.h"

#ifndef MAX_TCP_CONN
#define MAX_TCP_CONN     3
#endif

#define TCP_PORT_ECHO    7
#define TCP_MSS          536
#define TCP_RTO_MIN      10000000   // ~80ms min RTO
#define TCP_RTO_MAX      80000000   // ~640ms max RTO
#define TCP_HEADER_BYTES 20
#define TCP_MAX_HDR      28   // 20 base + 8 options (MSS+WS+NOP)
#define TCP_BUF_BASE     (TX_SCRATCH_BASE + 16)
#define TCP_ALPHA_SHIFT  3   // srtt weight = 1/8
#define TCP_BETA_SHIFT   2   // rttvar weight = 1/4

#define TCP_FIN 0x01
#define TCP_SYN 0x02
#define TCP_RST 0x04
#define TCP_PSH 0x08
#define TCP_ACK 0x10

enum TCP_ST { T_FREE=0, T_LISTEN=1, T_SYN_RCVD=2, T_ESTABLISHED=3, T_LAST_ACK=4 };

struct tcp_conn_t {
    // Connection identity
    uint8_t  state;
    uint16_t peer_port;
    uint32_t peer_ip;
    uint32_t peer_window;   // advertised window (scaled)
    uint16_t peer_mss;       // peer's MSS from SYN option
    uint8_t  peer_wscale;    // peer's window scale shift
    uint8_t  our_wscale;     // our window scale shift (sends 7 for ×128)
    // Sequence tracking
    uint32_t seq;           // next byte to send
    uint32_t peer_seq;      // next byte expected from peer
    uint32_t last_ack_recv; // last ACK value (for dup detection)
    uint8_t  dup_ack_cnt;   // duplicate ACK count (fast retransmit)
    // Congestion control (Reno)
    uint32_t cwnd;          // congestion window (bytes)
    uint32_t ssthresh;      // slow start threshold
    uint32_t flight_size;   // bytes sent but unacked
    // RTT estimation (Van Jacobson — values scaled by 8)
    uint32_t srtt;          // smoothed RTT << 3
    uint32_t rttvar;        // RTT variation << 2
    uint32_t rto;           // current RTO
    uint32_t rto_timer;     // retransmission timer
    uint32_t rtt_seq;       // SEQ being timed for RTT measurement
    uint32_t rtt_start;     // timer value when timed segment was sent
    // Retransmit buffer
    uint16_t retrans_len;
    uint8_t  retrans_flags;
    bool     retrans_pending;
    // Send buffer (echo data waiting to send)
    uint8_t  send_buf[TCP_MSS];
    uint16_t send_len;      // bytes queued for sending
    uint16_t send_offset;   // next byte offset to send
};
static tcp_conn_t tcp_conn[MAX_TCP_CONN];
static uint8_t    tcp_retrans_buf[MAX_TCP_CONN][TCP_MSS];  // BRAM

//=============================================================================
// Helpers
//=============================================================================
static int8_t tcp_find(uint16_t port, uint32_t ip) {
    int8_t free=-1;
    for(int i=0;i<MAX_TCP_CONN;i++){
        #pragma HLS UNROLL
        if(tcp_conn[i].state!=T_FREE&&tcp_conn[i].peer_port==port&&tcp_conn[i].peer_ip==ip)return i;
        if(tcp_conn[i].state==T_FREE&&free<0)free=i;
    }return free;
}
static uint16_t tcp_csum(uint32_t sip, uint32_t dip, const uint8_t *d, uint16_t len){
    uint32_t s=6+len;s+=(sip>>16)&0xFFFF;s+=sip&0xFFFF;s+=(dip>>16)&0xFFFF;s+=dip&0xFFFF;
    for(int i=0;i<len-1;i+=2)s+=((uint16_t)d[i]<<8)|d[i+1];
    if(len&1)s+=((uint16_t)d[len-1]<<8);
    while(s>>16)s=(s&0xFFFF)+(s>>16);
    return(uint16_t)(~s);
}
static void tcp_build_hdr(uint8_t*b,uint16_t sp,uint16_t dp,uint32_t seq,uint32_t ack,uint8_t f,uint16_t w,bool syn){
    bool has_opts=syn;uint8_t doff=has_opts?7:5; // 20+8=28 bytes when SYN
    b[0]=(sp>>8)&0xFF;b[1]=sp&0xFF;b[2]=(dp>>8)&0xFF;b[3]=dp&0xFF;
    b[4]=(seq>>24)&0xFF;b[5]=(seq>>16)&0xFF;b[6]=(seq>>8)&0xFF;b[7]=seq&0xFF;
    b[8]=(ack>>24)&0xFF;b[9]=(ack>>16)&0xFF;b[10]=(ack>>8)&0xFF;b[11]=ack&0xFF;
    b[12]=(doff<<4);b[13]=f;b[14]=(w>>8)&0xFF;b[15]=w&0xFF;
    b[16]=0;b[17]=0;b[18]=0;b[19]=0;
    if(has_opts){
        b[20]=2;b[21]=4;b[22]=(TCP_MSS>>8)&0xFF;b[23]=TCP_MSS&0xFF; // MSS=536
        b[24]=3;b[25]=3;b[26]=7; // Window Scale = 7 (window × 128)
        b[27]=1; // NOP padding to 4-byte boundary
    }
}

//=============================================================================
// Congestion control: process ACK (updates cwnd, ssthresh per Reno)
//=============================================================================
static void tcp_reno_on_ack(tcp_conn_t &c, uint32_t new_ack, bool new_data){
    uint32_t bytes_acked = new_ack - c.last_ack_recv;  // how much was ACKed
    if(bytes_acked==0){
        // Duplicate ACK
        if(++c.dup_ack_cnt==3){
            // Fast retransmit: retransmit oldest unacked
            c.dup_ack_cnt=0;
            c.ssthresh=(c.flight_size/2>2*TCP_MSS)?c.flight_size/2:2*TCP_MSS;
            c.cwnd=c.ssthresh+3*TCP_MSS;
            // retransmit triggered in caller
            c.retrans_pending=true;c.rto_timer=0;
        }else if(c.dup_ack_cnt>3){
            c.cwnd+=TCP_MSS;  // inflate cwnd per dup ACK
        }
        return;
    }
    // New ACK — reset dup counter
    c.dup_ack_cnt=0;
    // Update flight size
    if(c.flight_size>=bytes_acked)c.flight_size-=bytes_acked;else c.flight_size=0;
    c.last_ack_recv=new_ack;
    // Congestion window update
    if(c.cwnd<c.ssthresh){
        c.cwnd+=TCP_MSS;  // slow start: exponential
        if(c.cwnd>c.ssthresh)c.cwnd=c.ssthresh;
    }else{
        c.cwnd+=(TCP_MSS*TCP_MSS)/c.cwnd;  // congestion avoidance: linear
    }
}

//=============================================================================
// RTO update (Van Jacobson)
//=============================================================================
static void tcp_update_rto(tcp_conn_t &c, uint32_t rtt_sample){
    if(c.srtt==0){
        c.srtt=rtt_sample<<TCP_ALPHA_SHIFT;
        c.rttvar=rtt_sample<<(TCP_BETA_SHIFT-1);
    }else{
        int32_t delta=rtt_sample-(c.srtt>>TCP_ALPHA_SHIFT);
        if(delta<0)delta=-delta;
        c.rttvar=(c.rttvar*c.srtt+delta*(4-1)/*/1<<TCP_BETA_SHIFT*/)/4; // simplified
        c.srtt=c.srtt-(c.srtt>>TCP_ALPHA_SHIFT)+rtt_sample;
    }
    uint32_t rto=(c.srtt>>TCP_ALPHA_SHIFT)+(c.rttvar<<(TCP_BETA_SHIFT-1));
    if(rto<TCP_RTO_MIN)rto=TCP_RTO_MIN;
    if(rto>TCP_RTO_MAX)rto=TCP_RTO_MAX;
    c.rto=rto;
}

//=============================================================================
// Send TCP segment
//=============================================================================
static void tcp_send(uint32_t *buf, mac_tx_req_t &tx_req, int8_t cid,
                     uint8_t flags, const uint8_t *payload, uint16_t pay_len){
    if(cid<0||cid>=MAX_TCP_CONN)return;
    tcp_conn_t &c=tcp_conn[cid];
    uint8_t seg[TCP_MAX_HDR+TCP_MSS];
    uint16_t total=TCP_HEADER_BYTES+pay_len;
    uint32_t sip=(BOARD_IP_BYTE0<<24)|(BOARD_IP_BYTE1<<16)|(BOARD_IP_BYTE2<<8)|BOARD_IP_BYTE3;
    tcp_build_hdr(seg,TCP_PORT_ECHO,c.peer_port,c.seq,c.peer_seq,flags,0xFFFF,(flags&TCP_SYN)&&!(flags&TCP_ACK));
    if(payload&&pay_len>0){for(int i=0;i<pay_len;i++)seg[TCP_HEADER_BYTES+i]=payload[i];}
    uint16_t cs=tcp_csum(sip,c.peer_ip,seg,total);seg[16]=(cs>>8)&0xFF;seg[17]=cs&0xFF;
    for(int i=0;i<(total+3)/4;i++){uint32_t w=((uint32_t)seg[i*4]<<24)|((uint32_t)seg[i*4+1]<<16)|((uint32_t)seg[i*4+2]<<8)|seg[i*4+3];buf[TCP_BUF_BASE+i]=w;}
    // Update SEQ and flight size
    if(pay_len>0||(flags&(TCP_SYN|TCP_FIN))){uint8_t inc=((flags&TCP_SYN)?1:0)+((flags&TCP_FIN)?1:0)+pay_len;c.seq+=inc;c.flight_size+=inc;}
    // IP header
    int ipb=TX_UDP_BASE;uint16_t ipt=20+total;uint8_t ip[20];
    ip[0]=0x45;ip[1]=0;ip[2]=(ipt>>8)&0xFF;ip[3]=ipt&0xFF;ip[4]=0;ip[5]=0;ip[6]=0x40;ip[7]=0;
    ip[8]=128;ip[9]=6;ip[10]=0;ip[11]=0;
    ip[12]=BOARD_IP_BYTE0;ip[13]=BOARD_IP_BYTE1;ip[14]=BOARD_IP_BYTE2;ip[15]=BOARD_IP_BYTE3;
    ip[16]=(c.peer_ip>>24)&0xFF;ip[17]=(c.peer_ip>>16)&0xFF;ip[18]=(c.peer_ip>>8)&0xFF;ip[19]=c.peer_ip&0xFF;
    uint16_t iw[10];for(int i=0;i<10;i++)iw[i]=((uint16_t)ip[i*2]<<8)|ip[i*2+1];
    uint16_t ic=ones_complement_checksum(iw,10);ip[10]=(ic>>8)&0xFF;ip[11]=ic&0xFF;
    for(int i=0;i<5;i++)buf[ipb+i]=((uint32_t)ip[i*4]<<24)|((uint32_t)ip[i*4+1]<<16)|((uint32_t)ip[i*4+2]<<8)|ip[i*4+3];
    for(int i=0;i<(total+3)/4;i++)buf[ipb+5+i]=buf[TCP_BUF_BASE+i];
    // Retransmit save
    if(flags&TCP_SYN){c.retrans_flags=flags;c.retrans_len=0;c.retrans_pending=true;c.rto_timer=0;}
    else if(pay_len>0){c.retrans_flags=flags;c.retrans_len=pay_len;c.retrans_pending=true;c.rto_timer=0;for(int i=0;i<pay_len;i++)tcp_retrans_buf[cid][i]=payload[i];}
    // RTT measurement
    if(pay_len>0&&c.rtt_seq==0){c.rtt_seq=c.seq-pay_len;c.rtt_start=0;/* timer reset */}
    tx_req.dst_mac=0xFFFFFFFFFFFFULL;tx_req.ethertype=ETHERTYPE_IPV4;tx_req.buf_addr=ipb;tx_req.buf_len=ipt;tx_req.request=true;
}

//=============================================================================
// Try to send queued data from send buffer (up to cwnd limit)
//=============================================================================
static void tcp_flush_send(uint32_t *buf, mac_tx_req_t &tx_req, int8_t cid){
    tcp_conn_t &c=tcp_conn[cid];
    while(c.send_len>c.send_offset){
        uint32_t allowed=(c.cwnd>c.flight_size)?(c.cwnd-c.flight_size):0;
        if(allowed<TCP_MSS)break; // can't send yet (congestion window full)
        uint16_t chunk=(c.send_len-c.send_offset>TCP_MSS)?TCP_MSS:(c.send_len-c.send_offset);
        tcp_send(buf,tx_req,cid,TCP_ACK,c.send_buf+c.send_offset,chunk);
        c.send_offset+=chunk;
        if(chunk<TCP_MSS)break;
    }
    if(c.send_offset>=c.send_len){c.send_len=0;c.send_offset=0;} // all sent
}

//=============================================================================
// TCP RX processing
//=============================================================================
static void tcp_rx_process(bool rst, ip_rx_t &ip_rx, uint32_t *buf, mac_tx_req_t &tx_req){
    #pragma HLS RESOURCE variable=tcp_retrans_buf core=RAM_2P_BRAM
    #pragma HLS RESOURCE variable=tcp_conn core=RAM_2P_BRAM
    if(!rst){for(int i=0;i<MAX_TCP_CONN;i++)tcp_conn[i].state=T_FREE;return;}
    // Retransmission + send flush scan
    if(!ip_rx.valid||ip_rx.protocol!=6){
        for(int i=0;i<MAX_TCP_CONN;i++){
            #pragma HLS UNROLL
            tcp_conn_t &c=tcp_conn[i];
            // RTO retransmission
            if(c.retrans_pending){
                c.rto_timer++;
                if(c.rto_timer>=c.rto){
                    c.rto_timer=0;
                    // Backoff: double RTO
                    c.rto*=2;if(c.rto>TCP_RTO_MAX)c.rto=TCP_RTO_MAX;
                    c.ssthresh=(c.flight_size/2>2*TCP_MSS)?c.flight_size/2:2*TCP_MSS;
                    c.cwnd=TCP_MSS; // collapse cwnd on timeout
                    c.flight_size=0;
                    c.dup_ack_cnt=0;
                    if(c.state==T_SYN_RCVD)tcp_send(buf,tx_req,i,TCP_SYN|TCP_ACK,NULL,0);
                    else if(c.state==T_ESTABLISHED&&c.retrans_len>0)tcp_send(buf,tx_req,i,TCP_ACK,tcp_retrans_buf[i],c.retrans_len);
                    else if(c.state==T_LAST_ACK)tcp_send(buf,tx_req,i,TCP_FIN|TCP_ACK,NULL,0);
                }
            }
            // Flush send buffer (congestion window may allow sending now)
            if(c.state==T_ESTABLISHED&&c.send_len>0&&!tx_req.request){
                tcp_flush_send(buf,tx_req,i);
            }
        }
        return;
    }
    // Parse TCP header
    int tb=RX_BUFFER_BASE+5;uint8_t th[20];
    for(int i=0;i<5;i++){uint32_t w=buf[tb+i];th[i*4]=(w>>24)&0xFF;th[i*4+1]=(w>>16)&0xFF;th[i*4+2]=(w>>8)&0xFF;th[i*4+3]=w&0xFF;}
    uint16_t sp=((uint16_t)th[0]<<8)|th[1],dp=((uint16_t)th[2]<<8)|th[3];
    uint32_t seq=((uint32_t)th[4]<<24)|((uint32_t)th[5]<<16)|((uint32_t)th[6]<<8)|th[7];
    uint32_t ack=((uint32_t)th[8]<<24)|((uint32_t)th[9]<<16)|((uint32_t)th[10]<<8)|th[11];
    uint8_t doff=(th[12]>>4)&0xF,flags=th[13];
    uint16_t wnd=((uint16_t)th[14]<<8)|th[15];
    uint16_t tlen=ip_rx.total_len-IP_HEADER_BYTES,plen=tlen-(doff*4);
    if(dp!=TCP_PORT_ECHO)return;
    // Read payload
    uint8_t payload[TCP_MSS];
    if(plen>0&&plen<=TCP_MSS){int ps=tb+doff;for(int i=0;i<plen;i++){uint8_t wi=ps+(i>>2),bi=i&0x3;payload[i]=(buf[wi]>>((3-bi)*8))&0xFF;}}
    int8_t cid=tcp_find(sp,ip_rx.src_ip);
    // New connection
    if(cid<0&&(flags&TCP_SYN)&&!(flags&TCP_ACK)){cid=tcp_find(0,0);if(cid<0)return;
        tcp_conn_t &c=tcp_conn[cid];c.state=T_LISTEN;c.cwnd=TCP_MSS;c.ssthresh=65535;
        c.srtt=0;c.rttvar=0;c.rto=TCP_RTO_MIN;c.dup_ack_cnt=0;c.seq=0x12345678|(cid<<20);c.peer_seq=0;c.last_ack_recv=0;c.flight_size=0;
        c.peer_mss=TCP_MSS;c.peer_wscale=0;c.our_wscale=7;
        // Parse MSS/WS options from SYN (bytes 20+ of TCP header)
        if(doff>5){uint8_t opt_end=(doff-5)*4;for(int o=0;o+1<opt_end;){
            uint8_t k=th[20+o];if(k==0)break;if(k==1){o++;continue;}
            if(o+1>=opt_end)break;uint8_t ln=th[20+o+1];if(ln<2)break;
            if(k==2&&ln>=4)c.peer_mss=((uint16_t)th[20+o+2]<<8)|th[20+o+3];
            else if(k==3&&ln>=3)c.peer_wscale=th[20+o+2];
            o+=ln;
        }}
        // Adjust cwnd to peer's MSS if smaller
        if(c.peer_mss<TCP_MSS&&c.peer_mss>0){c.cwnd=c.peer_mss;}}
    if(cid<0||cid>=MAX_TCP_CONN||tcp_conn[cid].state==T_FREE)return;
    tcp_conn_t &c=tcp_conn[cid];
    c.peer_window=(wnd>0)?(wnd<<c.peer_wscale):wnd;
    // Process ACK for congestion control
    if(flags&TCP_ACK){tcp_reno_on_ack(c,ack,false);/*ack!=c.last_ack_recv*/}
    switch(c.state){
        case T_LISTEN:if(flags&TCP_SYN){c.peer_seq=seq+1;c.peer_ip=ip_rx.src_ip;c.peer_port=sp;c.state=T_SYN_RCVD;tcp_send(buf,tx_req,cid,TCP_SYN|TCP_ACK,NULL,0);}break;
        case T_SYN_RCVD:if((flags&TCP_ACK)&&ack==c.seq){c.retrans_pending=false;c.state=T_ESTABLISHED;c.rto_timer=0;}break;
        case T_ESTABLISHED:
            c.peer_seq=seq+plen;if(flags&TCP_FIN)c.peer_seq++;
            if(plen>0){
                // Queue echo data
                for(int i=0;i<plen&&i<TCP_MSS;i++)c.send_buf[c.send_len+i]=payload[i];
                c.send_len+=plen;c.send_offset=0;
                tcp_flush_send(buf,tx_req,cid);
            }else if(flags&TCP_ACK)c.retrans_pending=false;
            if(flags&TCP_FIN){tcp_send(buf,tx_req,cid,TCP_FIN|TCP_ACK,NULL,0);c.state=T_LAST_ACK;}break;
        case T_LAST_ACK:if(flags&TCP_ACK){c.retrans_pending=false;c.state=T_FREE;}break;
    }
}
