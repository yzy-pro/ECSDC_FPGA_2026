open_project {D:/pango/works/EmbFPGA/test/EmbFPGA.pds}
set_option max_threads 8
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options {top_module {hdmi_ddr3_top}} [get_filesets design_1]
launch_tasks [get_tasks syn_1] -to_action compile
wait_on_tasks [get_tasks syn_1] -to_action compile
launch_tasks [get_tasks syn_1] -to_action synthesize
wait_on_tasks [get_tasks syn_1] -to_action synthesize
