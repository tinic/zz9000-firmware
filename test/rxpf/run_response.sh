#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"
R=../..
python3 - "$R/mntzorro.v" > mntzorro_sim.v <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("  reg vc_row_bank = 0;\n", "", 1)
i = s.index("  videocap_sampler #(")
s = s[:i] + "  reg vc_row_bank = 0;\n" + s[i:]
# Match the retained nofast hardware variant without editing source defaults.
s = s.replace("`define VARIANT_Z3_FASTRAM", "//`define VARIANT_Z3_FASTRAM")
s = s.replace("`define VARIANT_SUPERDENISE", "//`define VARIANT_SUPERDENISE")
print(s, end="")
PY
xvlog -sv "$VIVADO_DIR/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv" > response-xvlog.log 2>&1
xvlog --relax "$VIVADO_DIR/data/verilog/src/glbl.v" "$R"/videocap_*.v mntzorro_sim.v rxpf_tb.v rxpf_response_tb.v rxpf_guard_tb.v >> response-xvlog.log 2>&1
xelab --relax -L unisims_ver -L xpm --timescale 1ns/1ps rxpf_response_tb glbl -s response > response-xelab.log 2>&1
args=()
case "${1:-}" in
  "") ;;
  baseline) args=(-testplusarg EXPECT_LATE) ;;
  unguarded) args=(-testplusarg EXPECT_SHORT_SETUP) ;;
  *) echo "usage: $0 [baseline|unguarded]" >&2; exit 2 ;;
esac
xsim response -R "${args[@]}" > response.log 2>&1
grep -E '^RESPONSE checked|^FAIL|RESPONSE_VERDICT' response.log
grep -q RESPONSE_VERDICT_OK response.log
! grep -q '^FAIL' response.log

# Guard invalidation tests apply only to the corrected candidate.
if [ -z "${1:-}" ]; then
  xelab --relax -L unisims_ver -L xpm --timescale 1ns/1ps rxpf_guard_tb glbl -s guard > guard-xelab.log 2>&1
  xsim guard -R > guard.log 2>&1
  grep -E '^GUARD|^FAIL' guard.log
  grep -q GUARD_VERDICT_OK guard.log
  ! grep -q '^FAIL' guard.log
fi
