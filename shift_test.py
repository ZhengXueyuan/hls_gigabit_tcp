S = "MAC: 00:0A:35:01:FE:C0\r\n"
G = bytes.fromhex("93 86 3A C0 30 07 04 74 33 0D 07 C4 3A A4 74 43 34 0A")

for k in range(1, 17):
    # 192-bit register loaded with S left-aligned
    bits = ""
    for ch in S.encode():
        bits += format(ch, "08b")
    bits += "0" * (192 - len(bits))
    out = []
    reg = int(bits, 2)
    for i in range(len(G) + 6):
        out.append((reg >> 184) & 0xFF)
        reg = (reg << k) & ((1 << 192) - 1)
    match = sum(1 for a, b in zip(out, G) if a == b)
    if match >= 3:
        print(f"shift={k}: match={match}/{len(G)}  out=" + " ".join(f"{b:02X}" for b in out[:len(G)]))

# also try: wrong start slice (reg[183:176] etc.)
for off in range(0, 9):
    out = []
    reg = int("".join(format(ch, "08b") for ch in S.encode()) + "0" * (192 - len(S) * 8), 2)
    for i in range(len(G)):
        out.append((reg >> (191 - off - 7)) & 0xFF)
        reg = (reg << 8) & ((1 << 192) - 1)
    match = sum(1 for a, b in zip(out, G) if a == b)
    if match >= 3:
        print(f"offset={off}: match={match}/{len(G)}  out=" + " ".join(f"{b:02X}" for b in out))
