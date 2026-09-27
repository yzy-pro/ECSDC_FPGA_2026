add_design "E:/code/PangoWork/Works/hdmi/ipcore/pll_50mhz/pll_50mhz.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/drivers/iic/iic_master.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/hardware/ms7200/ms7200_driver.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/hardware/ms7200/ms7200_top.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/hardware/ms7210/ms7210_driver.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/hardware/ms7210/ms7210_top.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/hardware/led/led.v"
add_design "E:/code/PangoWork/Works/hdmi/Designs/hdmi_loop_top.v"
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
compile -fsm_compiler {original} -top_module hdmi_loop_top
