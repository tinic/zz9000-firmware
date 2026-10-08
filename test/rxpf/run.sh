#!/bin/bash
# run.sh: xsim the receive-window read-ahead (Vivado 2018.3 env sourced)
set -e
cd "$(dirname "$0")"
R=../..
# xsim rejects mntzorro.v's use of vc_row_bank before its declaration (synthesis
# accepts it); the simulated copy declares it ahead of the first use, nothing else.
python3 - "$R/mntzorro.v" > mntzorro_sim.v <<'PY'
import sys
s = open(sys.argv[1]).read()
s = s.replace("  reg vc_row_bank = 0;\n", "", 1)
i = s.index("  videocap_sampler #(")
print(s[:i] + "  reg vc_row_bank = 0;\n" + s[i:], end="")
PY
xvlog -sv $VIVADO_DIR/data/ip/xpm/xpm_cdc/hdl/xpm_cdc.sv > xvlog.log 2>&1
xvlog --relax $VIVADO_DIR/data/verilog/src/glbl.v $R/videocap_*.v mntzorro_sim.v rxpf_tb.v >> xvlog.log 2>&1
xelab --relax -L unisims_ver -L xpm --timescale 1ns/1ps rxpf_tb glbl -s rxpf > xelab.log 2>&1
xsim rxpf -R > xsim.log 2>&1
grep -E 'PASS|FAIL|INFO|ERROR' xsim.log | grep -v 'INFO: \['
echo "--- arready held low at random"
xsim rxpf -R -testplusarg RANDOM_ARREADY > xsim-rand.log 2>&1
grep -E 'PASS|FAIL|ERROR' xsim-rand.log
