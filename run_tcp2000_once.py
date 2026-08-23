#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# run_tcp2000_once.py — single TCP 2000B echo attempt for ILA captures.
# Sleeps 1.5s first (guarantees the wrapper's >5ms idle auto-rezero of the
# debug frame counters), then connects, sends 2000B, prints PASS/FAIL detail.
import sys, time
sys.path.insert(0, 'D:/repo/ECO/udp_hls_eco')
import py_net_test as p

time.sleep(1.5)
ok, msg = p.tcp_echo(2000, timeout=8.0)
print("PASS" if ok else "FAIL", msg)
sys.exit(0 if ok else 1)
