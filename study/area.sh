#!/usr/bin/env bash
# STUDY ONLY. Cell area of the version-2 sketch, and of the existing chip logic for comparison, from Yosys
# synthesis mapped to the IHP SG13G2 standard cells (the cell set sg13cmos5l is built from).
# Usage: study/area.sh /path/to/sg13g2_stdcell_typ_1p20V_25C.lib
# This is synthesis only: no placement, clock tree, hold buffers, fill or routing.
set -euo pipefail
LIB="$1"; cd "$(dirname "$0")"
synth() {  # top, files...
  local top="$1"; shift
  yosys -q -p "read_verilog -sv $*; synth -top $top -flatten; dfflibmap -liberty $LIB; abc -liberty $LIB; opt_clean; tee -o /dev/stdout stat -liberty $LIB" \
    | grep -E "Number of cells|Chip area|sg13g2_dfr|sg13g2_sdf|sg13g2_dfrbp" | sed "s/^/  /"
}
echo "version-2 transmit sketch (eth_v2_tx):"; synth eth_v2_tx eth_v2_tx.v
echo "existing chip logic (pfst_chip, both cores, SRAM macros outside):"; synth pfst_chip ../src/pfst_chip.v ../src/pfst_core_sram.v
