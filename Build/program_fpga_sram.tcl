set sbit [file normalize [file join [file dirname [info script]] .. prj_tasks pnr_1 generate_bitstream flash_read_top.sbit]]
cfg_connect -ip 127.0.0.1 -port 65420
cfg_scan_chain
cfg_assign_file -device_index 0 -file $sbit
cfg_program -device_index 0
exit
