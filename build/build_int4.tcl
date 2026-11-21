# INT4 ResNet build for Z7-Nano (branch: int4)
set part xc7z020clg400-2
set proj resnet_int4

create_project $proj ./build_fpga_int4 -part $part -force

add_files [list rtl/resnet_board_int4.v rtl/resnet_top_int4.v rtl/axi_lite_slave.v]
set_property top resnet_board_int4 [current_fileset]

# Constraints
set fp [open "resnet_int4.xdc" w]
puts $fp "create_clock -period 20.000 -name sys_clk \[get_pins {PS7_i/FCLKCLK\[0\]}\]"
close $fp
add_files -fileset constrs_1 resnet_int4.xdc

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

open_run impl_1
set wns [get_property SLACK [get_timing_paths]]
report_utilization -file build_fpga_int4/util.rpt
puts "=============================="
puts " WNS: ${wns} ns"
puts " Bitstream: [glob ./build_fpga_int4/*.runs/impl_1/*.bit]"
puts "=============================="
