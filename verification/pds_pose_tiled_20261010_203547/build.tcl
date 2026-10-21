open_project {D:/pango/works/EmbFPGA/test/verification/pds_pose_tiled_20261010_203547/pose_tiled.pds}
set_option max_threads 8
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options {top_module {hdmi_ddr3_top}} [get_filesets design_1]
launch_tasks [get_tasks syn_1] -to_action compile
wait_on_tasks [get_tasks syn_1] -to_action compile
launch_tasks [get_tasks syn_1] -to_action synthesize
wait_on_tasks [get_tasks syn_1] -to_action synthesize
launch_tasks [get_tasks pnr_1] -to_action dev_map
wait_on_tasks [get_tasks pnr_1] -to_action dev_map
set_option -options {optimize_multi_corner_timing {true} optimize_dp_recovery {true} optimize_rp_recovery {true}} [get_actions place -of_objects [get_tasks pnr_1]]
launch_tasks [get_tasks pnr_1] -to_action place
wait_on_tasks [get_tasks pnr_1] -to_action place
launch_tasks [get_tasks pnr_1] -to_action route
wait_on_tasks [get_tasks pnr_1] -to_action route
set_option -options {fix_hold_violation {true}} [get_actions route_optimize -of_objects [get_tasks pnr_1]]
launch_tasks [get_tasks pnr_1] -to_action route_optimize
wait_on_tasks [get_tasks pnr_1] -to_action route_optimize
set_option -options {nworst {64} max_path {64} report_max_skew {true}} [get_actions report_timing -of_objects [get_tasks pnr_1]]
launch_tasks [get_tasks pnr_1] -to_action report_timing
wait_on_tasks [get_tasks pnr_1] -to_action report_timing
launch_tasks [get_tasks pnr_1] -to_action gen_bit_stream
wait_on_tasks [get_tasks pnr_1] -to_action gen_bit_stream
