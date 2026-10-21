puts "GRAY_CELLS [get_cells -hierarchical {*gray*}]"
puts "GRAY_PINS [get_pins -hierarchical {*gray*}]"
puts "SYNC_PINS [get_pins -hierarchical {*sync1*}]"
puts "DELAY_START"
puts [get_path_delay -from [get_pins {gray[0]/Q}] -to [get_pins {sync1[0]/D}] -max_path 1 -show_route]
puts "DELAY_END"
