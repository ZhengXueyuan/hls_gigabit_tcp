#include <stdio.h>
#include "hls_stream.h"
struct axis_byte { unsigned char data; bool last; };
void uart_console(bool, bool, bool&, hls::stream<axis_byte>&, bool&, unsigned char&);
int main() {
    hls::stream<axis_byte> msg; bool tx, cmd_rdy; unsigned char cmd;
    for (int i=0;i<5;i++) uart_console(false, true, tx, msg, cmd_rdy, cmd);
    // Simulate network sending "DHCP:192.168.1.100\n"
    const char *s = "DHCP:192.168.1.100\n";
    for(int i=0;s[i];i++){axis_byte b;b.data=s[i];b.last=false;msg.write(b);uart_console(true,true,tx,msg,cmd_rdy,cmd);}
    // Run idle cycles for TX to drain
    for(int i=0;i<100000;i++) uart_console(true,true,tx,msg,cmd_rdy,cmd);
    printf("UART IP test OK\n");
    return 0;
}
