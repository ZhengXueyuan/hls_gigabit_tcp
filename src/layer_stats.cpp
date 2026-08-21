//=============================================================================
// layer_stats.cpp — Packet statistics + periodic status dump
//=============================================================================
#include "eth_types.h"

static uint32_t rx_pkt=0, tx_pkt=0, rx_byte=0, tx_byte=0;
static uint32_t arp_rx=0, icmp_rx=0, dhcp_ev=0, igmp_rx=0;
static uint32_t timer=0;
static bool     dhcp_flag=false;
static uint32_t dhcp_ip=0;
static bool     force_arp=false;

void stats_force_arp_dump() { force_arp=true; }
bool stats_should_dump()   { return force_arp; }

static void stats_event(uint8_t ev, uint16_t len) {
    if(ev==0){rx_pkt++;rx_byte+=len;}else if(ev==1){tx_pkt++;tx_byte+=len;}
    else if(ev==2)arp_rx++;else if(ev==3)icmp_rx++;
    else if(ev==4)dhcp_ev++;else if(ev==5)igmp_rx++;
}
static void stats_dhcp_done(uint32_t ip){dhcp_flag=true;dhcp_ip=ip;}

void arp_dump(hls::stream<gmii_byte_t>&msg);

static void stats_report(bool rst, hls::stream<gmii_byte_t>&msg, bool do_arp, uint16_t buf39_err){
    if(!rst){rx_pkt=tx_pkt=rx_byte=tx_byte=arp_rx=icmp_rx=dhcp_ev=igmp_rx=timer=0;dhcp_flag=false;return;}
    timer++; if(timer<100000000 && !dhcp_flag && !do_arp) return; timer=0;
    auto e=[&](char c){gmii_byte_t b;b.data=c;b.last=false;if(!msg.full())msg.write(b);};
    auto pd=[&](uint32_t v){char b[12];int p=0;if(v==0){e('0');return;}while(v){b[p++]='0'+(v%10);v/=10;}while(p)e(b[--p]);};
    if(dhcp_flag){dhcp_flag=false;e('D');e('H');e('C');e('P');e(':');uint32_t ip=dhcp_ip;
        for(int i=24;i>=0;i-=8){uint8_t b=(ip>>i)&0xFF;if(b>99){e('0'+b/100);b%=100;}if(b>9){e('0'+b/10);b%=10;}e('0'+b);if(i>0)e('.');}e('\n');}
    e('R');e('X');e(':');pd(rx_pkt);e('p');e('k');e('t');e(' ');pd(rx_byte);e('B');
    e(' ');e('T');e('X');e(':');pd(tx_pkt);e('p');e('k');e(' ');pd(tx_byte);e('B');
    e(' ');e('A');e(':');pd(arp_rx);e(' ');e('I');e(':');pd(icmp_rx);
    e(' ');e('G');e(':');pd(igmp_rx);e(' ');e('D');e(':');pd(dhcp_ev);
    e(' ');e('3');e('9');e(':');pd(buf39_err);e('\n');
    if(do_arp||arp_rx>0){e('A');e('R');e('P');e(':');e('\n');arp_dump(msg);}
    force_arp=false;
}
