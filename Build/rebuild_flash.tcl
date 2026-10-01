# Rebuild the checked-in flash.pds project through bitstream generation.
set root [file normalize [file join [file dirname [info script]] ..]]
set project [file join $root flash.pds]

open_project $project
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {flash_read_top} top_library {work}} [get_filesets design_1]
clean -all

launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
launch_tasks [get_tasks {syn_1}] -to_action synthesize
wait_on_tasks [get_tasks {syn_1}] -to_action synthesize
launch_tasks [get_tasks {pnr_1}] -to_action dev_map
wait_on_tasks [get_tasks {pnr_1}] -to_action dev_map
launch_tasks [get_tasks {pnr_1}] -to_action place
wait_on_tasks [get_tasks {pnr_1}] -to_action place
launch_tasks [get_tasks {pnr_1}] -to_action route
wait_on_tasks [get_tasks {pnr_1}] -to_action route
launch_tasks [get_tasks {pnr_1}] -to_action route_optimize
wait_on_tasks [get_tasks {pnr_1}] -to_action route_optimize
launch_tasks [get_tasks {pnr_1}] -to_action report_timing
wait_on_tasks [get_tasks {pnr_1}] -to_action report_timing
launch_tasks [get_tasks {pnr_1}] -to_action gen_bit_stream
wait_on_tasks [get_tasks {pnr_1}] -to_action gen_bit_stream
save_project
