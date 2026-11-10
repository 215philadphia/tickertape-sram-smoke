"""Longest-path tracer over an SDF timing graph (max delays, rise/fall tracked).

Usage: python3 sdf_paths.py <file.sdf> <max.rpt>

Edges: INTERCONNECT (net wires) and IOPATH (combinational cell arcs).
Cell arc unateness is not in the SDF, so each output edge takes the worse of
the input rise/fall arrivals (slightly pessimistic, never optimistic).
Sequential launch arcs (CLK -> Q / A_CLK -> A_DOUT) are only used as starts.
"""
import re, sys, collections

sdf_path, rpt_path = sys.argv[1], sys.argv[2]
txt = open(sdf_path).read()

def mx(triple):  # "(a:b:c)" -> max value c (slow-corner max delay)
    v = [x for x in triple.strip('()').split(':') if x]
    return float(v[-1]) if v else None

edges = collections.defaultdict(list)   # src pin -> [(dst pin, rise, fall)]
launch = {}                             # A_DOUT pin -> (rise, fall) from A_CLK
for m in re.finditer(r'\(INTERCONNECT (\S+) (\S+) (\([^)]*\)) (\([^)]*\))\)', txt):
    edges[m[1]].append((m[2], mx(m[3]), mx(m[4])))

cells = re.split(r'\n \(CELL\b', txt)
for c in cells[1:]:
    mi = re.search(r'\(INSTANCE ([^)]*)\)', c); inst = mi[1].strip() if mi else ''
    for m in re.finditer(r'\(IOPATH (\S+) (\S+) (\([^)]*\)) (\([^)]*\))', c):
        a, b = m[1], m[2]
        if a.startswith('(') or a in ('CLK', 'A_CLK'):   # sequential arc
            if inst == 'sram0' and a == 'A_CLK':
                launch[f'sram0.{b}'] = (mx(m[3]), mx(m[4]))
            continue
        r, f = mx(m[3]), mx(m[4])
        r = f if r is None else r; f = r if f is None else f
        if r is not None:
            edges[f'{inst}.{a}'].append((f'{inst}.{b}', r, f))

def longest(starts, stop):
    """starts: {pin: (rise_arr, fall_arr)}; returns best arrival and path per stop pin."""
    arr = dict(starts); prev = {}
    order = list(starts)
    # graph is a DAG (combinational); relax via repeated BFS with worklist
    work = collections.deque(order)
    while work:
        p = work.popleft()
        if stop(p) and p not in starts:
            continue
        r, f = arr[p]
        worst = max(r, f)
        for q, dr, df in edges.get(p, []):
            is_wire = '.' not in p or p.split('.')[0] != q.split('.')[0]
            nr = (r + dr) if is_wire else worst + dr
            nf = (f + df) if is_wire else worst + df
            o = arr.get(q)
            if o is None or nr > o[0] + 1e-12 or nf > o[1] + 1e-12:
                arr[q] = (max(nr, o[0]) if o else nr, max(nf, o[1]) if o else nf)
                prev[q] = p
                work.append(q)
    return arr, prev

def path_to(prev, p):
    out = [p]
    while p in prev:
        p = prev[p]; out.append(p)
    return out[::-1]

# ---- Reference values taken from the CI report (slow corner) ----
rpt = open(rpt_path).read()
LAUNCH_LAT = 3.709694 - 3.219270   # clock network delay to sram0/A_CLK (launch), from report
REQ_BASE = 20.436909 - 0.25        # capture clock at A_CLK minus uncertainty, from report

# Calibrate SRAM clk->Q: report's A_DOUT delay vs SDF IOPATH, per reported bit
offs = []
for m in re.finditer(r'(\d\.\d+)\s+(\d+\.\d+) ([\^v]) sram0/A_DOUT\[(\d+)\]', rpt):
    d, edge, bit = float(m[1]), m[3], int(m[4])
    r, f = launch[f'sram0.A_DOUT[{bit}]']
    offs.append(d - (r if edge == '^' else f))
off = max(offs)
print(f'clk->Q offset report-vs-SDF over {len(offs)} reported bits: '
      f'min {min(offs):.3f}  max {off:.3f} ns (using max: conservative)')

# Setup times for A_ADDR from SDF TIMINGCHECK (worst = max)
setup = {}
for m in re.finditer(r'\(SETUP(?:HOLD)? \((?:COND \S+ )?\((pos|neg)edge A_ADDR\[(\d+)\]\)\)?\s*\((?:COND \S+ )?\(posedge A_CLK\)\)?\s*(\([^)]*\))', txt):
    b = int(m[2]); setup[b] = max(setup.get(b, -9), mx(m[3]))

# ---- Validation: reproduce reported sram0 -> uo_out[3] arrival ----
starts = {p: (LAUNCH_LAT + r + off, LAUNCH_LAT + f + off) for p, (r, f) in launch.items()}
arr, prev = longest(starts, lambda p: p.startswith('sram0.') and 'A_ADDR' in p)
m = re.search(r'Endpoint: uo_out\[3\].*?(\d+\.\d+)\s+data arrival time', rpt, re.S)
print(f'validation uo_out[3]: report arrival {float(m[1]):.3f} ns, SDF tracer {max(arr["uo_out[3]"]):.3f} ns')

# ---- Chase loop: sram0 A_DOUT -> sram0 A_ADDR ----
print('\nA_DOUT -> A_ADDR (chase loop), slow corner nom_slow_1p08V_125C:')
worst = None
for b in range(8):
    p = f'sram0.A_ADDR[{b}]'
    if p not in arr:
        print(f'  A_ADDR[{b}]: no path from A_DOUT'); continue
    a = max(arr[p]); su = setup.get(b, -0.141005)
    slack = REQ_BASE - su - a
    pth = path_to(prev, p)
    print(f'  A_ADDR[{b}]: from {pth[0]:<16} arrival {a:6.3f}  setup {su:+.3f}  slack {slack:6.3f} ns  ({len(pth)} pins)')
    if worst is None or slack < worst[0]:
        worst = (slack, pth)
print(f'\nWorst chase slack: {worst[0]:.3f} ns')
print('Worst chase path: ' + ' -> '.join(worst[1]))
