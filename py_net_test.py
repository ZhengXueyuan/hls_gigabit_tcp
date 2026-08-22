#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# py_net_test.py — ECO 板 udp_hls_eco 协议栈板级验证 (Python 版, 替代 tcp_bulk_test.ps1 等)
# 板: 192.168.100.2  PC NIC: 192.168.100.1
# UDP echo :8080, TCP echo :7
import socket, sys, time

BOARD = "192.168.100.2"
PC    = "192.168.100.1"
UDP_PORT = 8080
TCP_PORT = 7
PATTERN = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

def gen(n):
    return (PATTERN * (n // len(PATTERN) + 1))[:n]

def udp_echo(nbytes, timeout=3.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.bind((PC, 0))
    s.settimeout(timeout)
    data = gen(nbytes)
    try:
        s.sendto(data, (BOARD, UDP_PORT))
        t0 = time.time()
        rx, _ = s.recvfrom(65535)
        dt = (time.time() - t0) * 1000
        if rx == data:
            return True, f"OK {nbytes}B echoed in {dt:.1f}ms"
        # find first mismatch
        m = next((i for i in range(min(len(rx), len(data))) if rx[i] != data[i]), min(len(rx), len(data)))
        return False, f"MISMATCH len={len(rx)}/{len(data)} first_diff@{m} rx={rx[m:m+8].hex()} exp={data[m:m+8].hex()}"
    except socket.timeout:
        return False, f"TIMEOUT ({timeout}s) no echo"
    finally:
        s.close()

def tcp_echo(nbytes, timeout=8.0):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind((PC, 0))
    s.settimeout(timeout)
    data = gen(nbytes)
    try:
        s.connect((BOARD, TCP_PORT))
        s.sendall(data)
        rx = b""
        t0 = time.time()
        while len(rx) < nbytes:
            chunk = s.recv(65535)
            if not chunk:
                break
            rx += chunk
            if time.time() - t0 > timeout:
                break
        dt = (time.time() - t0) * 1000
        if rx == data:
            return True, f"OK {nbytes}B echoed in {dt:.1f}ms"
        m = next((i for i in range(min(len(rx), len(data))) if rx[i] != data[i]), min(len(rx), len(data)))
        ctx = f"len={len(rx)}/{nbytes} first_diff@{m}"
        if m < len(rx) and m < len(data):
            ctx += f" rx={rx[m:m+8].hex()} exp={data[m:m+8].hex()}"
        return False, f"MISMATCH {ctx}"
    except socket.timeout:
        return False, f"TIMEOUT ({timeout}s)"
    except ConnectionRefusedError:
        return False, "CONN REFUSED (port 7 not listening)"
    except Exception as e:
        return False, f"ERROR {e}"
    finally:
        s.close()

def main():
    print(f"== ECO udp_hls_eco 板级验证  board={BOARD} pc={PC} ==")
    results = []
    # UDP
    ok, msg = udp_echo(64)
    print(f"[UDP  64B ] {'PASS' if ok else 'FAIL'}  {msg}"); results.append(("UDP64", ok))
    ok, msg = udp_echo(512)
    print(f"[UDP 512B ] {'PASS' if ok else 'FAIL'}  {msg}"); results.append(("UDP512", ok))
    # TCP small
    ok, msg = tcp_echo(25)
    print(f"[TCP  25B ] {'PASS' if ok else 'FAIL'}  {msg}"); results.append(("TCP25", ok))
    # TCP 1608
    ok, msg = tcp_echo(1608)
    print(f"[TCP 1608B] {'PASS' if ok else 'FAIL'}  {msg}"); results.append(("TCP1608", ok))
    # TCP 2000 x3
    for i in range(3):
        ok, msg = tcp_echo(2000)
        print(f"[TCP 2000B #{i+1}] {'PASS' if ok else 'FAIL'}  {msg}")
        results.append((f"TCP2000#{i+1}", ok))
        time.sleep(0.3)
    npass = sum(1 for _, ok in results if ok)
    print(f"== 结果: {npass}/{len(results)} PASS ==")
    sys.exit(0 if npass == len(results) else 1)

if __name__ == "__main__":
    main()
