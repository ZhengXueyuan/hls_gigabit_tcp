#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ila_analyze2.py — parse write_hw_ila_data CSV (probe-name columns, radix row)
import csv, sys

FSM = {1 << i: f"s{i+1}" for i in range(33)}
PATTERN = b"ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"

def H(v):
    v = v.strip()
    if v == "": return 0
    try: return int(v, 16)
    except ValueError: return 0

def main(path, dump_detail=False):
    with open(path, newline='') as f:
        rows = list(csv.reader(f))
    hdr = rows[0]
    idx = {name.split('[')[0]: i for i, name in enumerate(hdr)}
    data = []
    for r in rows[2:]:                      # skip header + radix rows
        if len(r) < len(hdr): continue
        g = lambda n: H(r[idx[n]])
        ctrl = g('dbg_ctrl'); wire = g('dbg_wire')
        data.append(dict(
            smp=g('Sample in Buffer'), trig=g('TRIGGER'),
            wa=g('dbg_tsb_addr1'), ra=g('dbg_tsb_addr0'),
            wd=g('dbg_tsb_d1'), rd=g('dbg_tsb_q0'),
            qlen=g('dbg_q_len'), qoff=g('dbg_q_off'), fsm=g('dbg_fsm'),
            ce0=(ctrl >> 15) & 1, ce1=(ctrl >> 14) & 1, we1=(ctrl >> 13) & 1,
            txreq=(ctrl >> 12) & 1, macbusy=(ctrl >> 11) & 1,
            tcprx_s=(ctrl >> 10) & 1, tcprx_d=(ctrl >> 9) & 1,
            send_s=(ctrl >> 8) & 1, send_d=(ctrl >> 7) & 1,
            mactx_s=(ctrl >> 6) & 1, mactx_d=(ctrl >> 5) & 1,
            ff_wr=(ctrl >> 4) & 1, cid=ctrl & 7,
            rxs=g('net_rx_data'), txs=g('net_tx_data'),
            rxfc=g('dbg_rx_fcnt'), txfc=g('dbg_tx_fcnt'),
            rxdv=(wire >> 7) & 1, txen=(wire >> 6) & 1,
            rxv=(wire >> 5) & 1, rxr=(wire >> 4) & 1,
            txv=(wire >> 3) & 1, txr=(wire >> 2) & 1,
            occ=g('rx_occ')))
    st = lambda f: FSM.get(f, f"?{f:x}")
    trig = next((i for i, e in enumerate(data) if e['trig']), -1)
    print(f"samples={len(data)} trigger@{trig}")
    print(f"occ range: min={min(e['occ'] for e in data)} max={max(e['occ'] for e in data)}")

    # ---- wire RX frames (e_rxdv spans) ----
    print("\n== wire RX frames (rxdv spans) ==")
    i = 0
    while i < len(data):
        if data[i]['rxdv']:
            j = i
            while j < len(data) and data[j]['rxdv']: j += 1
            print(f"  [{i}..{j-1}] len={j-i}cy ({(j-i)*8}ns)")
            i = j
        else: i += 1

    # ---- DUT rx_stream consumed bytes (rxv & rxr), show frames with last ----
    print("\n== DUT rx_stream beats (valid&ready) — frame spans & first/last bytes ==")
    beats = [(i, e) for i, e in enumerate(data) if e['rxv'] and e['rxr']]
    frames, cur = [], []
    for i, e in beats:
        cur.append((i, e['rxs'] & 0xff))
        if e['rxs'] & 0x100:
            frames.append(cur); cur = []
    if cur: frames.append(cur)   # unterminated tail
    for f in frames:
        b = bytes(x[1] for x in f)
        print(f"  [{f[0][0]}..{f[-1][0]}] {len(b)}B last={'Y' if data[f[-1][0]]['rxs']&0x100 else 'N'} "
              f"head={b[:12].hex()} tail={b[-8:].hex()}")
        # pattern check: does payload look like a splice? find pattern jumps
        # locate 45 00 (IP header start) after eth header
        ip = b.find(b'\x45\x00')
        if ip >= 0 and len(b) > ip + 24:
            iplen = (b[ip+2] << 8) | b[ip+3]
            proto = b[ip+9]
            pay = b[ip+20+ (20 if proto==6 else 0):]  # assume no TCP opts
            exp = bytes(PATTERN[(x) % 36] for x in range(len(pay)))
            # try align pay to pattern at every base
            base = next((k for k in range(36) if pay[:16] == bytes(PATTERN[(k+x) % 36] for x in range(min(16,len(pay))))), None)
            note = f"iplen={iplen} proto={proto} pay={len(pay)}B pat_base={base}"
            # detect splice: scan for pattern discontinuity
            if base is not None:
                for x in range(1, len(pay)):
                    if pay[x] != PATTERN[(base + x) % 36]:
                        note += f" SPLICE@pay{x} got={pay[x]:02x} exp={PATTERN[(base+x)%36]:02x}"
                        break
            print(f"      {note}")

    # ---- queue write bursts ----
    print("\n== tcp_send_bufs write bursts (we1&ce1) ==")
    bursts, cur = [], None
    for i, e in enumerate(data):
        if e['we1'] and e['ce1']:
            if cur is None: cur = [i, i, e['wa'], e['wa'], []]
            cur[1] = i; cur[3] = e['wa']; cur[4].append(e['wd'])
        else:
            if cur: bursts.append(cur); cur = None
    if cur: bursts.append(cur)
    for b in bursts:
        wds = bytes(b[4])
        print(f"  [{b[0]}..{b[1]}] addr {b[2]}..{b[3]} ({len(b[4])} writes) "
              f"first12={wds[:12].hex()} last8={wds[-8:].hex()}")
        # pattern alignment of written payload
        base = next((k for k in range(36) if wds[:16] == bytes(PATTERN[(k+x) % 36] for x in range(min(16, len(wds))))), None)
        if base is not None:
            splice = next((x for x in range(1, len(wds)) if wds[x] != PATTERN[(base+x) % 36]), None)
            print(f"      pattern base={base} splice_at={splice}")

    # ---- queue read bursts ----
    print("\n== tcp_send_bufs read bursts (ce0) ==")
    rbs, cur = [], None
    for i, e in enumerate(data):
        if e['ce0']:
            if cur is None: cur = [i, i, e['ra'], e['ra'], []]
            cur[1] = i; cur[3] = e['ra']; cur[4].append(e['rd'])
        else:
            if cur: rbs.append(cur); cur = None
    if cur: rbs.append(cur)
    for b in rbs:
        rds = bytes(b[4])
        print(f"  [{b[0]}..{b[1]}] addr {b[2]}..{b[3]} ({len(b[4])} rd-cy) "
              f"q0_first12={rds[:12].hex()} q0_last8={rds[-8:].hex()}")

    # ---- tx_stream frames ----
    print("\n== DUT tx_stream frames (valid&ready beats, last-terminated) ==")
    tbeats = [(i, e) for i, e in enumerate(data) if e['txv'] and e['txr']]
    tframes, cur = [], []
    for i, e in tbeats:
        cur.append((i, e['txs'] & 0xff))
        if e['txs'] & 0x100:
            tframes.append(cur); cur = []
    if cur: tframes.append(cur)
    for f in tframes:
        b = bytes(x[1] for x in f)
        print(f"  [{f[0][0]}..{f[-1][0]}] {len(b)}B head={b[:12].hex()}")
        pay = b[54:] if len(b) > 54 else b''
        if len(pay) > 16:
            base = next((k for k in range(36) if pay[:16] == bytes(PATTERN[(k+x) % 36] for x in range(16))), None)
            if base is not None:
                splice = next((x for x in range(1, len(pay)) if pay[x] != PATTERN[(base+x) % 36]), None)
                print(f"      payload {len(pay)}B base={base} splice_at={splice}"
                      + (f" got={pay[splice]:02x} exp={PATTERN[(base+splice)%36]:02x}" if splice else ""))

    # ---- q_len / q_off timeline (changes only) ----
    print("\n== q_len/q_off/occ timeline (changes, first 60) ==")
    last = None; cnt = 0
    for i, e in enumerate(data):
        key = (e['qlen'], e['qoff'])
        if key != last:
            print(f"  [{i}] q_len={e['qlen']:4d} q_off={e['qoff']:4d} occ={e['occ']:4d} "
                  f"state={st(e['fsm'])} txreq={e['txreq']} busy={e['macbusy']}")
            last = key; cnt += 1
            if cnt > 60: print("  ..."); break

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "cap_a.csv")
