set output [file normalize [file join [file dirname [info script]] .. .tmp_flash_readback.bin]]
set sfc [file normalize [file join [file dirname [info script]] .. prj_tasks pnr_1 generate_bitstream flash_read_top.sfc]]
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_jtag_flash_scan_device -device_index 0
cfg_jtag_flash_assign_file -device_index 0 -file $sfc
cfg_jtag_flash_readback -device_index 0 -file $output
exit
