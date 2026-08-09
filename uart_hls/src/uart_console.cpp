//=============================================================================
// uart_console.cpp — Enhanced UART Console IP (50MHz)
//=============================================================================
// Commands: ?help ?mac ?ip ?dhcp ?arp ?stat
// Features: echo, backspace, DHCP cache, ARP/stat data from network IP
//=============================================================================
#include <stdint.h>
#include "ap_int.h"
#include "hls_stream.h"

#define UART_DIV   13020   // 125MHz / 9600
#define UART_HALF  6510
#define TX_SZ      512
#define RX_SZ      64
#define CMD_LEN     48

struct axis_byte { ap_uint<8> data; bool last; };
enum { U_IDLE, U_START, U_DATA, U_STOP };

static uint8_t  tx_buf[TX_SZ];
static uint16_t tx_wr=0, tx_rd=0;
static uint8_t  rx_buf[RX_SZ];
static uint8_t  rx_wr=0, rx_rd=0;
static uint8_t  cmd[CMD_LEN], cmd_len=0;
static uint32_t cached_ip=0; static bool ip_ok=false;
static uint8_t  rst=U_IDLE, tst=U_IDLE;
static uint16_t rdiv=0, tdiv=0;
static uint8_t  rbit=0, tbit=0, rsh=0, tsh=0;
static bool     rprev=true;
static uint8_t  ln_buf[256]; static uint16_t ln_idx=0; // line buffer for network data

// --- FIFO helpers ---
static void pc(char c){uint16_t n=(tx_wr+1)&(TX_SZ-1);if(n!=tx_rd){tx_buf[tx_wr]=(uint8_t)c;tx_wr=n;}}
static void ps(const char*s){while(*s)pc(*s++);}
static void ph(uint8_t v){char h[]="0123456789ABCDEF";pc(h[v>>4]);pc(h[v&0xF]);}
static void pip(uint32_t ip){for(int i=24;i>=0;i-=8){uint8_t b=(ip>>i)&0xFF;if(b>99)pc('0'+b/100);if(b>9)pc('0'+b/10);pc('0'+b);if(i>0)pc('.');}}
static bool sm(const uint8_t*a,const char*b,int l){for(int i=0;i<l;i++){if(a[i]!=(uint8_t)b[i])return false;if(a[i]==0)return true;}return b[l]==0;}
static void pline(){ // flush line buffer to TX
    for(uint16_t i=0;i<ln_idx;i++)pc(ln_buf[i]);
    ln_idx=0;
}

// --- UART RX ---
static void rx_p(bool rst_n,bool rx){
    if(!rst_n){rst=U_IDLE;rdiv=0;rx_wr=0;rx_rd=0;rprev=true;return;}
    switch(rst){
        case U_IDLE: if(!rx&&rprev){rst=U_START;rdiv=0;}rprev=rx;break;
        case U_START: if(rdiv<UART_HALF+(UART_DIV>>2))rdiv++;else{if(!rx){rst=U_DATA;rdiv=0;rbit=0;rsh=0;}else rst=U_IDLE;}break;
        case U_DATA: if(++rdiv>=UART_DIV){rdiv=0;if(rx)rsh|=(1<<rbit);if(++rbit==8){rst=U_STOP;rdiv=0;}}break;
        case U_STOP: if(++rdiv>=UART_DIV){rdiv=0;uint8_t n=(rx_wr+1)&(RX_SZ-1);if(n!=rx_rd){rx_buf[rx_wr]=rsh;rx_wr=n;}rst=U_IDLE;}break;
    }
}

// --- UART TX ---
static void tx_p(bool rst_n,bool&txd){
    if(!rst_n){tst=U_IDLE;tdiv=0;txd=true;return;}txd=true;
    switch(tst){
        case U_IDLE: if(tx_rd!=tx_wr){tsh=tx_buf[tx_rd];tx_rd=(tx_rd+1)&(TX_SZ-1);tst=U_START;tdiv=0;tbit=0;}break;
        case U_START: txd=false;if(++tdiv>=UART_DIV){tdiv=0;tst=U_DATA;}break;
        case U_DATA: txd=(tsh>>tbit)&1;if(++tdiv>=UART_DIV){tdiv=0;if(++tbit==8){tst=U_STOP;tdiv=0;}}break;
        case U_STOP: txd=true;if(++tdiv>=UART_DIV){tdiv=0;tst=U_IDLE;}break;
    }
}

// --- Command processor ---
static void cmd_p(){
    while(rx_rd!=rx_wr){
        uint8_t c=rx_buf[rx_rd];rx_rd=(rx_rd+1)&(RX_SZ-1);
        // Echo
        if(c>=32&&c<127)pc(c); else if(c=='\n'){pc('\r');pc('\n');}
        // Process
        if(c=='\b'||c==127){if(cmd_len>0)cmd_len--;}  // BS/DEL
        else if(c=='\n'||c=='\r'){cmd[cmd_len]=0;
            if(cmd_len>0){
                if(sm(cmd,"?help",cmd_len))    {ps("\r\n=== Cmds ===\r\n?help ?mac ?ip ?dhcp ?arp ?stat\r\n");}
                else if(sm(cmd,"?mac",cmd_len)){ps("\r\nMAC: 00:0A:35:01:FE:C0\r\n");}
                else if(sm(cmd,"?ip",cmd_len)) {ps("\r\nIP: ");if(ip_ok)pip(cached_ip);else ps("192.168.0.2");ps("\r\n");}
                else if(sm(cmd,"?dhcp",cmd_len)){ps("\r\nDHCP: ");if(ip_ok){pip(cached_ip);}else ps("pending");ps("\r\n");}
                else if(sm(cmd,"?arp",cmd_len)) {ps("\r\nARP:\r\n");pline();}  // network IP sends ARP data
                else if(sm(cmd,"?stat",cmd_len)){ps("\r\nStats:\r\n");pline();}
                else {ps("\r\n?: ");ps((const char*)cmd);ps("\r\n");}
                cmd_len=0;
            }
        }else if(c>=32&&cmd_len<CMD_LEN-1) cmd[cmd_len++]=c;
    }
}

// --- Top-level ---
void uart_console(bool rst_n,bool rx,bool&tx,hls::stream<axis_byte>&msg,bool&crdy,uint8_t&cb){
    #pragma HLS INTERFACE ap_none port=rst_n
    #pragma HLS INTERFACE ap_none port=rx
    #pragma HLS INTERFACE ap_none port=tx
    #pragma HLS INTERFACE axis port=msg
    #pragma HLS INTERFACE ap_none port=crdy
    #pragma HLS INTERFACE ap_none port=cb
    #pragma HLS INTERFACE ap_ctrl_none port=return
    #pragma HLS RESOURCE variable=tx_buf core=RAM_2P_BRAM
    #pragma HLS RESOURCE variable=rx_buf core=RAM_2P_BRAM

    rx_p(rst_n,rx); tx_p(rst_n,tx); cmd_p();

    // Read network messages
    if(!msg.empty()){
        axis_byte b=msg.read();
        // Lines starting with 'A' (ARP dump) or 'R' (stats) → buffer, then flush on '\n'
        if(b.data=='\n'){ln_buf[ln_idx++]='\n';if(ln_buf[0]=='D'){pline();}else{pline();} ln_idx=0;}
        else if(ln_idx<255)ln_buf[ln_idx++]=b.data;
        // Parse DHCP
        if(b.data=='\n'){
            if(ln_buf[0]=='D'&&ln_buf[1]=='H'&&ln_buf[2]=='C'&&ln_buf[3]=='P'&&ln_buf[4]==':'){
                uint32_t ip=0;int d=0;uint8_t v=0;
                for(int i=5;ln_buf[i]!='\n'&&ln_buf[i]!=0;i++){
                    if(ln_buf[i]=='.'){ip=(ip<<8)|v;v=0;d++;}else if(ln_buf[i]>='0'&&ln_buf[i]<='9')v=v*10+(ln_buf[i]-'0');
                }
                ip=(ip<<8)|v;if(d==3){cached_ip=ip;ip_ok=true;}
            }
        }
    }
    crdy=false;
}
