#!/usr/bin/env bash
# Run the formal proofs. Needs yosys, SymbiYosys (sby) and the cvc5 SMT solver (z3 and the old distro boolector are too slow/broken on the multipliers).
#   formal/run.sh            all proofs
#   formal/run.sh core       the core only
#   formal/run.sh chip       the chip level only
# The RTL in src/ is never modified: each properties file is pasted into a copy of the RTL in formal/build/.
set -euo pipefail
cd "$(dirname "$0")"
which="${1:-all}"
mkdir -p build

inject() {   # inject <rtl.v> <props.vh> <out.v>: paste the properties before the module's final `endmodule`
  python3 - "$1" "$2" "$3" <<'PY'
import sys
src = open(sys.argv[1]).read()
props = open(sys.argv[2]).read()
i = src.rindex("endmodule")
open(sys.argv[3], "w").write(src[:i] + "\n// ---- properties pasted in by formal/run.sh ----\n" + props + "\n" + src[i:])
PY
}

status=0
if [ "$which" = all ] || [ "$which" = core ]; then
  inject ../src/pfst_core_sram.v pfst_core_props.vh build/pfst_core_sram_formal.v
  sby -f core.sby || status=1
fi
if [ "$which" = all ] || [ "$which" = chip ]; then
  cp ../src/pfst_core_sram.v build/pfst_core_sram.v
  inject ../src/pfst_chip.v pfst_chip_props.vh build/pfst_chip_formal.v
  sby -f chip.sby || status=1
fi
exit $status
