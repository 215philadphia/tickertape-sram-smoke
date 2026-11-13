#!/usr/bin/env bash
# Build and run the OCaml golden model and the PFST compiler tests; export compiled tables.
set -euo pipefail
cd "$(dirname "$0")"
oc() { ocamlfind ocamlopt -package str -linkpkg -w -a "$@"; }
oc -o golden_test     pfst.ml refs.ml i2c_env.ml nanotick_env.ml main.ml
oc -o compile_test    pfst.ml refs.ml i2c_env.ml nanotick_env.ml compiler.ml dsl_programs.ml compile_test.ml
oc -o export_compiled pfst.ml refs.ml compiler.ml dsl_programs.ml export_compiled.ml
./golden_test  | tee golden_test.log
./compile_test | tee compile_test.log
./export_compiled > compiled_tables.json
python3 -c "import json; d = json.load(open('compiled_tables.json')); print('exported', len(d), 'compiled programs:', ', '.join(d))"
fails=$(cat golden_test.log compile_test.log | grep -c "FAIL" || true)
# test/compiled_tables.json is the snapshot the RTL tests (test/test_programs.py) load: it must
# match what the compiler produces now. After changing a program: cp compiled_tables.json ../test/
if cmp -s compiled_tables.json ../test/compiled_tables.json; then
  echo "test/compiled_tables.json matches the compiler output"
else
  echo "FAIL: test/compiled_tables.json is stale; run: cp model/compiled_tables.json test/"; fails=$((fails + 1))
fi
echo "FAIL lines: $fails"; [ "$fails" -eq 0 ]
