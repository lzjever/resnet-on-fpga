# Vivado build script for ResNet CNN on Z7-Nano
# Usage: vivado -mode batch -source build/build.tcl
set part xc7z020clg400-2

create_project resnet ./.build -part $part -force

add_files ../rtl/resnet_top.v
set_property top resnet_top [current_fileset]

# Constraints: PS7 instantiation (same as lab09)
add_files -fileset constrs_1 -norecurse [make_constr]
proc make_constr {} {
    set f [open "resnet.xdc" w]
    puts $f "# Clock from PS FCLK0"
    puts $f "create_clock -period 20.000 -name sys_clk \[get_pins {PS7_i/FCLKCLK\[0\]}\]"
    close $f
    return "resnet.xdc"
}

launch_runs synth_1 -jobs 8
wait_on_run synth_1

launch_runs impl_1 -to_step write_bitstream -jobs 8
wait_on_run impl_1

set wns [get_property SLACK [get_timing_paths]]
puts "=============================="
puts " WNS: ${wns} ns"
puts " Bitstream: [glob ./.build/*.runs/impl_1/*.bit]"
puts "=============================="
