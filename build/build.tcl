# ResNet CNN build for Z7-Nano
set part xc7z020clg400-2
set proj resnet

create_project $proj ./build_fpga -part $part -force

add_files [list rtl/resnet_board.v rtl/axi_lite_slave.v]
set_property top resnet_board [current_fileset]

# Constraints
set fp [open "resnet.xdc" w]
puts $fp "create_clock -period 20.000 -name sys_clk \[get_pins {PS7_i/FCLKCLK\[0\]}\]"
close $fp
add_files -fileset constrs_1 resnet.xdc

launch_runs synth_1 -jobs 8
wait_on_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

open_run impl_1
set wns [get_property SLACK [get_timing_paths]]
report_utilization -file build_fpga/util.rpt
puts "=============================="
puts " WNS: ${wns} ns"
puts " Bitstream: [glob ./build_fpga/*.runs/impl_1/*.bit]"
puts "=============================="
