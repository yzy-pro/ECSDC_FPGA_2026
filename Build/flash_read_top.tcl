# Run with: pds_shell -file Build/flash_read_top.tcl
set root [file normalize [file join [file dirname [info script]] ..]]
set output_dir [file normalize [file join $root .tmp_pds_build]]
create_project -force -syn_tool ads -family Logos -device PGL50H \
    -package FBG484 -speedgrade {-6} \
    [file join $output_dir flash_read_top.pds]

add_design [file join $root Designs Driver spi qspi_master_rx.v]
add_design [file join $root Designs Hardware flash flash_driver.v]
add_design [file join $root Designs Hardware flash flash_top.v]
add_design [file join $root Designs Hardware cp2102 cp2102_driver.v]
add_design [file join $root Designs Hardware cp2102 cp2102_top.v]
add_design [file join $root Designs Hardware led led_top.v]
add_design [file join $root Designs flash_read_top.v]
add_design [file join $root ipcore cp2102_tx_fifo cp2102_tx_fifo.idf]
add_constraint [file join $root Constraints flash flash.fdc]
add_constraint [file join $root Constraints system system.fdc]
add_constraint [file join $root Constraints cp2102 cp2102.fdc]
add_constraint [file join $root Constraints led led.fdc]

compile -top_module flash_read_top
synthesize -ads -top_module flash_read_top
dev_map
save_project
