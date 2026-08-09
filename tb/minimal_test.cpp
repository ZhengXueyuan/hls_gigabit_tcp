#include <stdio.h>
#include "hls_stream.h"
#include "../src/eth_types.h"
void udp_echo(bool, hls::stream<gmii_byte_t>&, hls::stream<gmii_byte_t>&);
int main() {
    hls::stream<gmii_byte_t> rx, tx;
    for(int i=0;i<5;i++) udp_echo(false, rx, tx);  // reset
    gmii_byte_t b; while(!tx.empty()) tx.read(b);    // drain any reset output
    
    // Run exactly enough to trigger UDP default TX (~257 cycles)
    for(int i=0;i<260;i++){
        udp_echo(true, rx, tx);
        while(!tx.empty()) tx.read(b);  // drain to prevent overflow
    }
    
    // Now run capture without draining
    uint8_t buf[512]; int n=0;
    for(int cyc=0;cyc<3000;cyc++){
        udp_echo(true, rx, tx);
        while(!tx.empty() && n<500){
            gmii_byte_t bb = tx.read();
            buf[n++] = bb.data;
            if(bb.last) goto done;
        }
    }
    done:
    printf("Captured %d bytes: ", n);
    for(int i=0;i<(n<20?n:20);i++) printf("%02X ",buf[i]);
    printf("\nPreamble: %s\n", (n>0&&buf[0]==0x55)?"OK":"FAIL");
    return (n>0&&buf[0]==0x55)?0:1;
}
