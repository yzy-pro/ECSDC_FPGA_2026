# Run after building flash.pds with cdt_cfg_shell.exe -file <absolute path to this script>.
set root [file normalize [file join [file dirname [info script]] ..]]
set sbit [file join $root prj_tasks pnr_1 generate_bitstream flash_read_top.sbit]
set digest [file join $root Debug lut_checksum.bin]

cfg_gen_sfc -device_name W25Q128Q -opcode 11 \
    -sbit_start_address 0x00000000 -sbit $sbit \
    -user_address_list {00202000} -file_list [list $digest]
