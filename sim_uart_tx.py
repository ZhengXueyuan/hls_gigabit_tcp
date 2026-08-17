# sim_uart_tx.py — exact cycle model of uart_console TX FSM + CH340 RX model
# Purpose: reproduce the observed garbled ?mac response to find the mechanism.
import sys

BPS_DIV = 5207
BPS_HALF = 2603
T = BPS_DIV + 1  # 5208 cycles per cell

def tx_stream(bytes_list, idle_after=10000):
    """Model the C++ TX FSM exactly: mid-cell driving, tx_active drops at stop
    drive, next byte starts on the very next cycle."""
    line = []
    tx_active = 0
    tcnt = 0
    tnum = 0
    tx_out = 1
    tx_byte = 0
    data = list(bytes_list)
    qi = 0
    resp_remain = len(data)
    for c in range(200000):
        if tx_active:
            if tcnt == BPS_HALF:
                if tnum == 0: tx_out = 0
                elif tnum <= 8: tx_out = (tx_byte >> (tnum - 1)) & 1
                else: tx_out = 1
                if tnum == 9: tx_active = 0
                else: tnum += 1
            if tcnt == BPS_DIV: tcnt = 0
            else: tcnt += 1
        else:
            tx_out = 1
            if resp_remain > 0:
                tx_active = 1
                tx_byte = data[qi]      # capture current top byte, THEN advance
                qi += 1
                resp_remain -= 1
                tcnt = 0
                tnum = 0
        line.append(tx_out)
        if resp_remain == 0 and tx_active == 0 and c > 10:
            break
    return line

def rx_model(line, bit_time, max_bytes=64):
    """CH340-like RX: sync on 1->0 falling edge, sample mid-cell of each bit,
    stop-bit check at 9.5 cells."""
    out = []
    i = 0
    n = len(line)
    while len(out) < max_bytes and i < n - 1:
        # find 1->0 falling edge
        while i < n - 1 and not (line[i] == 1 and line[i + 1] == 0):
            i += 1
        if i >= n - 1: break
        start = i + 1  # first low sample after the edge
        # sample 8 data bits at 1.5T..8.5T, stop at 9.5T
        val = 0
        ok = True
        for k in range(8):
            pos = start + int((k + 1.5) * bit_time)
            if pos >= n: ok = False; break
            if line[pos]: val |= (1 << k)
        if not ok: break
        stoppos = start + int(9.5 * bit_time)
        stop = 1 if (stoppos < n and line[stoppos]) else 0
        out.append((val, stop))
        i = start + int(bit_time)  # skip past this byte's cells
    return out

text = "MAC: 00:0A:35:01:FE:C0\r\n"
real = list(text.encode())
line = tx_stream(real)
# what does a perfect RX see at various bit times (in cycles)?
for bt in [5208, 49476/9.5, 5200, 5250, 10416/2]:
    pass

# RX at exactly 5208-cycle cells
out = rx_model(line, 5208)
got = bytes([v for v, s in out if s == 1])  # keep all, note framing
obs = bytes.fromhex("93 86 3A C0 30 07 04 74 33 0D 07 C4 3A A4 74 43 34 0A")
print("real:", " ".join(f"{b:02X}" for b in real))
print("rx  :", " ".join(f"{v:02X}" for v, s in out))
print("stop flags:", "".join(str(s) for v, s in out))
print("obs :", " ".join(f"{b:02X}" for b in obs))
# try bit_time = 9.5-cell-spacing/9.5 = 49476/9.5
bt = 49476 / 9.5
out2 = rx_model(line, bt)
print(f"rx@bt={bt:.1f}:", " ".join(f"{v:02X}" for v, s in out2))
# try RX that resyncs mid-stream (start edges at 9.5 cells): model RX cells = 9.5*5208/10?
for frac in [0.95, 0.98, 1.0, 1.02, 1.05]:
    bt2 = 5208 * frac
    out3 = rx_model(line, bt2)
    vals = " ".join(f"{v:02X}" for v, s in out3)
    print(f"bt={bt2:.0f} ({frac}): {vals[:80]}")
