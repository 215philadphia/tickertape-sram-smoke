#!/usr/bin/env bash
# Plant bugs in a COPY of the host library and check the tests catch each one (the real tree is never modified).
# Usage: host/tests/mutate.sh        exit 0 only if the clean tree passes and every mutant is caught.
set -u
cd "$(dirname "$0")"
HERE=$(pwd)
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
fail=0

run_suite() {   # $1 = dir holding ttpfst/ and examples/ ; prints "pure=<rc> sim=<rc> failed: <tests>"
  local d=$1 prc src rc
  make pure HOST_DIR="$d" >"$WORK/pure.log" 2>&1; prc=$?
  make -B HOST_DIR="$d" >"$WORK/sim.log" 2>&1; rc=$?
  local failed
  failed=$(python3 - <<'PY'
import xml.etree.ElementTree as ET
try:
    r = ET.parse("results.xml").getroot()
    print(",".join(t.get("name") for t in r.iter("testcase") if t.find("failure") is not None or t.find("error") is not None) or "-")
except Exception as e:
    print("no results.xml: %s" % e)
PY
)
  echo "pure=$prc sim=$rc failed-sim-tests: $failed"
  return $(( prc != 0 || rc != 0 ))
}

echo "== clean tree"
cp -r ../ttpfst ../examples "$WORK/"
if ! run_suite "$WORK"; then echo "FAIL: clean tree does not pass"; exit 1; fi

mutant() {   # name file sed-expression
  local name=$1 file=$2 expr=$3
  rm -rf "$WORK/m"; mkdir "$WORK/m"; cp -r ../ttpfst ../examples "$WORK/m/"
  sed -i "$expr" "$WORK/m/$file"
  if cmp -s "$WORK/m/$file" "../$file"; then echo "== $name: MUTATION DID NOT APPLY"; fail=1; return; fi
  echo "== mutant $name  ($file: $expr)"
  if run_suite "$WORK/m"; then echo "   NOT CAUGHT"; fail=1; else echo "   caught"; fi
}

mutant cpol-1            ttpfst/spi.py    's/^CPOL = 0 /CPOL = 1 /'
mutant word-byte-order   ttpfst/driver.py 's/^WORD_BYTEORDER = "big"/WORD_BYTEORDER = "little"/'
mutant rsel-nibbles-swap ttpfst/loader.py 's/ra | rb << 2/rb | ra << 2/'
mutant msb-first-dropped ttpfst/loader.py 's/cfg = int(prog\["msb_first"\]) | conf/cfg = 0 | conf/'
mutant start-without-restart ttpfst/driver.py 's/CTRL_RUN | CTRL_RESTART)$/CTRL_RUN)/'

# the real tree was not touched
git diff --quiet -- ../ttpfst ../examples || { echo "real tree modified"; fail=1; }
[ $fail -eq 0 ] && echo "ALL MUTANTS CAUGHT" || echo "SOME MUTANT SURVIVED OR HARNESS ERROR"
exit $fail
