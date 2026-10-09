# SPDX-License-Identifier: MIT
# Standalone packet-core measurement, NOT a full-design build or bitstream.
# Run via run_ooc.py for immutable source provenance and scratch cleanup.
proc packet_ooc {} {
    global argv
    if {[llength $argv] != 2} { error "Expected output directory and clock period (ns)" }
    lassign $argv out period
    set out [file normalize $out]
    if {![string is double -strict $period] || $period < 1.0 || $period > 100.0} {
        error "Clock period must be between 1 and 100 ns"
    }
    set root [file normalize [file join [file dirname [info script]] ../..]]
    set part xc7z020clg400-1
    set_param general.maxThreads 1
    create_project -in_memory packet_window_ooc -part $part
    read_verilog [file join $root experimental zz_eth_packet_window.v]

    # These are explicit assumed synchronous interface budgets, not Zorro/ACP
    # constraints. Include reset in the budget; no false paths or multicycles.
    set xdc [file join $out boundary.xdc]
    set f [open $xdc w]
    puts $f [format {create_clock -name packet_clk -period %.9f [get_ports clk]} $period]
    puts $f {set_clock_uncertainty -setup 0.100 [get_clocks packet_clk]}
    puts $f {set_clock_uncertainty -hold 0.050 [get_clocks packet_clk]}
    puts $f {set_input_delay -clock packet_clk -max 1.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
    puts $f {set_input_delay -clock packet_clk -min 0.000 [get_ports -filter {DIRECTION == IN && NAME != clk}]}
    puts $f {set_output_delay -clock packet_clk -max 1.000 [all_outputs]}
    puts $f {set_output_delay -clock packet_clk -min 0.000 [all_outputs]}
    close $f
    read_xdc $xdc
    synth_design -top zz_eth_packet_window -part $part -mode out_of_context
    if {[llength [get_clocks -quiet packet_clk]] != 1} { error "Missing probe clock" }
    report_utilization -hierarchical -file [file join $out synth_utilization.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -file [file join $out synth_timing.rpt]

    # Primitive names and widths make unexpected memory expansion visible.
    set f [open [file join $out memory_cells.tsv] w]
    puts $f "cell\tprimitive\tread_width_a\tread_width_b\twrite_width_a\twrite_width_b"
    set r18 [get_cells -hierarchical -quiet -filter {REF_NAME == RAMB18E1}]
    set r36 [get_cells -hierarchical -quiet -filter {REF_NAME == RAMB36E1}]
    foreach c [concat $r18 $r36] {
        set row [list $c [get_property REF_NAME $c]]
        foreach prop {READ_WIDTH_A READ_WIDTH_B WRITE_WIDTH_A WRITE_WIDTH_B} {
            lappend row [get_property $prop $c]
        }
        puts $f [join $row "\t"]
    }
    close $f
    set bram18 [llength $r18]
    set bram36 [llength $r36]
    # Preserve inference results even if a later implementation command fails.
    set f [open [file join $out inference.tsv] w]
    puts $f "ramb18\t$bram18"
    puts $f "ramb36\t$bram36"
    close $f

    opt_design
    place_design
    route_design
    report_utilization -hierarchical -file [file join $out routed_utilization.rpt]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -max_paths 10 -file [file join $out routed_timing.rpt]
    report_timing -delay_type min -max_paths 50 -path_type full_clock_expanded \
        -input_pins -file [file join $out routed_hold_paths.rpt]
    report_timing -delay_type max -max_paths 10 -path_type full_clock_expanded \
        -input_pins -file [file join $out routed_setup_paths.rpt]
    set registers [all_registers]
    set inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
    report_timing -delay_type min -from $registers -to $registers -max_paths 20 \
        -path_type full_clock_expanded -input_pins -file [file join $out internal_hold_paths.rpt]
    report_timing -delay_type min -from $inputs -to $registers -max_paths 20 \
        -path_type full_clock_expanded -input_pins -file [file join $out input_hold_paths.rpt]
    report_route_status -file [file join $out route_status.rpt]
    report_drc -file [file join $out drc.rpt]
    check_timing -verbose -file [file join $out check_timing.rpt]
    report_clocks -file [file join $out clocks.rpt]

    set setup [get_timing_paths -quiet -delay_type max -max_paths 1 -nworst 1]
    set hold [get_timing_paths -quiet -delay_type min -max_paths 1 -nworst 1]
    if {[llength $setup] != 1 || [llength $hold] != 1} { error "Missing setup/hold paths" }
    set setup_slack [get_property SLACK $setup]
    set hold_slack [get_property SLACK $hold]
    set internal_hold [get_timing_paths -quiet -delay_type min -from $registers \
        -to $registers -max_paths 1 -nworst 1]
    set input_hold [get_timing_paths -quiet -delay_type min -from $inputs \
        -to $registers -max_paths 1 -nworst 1]
    set internal_hold_slack unavailable
    set input_hold_slack unavailable
    if {[llength $internal_hold] == 1} { set internal_hold_slack [get_property SLACK $internal_hold] }
    if {[llength $input_hold] == 1} { set input_hold_slack [get_property SLACK $input_hold] }
    foreach slack [list $setup_slack $hold_slack] {
        if {![string is double -strict $slack] || abs($slack) > 1.0e6} {
            error "Non-finite or unconstrained slack: $slack"
        }
    }
    set ram_ok [expr {$bram18 + 2 * $bram36 >= 2}]
    set timing_ok [expr {$setup_slack >= 0 && $hold_slack >= 0}]
    set f [open [file join $out metrics.tsv] w]
    foreach {key value} [list vivado [version -short] part $part period_ns $period \
            ramb18 $bram18 ramb36 $bram36 setup_slack_ns $setup_slack \
            hold_slack_ns $hold_slack internal_hold_slack_ns $internal_hold_slack \
            input_hold_slack_ns $input_hold_slack bram_capacity_gate $ram_ok \
            numeric_timing_gate $timing_ok image_ready 0] {
        puts $f "$key\t$value"
    }
    close $f
    puts "OOC_MEASURED: RAMB18=$bram18 RAMB36=$bram36 setup=$setup_slack hold=$hold_slack"
    # No automatic pass can approve constraint coverage, DRC, or integration.
    if {!$ram_ok || !$timing_ok} { error "OOC numeric gate failed; inspect retained reports" }
    puts "OOC_NUMERIC_GATE PASS; manual report review and full integration still required"
}
if {[catch {packet_ooc} message options]} {
    puts stderr "OOC_ERROR: $message"
    puts stderr [dict get $options -errorinfo]
    exit 1
}
exit 0
