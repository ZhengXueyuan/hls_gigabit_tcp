#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# analyze_pkt.py — parse pktmon text dump, extract TCP frames FPGA<->PC
import sys, re

path = sys.argv[1] if len(sys.argv) > 1 else "pk_tcp_race.txt"
with open(path, "r", encoding="utf-16") as f:
    lines = f.read().splitlines()
print(f"Total lines: {len(lines)}")

frame_count = 0
pc_count = 0
for i, ln in enumerate(lines):
    if re.search(r'192\.168\.100\.2\.7 > 192\.168\.100\.1', ln):
        frame_count += 1
        if frame_count <= 12:
            print(f"FPGA#{frame_count} L{i}: {ln[:250]}")
    elif re.search(r'192\.168\.100\.1\.\d+ > 192\.168\.100\.2', ln):
        pc_count += 1
        if pc_count <= 8:
            print(f"PC#{pc_count} L{i}: {ln[:250]}")
print(f"FPGA frames: {frame_count}  PC frames: {pc_count}")
