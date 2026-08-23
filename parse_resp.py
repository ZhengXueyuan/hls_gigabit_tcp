#!/usr/bin/env python3
# parse_resp.py — 解析 xsim 的 resp.memh, 重组 TCP echo payload, 检查错位
# resp.memh 每行 "<last> <data_hex>" (last=1 表示帧末)
import sys

RESP = r"D:\repo\ECO\udp_hls_eco\xsim_run\resp.memh"

def load_frames(path):
    frames = []
    cur = []
    with open(path) as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            parts = line.split()
            if len(parts) != 2:
                continue
            last, data = int(parts[0]), int(parts[1], 16)
            cur.append(data)
            if last:
                frames.append(cur)
                cur = []
    if cur:
        frames.append(cur)
    return frames

def strip_preamble(frame):
    # 去掉 7*0x55 + 0xD5
    i = 0
    while i < len(frame) and frame[i] == 0x55:
        i += 1
    if i < len(frame) and frame[i] == 0xD5:
        i += 1
    return frame[i:]

def parse_frame(frame):
    """返回 (src_port, dst_port, seq, ack, flags, payload)
    payload 长度按 IP tot_len 截, 忽略帧尾 FCS (DUT 在 tx_stream 里附带 4B FCS,
    板上 wrapper 会剥掉, xsim 直连时会被误算进 payload)。"""
    f = strip_preamble(frame)
    if len(f) < 14 + 20 + 20:
        return None
    eth_type = (f[12] << 8) | f[13]
    if eth_type != 0x0800:
        return None
    ip = f[14:]
    ihl = (ip[0] & 0x0F) * 4
    tot_len = (ip[2] << 8) | ip[3]
    proto = ip[9]
    if proto != 6:
        return None
    tcp = ip[ihl:]
    sport = (tcp[0] << 8) | tcp[1]
    dport = (tcp[2] << 8) | tcp[3]
    seq = (tcp[4] << 24) | (tcp[5] << 16) | (tcp[6] << 8) | tcp[7]
    ack = (tcp[8] << 24) | (tcp[9] << 16) | (tcp[10] << 8) | tcp[11]
    doff = (tcp[12] >> 4) * 4
    flags = tcp[13]
    # payload 长度 = IP tot_len - ihl - doff (不含 FCS)
    plen = tot_len - ihl - doff
    payload = tcp[doff:doff + plen]
    return (sport, dport, seq, ack, flags, payload)

frames = load_frames(RESP)
print(f"total TX bytes = {sum(len(f) for f in frames)}")
print(f"total frames = {len(frames)}")

echo_stream = []  # 所有回显 payload 字节按序拼接
for i, fr in enumerate(frames):
    p = parse_frame(fr)
    if p is None:
        print(f"frame{i}: len={len(fr)} (not TCP/IPv4)")
        continue
    sport, dport, seq, ack, flags, payload = p
    is_syn = bool(flags & 0x02)
    print(f"frame{i}: len={len(fr)} sport={sport} dport={dport} seq=0x{seq:08x} ack=0x{ack:08x} flags=0x{flags:02x} payload_len={len(payload)}{' [SYN]' if is_syn else ''}")
    if payload and not is_syn:
        echo_stream.extend(payload)

# 板上期待: echo payload 第 i 字节 = i & 0xFF (gen_stim 里 payload = (global_off+i)&0xFF)
print(f"\ntotal echo payload bytes = {len(echo_stream)}")
mismatches = []
for i, b in enumerate(echo_stream):
    expected = i & 0xFF
    if b != expected:
        mismatches.append((i, b, expected))

if not mismatches:
    print("ALL echo payload bytes MATCH expected (i & 0xFF). NO misalignment.")
else:
    print(f"MISMATCH count = {len(mismatches)}")
    # 显示前 20 个错位
    for i, got, exp in mismatches[:20]:
        print(f"  offset {i}: got 0x{got:02x} expected 0x{exp:02x}")
    # 显示错位区间
    offs = [m[0] for m in mismatches]
    print(f"mismatch offset range: {min(offs)} .. {max(offs)}")
    # 上下文: 第一个错位前后 16 字节
    first = min(offs)
    lo = max(0, first - 16)
    hi = min(len(echo_stream), first + 16)
    print(f"context around first mismatch (offset {first}):")
    print(f"  got:      {' '.join(f'{b:02x}' for b in echo_stream[lo:hi])}")
    print(f"  expected: {' '.join(f'{(j & 0xFF):02x}' for j in range(lo, hi))}")
