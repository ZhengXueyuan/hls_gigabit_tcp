from sim_uart_tx import tx_stream

S = "MAC: 00:0A:35:01:FE:C0\r\n"
G = bytes.fromhex("93 86 3A C0 30 07 04 74 33 0D 07 C4 3A A4 74 43 34 0A")
line = tx_stream(list(S.encode()))

# TX stream bits as a list
bits = line

# RX with fixed offset k: byte i = bits[k + 10*i + 1 : k + 10*i + 9]
for k in range(0, 12):
    out = []
    for i in range(len(G)):
        pos = k + 10 * i
        if pos + 9 >= len(bits): break
        val = 0
        for b in range(8):
            val |= bits[pos + 1 + b] << b
        out.append(val)
    if len(out) >= len(G):
        match = sum(1 for a, b in zip(out, G) if a == b)
        if match > 6:
            print(f"k={k} match={match}/{len(G)}: " + " ".join(f"{b:02X}" for b in out))

# also try: RX resyncs at each falling edge (proper model), but print byte-by-byte
# with bit offsets: after each byte, skip to next falling edge
def rx_resync(bits, max_bytes=24):
    out = []
    i = 0
    n = len(bits)
    while len(out) < max_bytes and i < n - 1:
        while i < n - 1 and not (bits[i] == 1 and bits[i+1] == 0):
            i += 1
        if i >= n - 1: break
        st = i + 1
        val = 0
        for k in range(8):
            pos = st + int((k + 1.5) * 5208)
            if pos < n and bits[pos]: val |= 1 << k
        out.append(val)
        i = st + 5208  # move past this byte region
    return out

r = rx_resync(bits)
print("resync model:", " ".join(f"{b:02X}" for b in r))
print("G           :", " ".join(f"{b:02X}" for b in G))
