#!/usr/bin/env bash
# STUDY ONLY. Simulates the version-2 sketch once: a 60-byte frame, decoded and its CRC-32 checked with zlib.
set -euo pipefail
cd "$(dirname "$0")"
python3 -c "
import random; r = random.Random(5); open('frame.hex', 'w').write('\n'.join('%02x' % r.randrange(256) for _ in range(60)) + '\n')"
iverilog -g2012 -o tb_eth_v2.vvp tb_eth_v2.v eth_v2_tx.v && vvp -n tb_eth_v2.vvp > /dev/null
python3 - <<'PY'
import zlib
frame = bytes(int(x, 16) for x in open('frame.hex').read().split())
line = [l.strip() for l in open('line.txt')]
d = [{'10': 1, '01': -1, '00': 0}[x] for x in line]
s = next(i for i, x in enumerate(d) if x)
bits = []
while True:
    a, b = d[s + 4 * len(bits)], d[s + 4 * len(bits) + 2]
    if (a, b) == (-1, 1): bits.append(1)
    elif (a, b) == (1, -1): bits.append(0)
    else: break
assert bits[:64] == [1, 0] * 31 + [1, 1], 'preamble/SFD'
body = bytes(sum(bits[64 + 8 * k + i] << i for i in range(8)) for k in range((len(bits) - 64) // 8))
assert body[:60] == frame, 'data'
assert body[60:] == zlib.crc32(frame).to_bytes(4, 'little'), 'FCS %s != %08x' % (body[60:].hex(), zlib.crc32(frame))
etd = 0
while d[s + 4 * len(bits) + etd] == 1: etd += 1
print('study sketch: %d bits decoded, 60 bytes and CRC-32 %08x correct, start of idle %d ns' % (len(bits), zlib.crc32(frame), etd * 25))
PY
rm -f tb_eth_v2.vvp line.txt frame.hex
