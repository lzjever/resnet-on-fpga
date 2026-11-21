open_hw_manager
connect_hw_server
open_hw_target
set fpga_dev [lindex [get_hw_devices xc7z020*] 0]
if {$fpga_dev eq ""} { puts "ERROR: xc7z020 not found"; exit 1 }
current_hw_device $fpga_dev
set_property PROGRAM.FILE [glob ./build_fpga_int4/*.runs/impl_1/*.bit] [current_hw_device]
program_hw_devices [current_hw_device]
puts "=== JTAG program done ==="
close_hw_manager
