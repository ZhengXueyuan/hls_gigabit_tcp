#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# ila_analyze.py — parse write_hw_ila_data CSV from the udp_hls_eco ILA capture
# and reconstruct the tcp_send_bufs queue write/read timeline around the 4th
# TCP segment of the 2000B echo test.
import csv, sys, re

FSM_STATES = {1<<i: f"s{i+1}" for i in range(33)}

def h(v):
    v = v.strip()
    if v.startswith("0x"): v = v[2:]
    v = v.replace("'", "").replace("_", "")
    try: return int(v, 16)
    except ValueError:
        try: return int(v, 2)
        except ValueError: return 0

def main(path):
    with open(path, newline='') as f:
        rows = list(csv.reader(f))
    hdr = rows[0]
    # find columns by probe index (headers usually contain 'probeN')
    col = {}
    for i, name in enumerate(hdr):
        m = re.search(r'probe(\d+)', name)
        if m: col[int(m.group(1))] = i
    isamp = next((i for i, n in enumerate(hdr) if 'Sample' in n), 0)
    itrig = next((i for i, n in enumerate(hdr) if 'TRIGGER' in n.upper()), None)
    print("columns:", {k: hdr[v] for k, v in sorted(col.items())})

    # probe map: 0=wr_addr 1=rd_addr 2=wr_data 3=rd_data 4=q_len 5=q_off
    #            6=fsm 7=ctrl 8=rx_stream 9=tx_stream 10=rx_fcnt 11=tx_fcnt
    ev = []
    for r in rows[1:]:
        if len(r) < len(hdr): continue
        p = {k: h(r[i]) for k, i in col.items()}
        ctrl = p.get(7, 0)
        ev.append(dict(
            smp=h(r[isamp]), trig=(r[itrig].strip() == '1') if itrig is not None else False,
            wa=p.get(0,0), ra=p.get(1,0), wd=p.get(2,0), rd=p.get(3,0),
            qlen=p.get(4,0), qoff=p.get(5,0), fsm=p.get(6,0),
            ce0=(ctrl>>15)&1, ce1=(ctrl>>14)&1, we1=(ctrl>>13)&1,
            txreq=(ctrl>>12)&1, macbusy=(ctrl>>11)&1,
            tcprx_start=(ctrl>>10)&1, tcprx_done=(ctrl>>9)&1,
            send_start=(ctrl>>8)&1, send_done=(ctrl>>7)&1,
            mactx_start=(ctrl>>6)&1, mactx_done=(ctrl>>5)&1,
            ff_wr=(ctrl>>4)&1, ffcid=ctrl&7,
            rxs=p.get(8,0), txs=p.get(9,0), rxfc=p.get(10,0), txfc=p.get(11,0)))

    # ---- event summary ----
    def st(fsm): return FSM_STATES.get(fsm, f"?{fsm:x}")
    nwr = sum(1 for e in ev if e['we1'] and e['ce1'])
    nrd = sum(1 for e in ev if e['ce0'])
    print(f"samples={len(ev)}  queue_writes={nwr}  queue_reads={nrd}")
    trigs = [i for i, e in enumerate(ev) if e['trig']]
    print(f"trigger sample index: {trigs}")

    # frame boundaries from streams (bit8 = last)
    rx_frames = [(i, e['rxfc']) for i, e in enumerate(ev) if e['rxs'] & 0x100]
    tx_frames = [(i, e['txfc']) for i, e in enumerate(ev) if e['txs'] & 0x100]
    print(f"rx frames (last beats): {len(rx_frames)} at {rx_frames[:20]}")
    print(f"tx frames (last beats): {len(tx_frames)} at {tx_frames[:20]}")

    # queue write bursts: group consecutive we1&ce1
    bursts = []
    cur = None
    for i, e in enumerate(ev):
        if e['we1'] and e['ce1']:
            if cur is None: cur = [i, i, e['wa'], e['wa'], []]
            cur[1] = i; cur[3] = e['wa']; cur[4].append(e['wd'])
        else:
            if cur: bursts.append(cur); cur = None
    if cur: bursts.append(cur)
    print(f"\nqueue write bursts: {len(bursts)}")
    for b in bursts:
        print(f"  [{b[0]}..{b[1]}] addr {b[2]}..{b[3]} ({len(b[4])}B) "
              f"first8={bytes(b[4][:8]).hex()} qlen@{b[0]}={ev[b[0]]['qlen']} state={st(ev[b[0]]['fsm'])}")

    # queue read bursts
    rbs = []
    cur = None
    for i, e in enumerate(ev):
        if e['ce0']:
            if cur is None: cur = [i, i, e['ra'], e['ra'], []]
            cur[1] = i; cur[3] = e['ra']; cur[4].append(e['rd'])
        else:
            if cur: rbs.append(cur); cur = None
    if cur: rbs.append(cur)
    print(f"\nqueue read bursts: {len(rbs)}")
    for b in rbs[:30]:
        print(f"  [{b[0]}..{b[1]}] addr {b[2]}..{b[3]} ({len(b[4])} samples) "
              f"q0_first8={bytes(b[4][:8]).hex()} state={st(ev[b[0]]['fsm'])}")

    # q_len/q_off trace at changes
    print("\nq_len/q_off changes:")
    last = None
    cnt = 0
    for i, e in enumerate(ev):
        key = (e['qlen'], e['qoff'])
        if key != last:
            print(f"  [{i}] q_len={e['qlen']} q_off={e['qoff']} state={st(e['fsm'])} txreq={e['txreq']}")
            last = key; cnt += 1
            if cnt > 80: print("  ..."); break

if __name__ == "__main__":
    main(sys.argv[1] if len(sys.argv) > 1 else "ila_cap.csv")
