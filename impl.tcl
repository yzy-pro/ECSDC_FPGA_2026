# 由 Fabric Compiler（版本 2025.2，构建号 211867）于 2026 年 9 月 22 日生成。

add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v"
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v"
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v"
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v"
add_design E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf
add_design E:/code/PangoWork/Works/i2c/Designs/Hardware/eeprom/eeprom.v -library work -verilog
add_design E:/code/PangoWork/Works/i2c/Designs/Hardware/user_pll/user_pll.v -library work -verilog
add_design E:/code/PangoWork/Works/i2c/ipcore/eeprom_rx_fifo/eeprom_rx_fifo.idf
add_design E:/code/PangoWork/Works/i2c/ipcore/eeprom_tx_fifo/eeprom_tx_fifo.idf
add_design E:/code/PangoWork/Works/i2c/ipcore/pll_27mhz/pll_27mhz.idf
remove_design E:/code/PangoWork/Works/i2c/ipcore/pll_27mhz/pll_27mhz.idf
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/clock/clocks.fdc"
launch_tasks [get_tasks {syn_1}] -to_action synthesize
wait_on_tasks [get_tasks {syn_1}] -to_action synthesize
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
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_27mhz/pll_27mhz.idf"
remove_design "E:/code/PangoWork/Works/i2c/ipcore/pll_27mhz/pll_27mhz.idf"
set_option {max_threads} {0}
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/clock/clocks.fdc"
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/clock/clocks.fdc"
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/clock/clocks.fdc"
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
launch_tasks [get_tasks {syn_1}] -to_action synthesize
wait_on_tasks [get_tasks {syn_1}] -to_action synthesize
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/clock/clocks.fdc"
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/clk.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/key.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/led.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/clock/clocks.fdc"
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top}} [get_filesets design_1]
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
add_design E:/code/PangoWork/Works/i2c/ipcore/eeprom_tx_fifo/eeprom_tx_fifo.idf
add_design E:/code/PangoWork/Works/i2c/ipcore/eeprom_rx_fifo/eeprom_rx_fifo.idf
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
set_option {max_threads} {0}
set_option -options {top_module	i2c_driver	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_driver}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/eeprom/eeprom.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_rx_fifo/eeprom_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_tx_fifo/eeprom_tx_fifo.idf"
set_option {max_threads} {0}
set_option -options {top_module	eeprom	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {eeprom}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/eeprom/eeprom.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_rx_fifo/eeprom_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_tx_fifo/eeprom_tx_fifo.idf"
set_option {max_threads} {0}
set_option -options {top_module	eeprom	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {eeprom}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/eeprom/eeprom.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_rx_fifo/eeprom_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_tx_fifo/eeprom_tx_fifo.idf"
set_option {max_threads} {0}
set_option -options {top_module	eeprom	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {eeprom}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/i2c_eeprom_top.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/eeprom/eeprom.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v" -library work -verilog
add_design "E:/code/PangoWork/Works/i2c/ipcore/pll_50mhz/pll_50mhz.idf"
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_rx_fifo/eeprom_rx_fifo.idf"
add_design "E:/code/PangoWork/Works/i2c/ipcore/eeprom_tx_fifo/eeprom_tx_fifo.idf"
set_option {max_threads} {0}
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/led/led.v"
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/key/key.v"
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/eeprom/eeprom.v"
add_design "E:/code/PangoWork/Works/i2c/Designs/Driver/i2c/i2c_driver.v"
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
launch_tasks [get_tasks {syn_1}] -to_action synthesize
wait_on_tasks [get_tasks {syn_1}] -to_action synthesize
remove_constraint  -logic -fdc "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
add_constraint "E:/code/PangoWork/Works/i2c/Constraints/io/eeprom.fdc"
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
set_option {max_threads} {0}
set_option -options {top_module	i2c_eeprom_top	top_library	work} [get_filesets design_1]
add_design "E:/code/PangoWork/Works/i2c/Designs/Hardware/user_pll/user_pll.v" -library work -verilog
set_option {max_threads} {0}
set_option -options {top_module	user_pll	top_library	work} [get_filesets design_1]
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {user_pll}} [get_filesets design_1]
launch_tasks [get_tasks {syn_1}] -to_action compile
wait_on_tasks [get_tasks {syn_1}] -to_action compile
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
set_option max_threads 0
set_arch -family Logos -device PGL50H -speedgrade -6 -package FBG484
set_option -options { top_module {i2c_eeprom_top} top_library {work}} [get_filesets design_1]
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
