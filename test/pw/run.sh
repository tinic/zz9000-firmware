#!/bin/bash
# Packet receive window in mntzorro.v, end to end (Vivado 2018.3 xsim).
# Exits non-zero unless the testbench prints PW_VERDICT_OK.
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
xvlog --relax $VIVADO_DIR/data/verilog/src/glbl.v $R/videocap_*.v \
  $R/experimental/zz_eth_packet_window.v $R/experimental/zz_eth_packet_mailbox.v \
  $R/experimental/zz_eth_read_arbiter.v mntzorro_sim.v pw_tb.v >> xvlog.log 2>&1
xelab --relax -L unisims_ver -L xpm --timescale 1ns/1ps pw_tb glbl -s pw > xelab.log 2>&1
xsim pw -R > xsim.log 2>&1 || true
grep -E '^(PASS|FAIL|INFO|PW_VERDICT)' xsim.log
grep -q '^PW_VERDICT_OK' xsim.log
