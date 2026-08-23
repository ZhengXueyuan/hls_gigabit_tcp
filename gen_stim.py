#!/usr/bin/env python3
# gen_stim.py — 生成 xsim TB 刺激 (复现板级 2000B = 536*3+392 背靠背 TCP 突发)
# 输出 stim.memh: 每行 "<last> <data_hex>", 供 tb_udp_echo.v $fscanf 读取
BOARD_MAC = [0x00,0x0A,0x35,0x01,0xFE,0xC0]
SRC_MAC   = [0x10,0x11,0x12,0x13,0x14,0x15]
SRC_IP    = [192,168,100,100]
DST_IP    = [192,168,100,2]
SPORT     = 0x3039
DPORT     = 7

def ip_csum(hdr):
    # hdr: list of 20 bytes, csum field (bytes 10,11) = 0
    s = 0
    for i in range(0,20,2):
        s += (hdr[i]<<8)|hdr[i+1]
    while s>>16: s = (s&0xFFFF)+(s>>16)
    return (~s)&0xFFFF

def build_frame(tcp_flags, seq, ack, payload):
    # Ethernet preamble + MAC + IPv4 + TCP (+payload). 无 FCS (RX不看), last 在最后字节.
    b = [0x55]*7 + [0xD5]
    b += BOARD_MAC + SRC_MAC + [0x08,0x00]
    ihl = 20; tot = ihl + 20 + len(payload)
    ip = [0x45,0x00,(tot>>8)&0xFF,tot&0xFF, 0x00,0x4a, 0x40,0x00, 64,6, 0,0]
    ip += SRC_IP + DST_IP
    c = ip_csum(ip); ip[10]=(c>>8)&0xFF; ip[11]=c&0xFF
    b += ip
    tcp = [(SPORT>>8)&0xFF,SPORT&0xFF,(DPORT>>8)&0xFF,DPORT&0xFF]
    tcp += [(seq>>24)&0xFF,(seq>>16)&0xFF,(seq>>8)&0xFF,seq&0xFF]
    tcp += [(ack>>24)&0xFF,(ack>>16)&0xFF,(ack>>8)&0xFF,ack&0xFF]
    tcp += [0x50, tcp_flags, 0x20,0x00, 0,0, 0,0]   # doff=5, win=0x2000, csum=0, urg=0
    b += tcp
    b += payload
    return b

def emit(frames):
    lines = []
    for fr in frames:
        for i,byte in enumerate(fr):
            last = 1 if i==len(fr)-1 else 0
            lines.append(f"{last} {byte:02x}")
    return lines

frames = []
# 1) SYN (客户端 ISN=0x10000000)
frames.append(build_frame(0x02, 0x10000000, 0, []))
# 2) ACK (三次握手完成, ack=0x12345679 = FPGA 建立后 seq)
frames.append(build_frame(0x10, 0x10000001, 0x12345679, []))
# 3-6) 4 个数据段 536,536,536,392, payload = (global_off+i)&0xFF
lens = [536,536,536,392]
cseq = 0x10000001
ackv = 0x12345679   # 客户端对 FPGA 回显的确认, 随回显递增
sent = 0
for L in lens:
    payload = [(sent+i)&0xFF for i in range(L)]
    frames.append(build_frame(0x18, cseq, ackv, payload))
    cseq += L
    ackv += L        # 假设 FPGA 回显了上一段 (536), ack 跟进
    sent += L
# 7) 收尾纯 ACK (确认全部 2000B 回显, 促使尾包发出)
frames.append(build_frame(0x10, cseq, 0x12345679+2000, []))

lines = emit(frames)
with open("stim.memh","w") as f:
    f.write("\n".join(lines)+"\n")
total_bytes = sum(len(fr) for fr in frames)
print(f"frames={len(frames)} total_feed_bytes={total_bytes} lines={len(lines)}")
for i,fr in enumerate(frames):
    print(f"  frame{i}: {len(fr)} bytes")
