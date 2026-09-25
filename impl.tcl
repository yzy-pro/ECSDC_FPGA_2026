# PDS batch implementation script for the IMU bridge.
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_rx.v"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_tx.v"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/led/led.v"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/pll_50mhz/pll_50mhz.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cboard_imu_rx_fifo/cboard_imu_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cp2102_tx_fifo/cp2102_tx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cboard_imu/cboard_imu.v"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cp2102/cp2102.v"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/cboard_imu_debug_top.v"
remove_design -verilog "E:/code/PangoWork/Works/cboard_imu/Designs/uart_loop_test_top.v"

add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cboard_imu.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cp2102.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/clock/clocks.fdc"

set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {cboard_imu_debug_top} top_library {work}} [get_filesets design_1]

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
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_rx.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_tx.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/pll_50mhz/pll_50mhz.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cboard_imu_rx_fifo/cboard_imu_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cp2102_tx_fifo/cp2102_tx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cboard_imu/cboard_imu.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cp2102/cp2102.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/cboard_imu_debug_top.v" -library work -verilog
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cboard_imu.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cp2102.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/clock/clocks.fdc"
set_option {max_threads} {0}
set_option -options {top_module	cboard_imu_debug_top	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {cboard_imu_debug_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
launch_tasks [get_tasks {syn_1}] -to_action synthesize
wait_on_tasks [get_tasks {syn_1}] -to_action synthesize
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_rx.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_tx.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/pll_50mhz/pll_50mhz.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cboard_imu_rx_fifo/cboard_imu_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cp2102_tx_fifo/cp2102_tx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cboard_imu/cboard_imu.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cp2102/cp2102.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/cboard_imu_debug_top.v" -library work -verilog
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cboard_imu.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cp2102.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/clock/clocks.fdc"
set_option {max_threads} {0}
set_option -options {top_module	cboard_imu_debug_top	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {cboard_imu_debug_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_rx.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/drivers/uart/uart_tx.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/pll_50mhz/pll_50mhz.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cboard_imu_rx_fifo/cboard_imu_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/ipcore/cp2102_tx_fifo/cp2102_tx_fifo.idf"
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cboard_imu/cboard_imu.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/hardware/cp2102/cp2102.v" -library work -verilog
add_design "E:/code/PangoWork/Works/cboard_imu/Designs/cboard_imu_debug_top.v" -library work -verilog
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cboard_imu.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/cp2102.fdc"
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/clock/clocks.fdc"
set_option {max_threads} {0}
set_option -options {top_module	cboard_imu_debug_top	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {cboard_imu_debug_top}} [get_filesets design_1]
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
add_constraint "E:/code/PangoWork/Works/cboard_imu/Constraints/io/key.fdc"
set_option {max_threads} {0}
set_option -options {top_module	cboard_imu_debug_top	top_library	work} [get_filesets design_1]
set_option {max_threads} {0}
set_option -options {top_module	cboard_imu_debug_top} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {cboard_imu_debug_top} top_library {work}} [get_filesets design_1]
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
