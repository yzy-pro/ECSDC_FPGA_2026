puts "COMMANDS [info commands *clock*]"
puts "COMMANDS [info commands *delay*]"
puts "COMMANDS [info commands *skew*]"
puts "COMMANDS [info commands *help*]"
foreach command {set_clock_groups set_max_delay set_bus_skew get_cells get_pins get_property report_timing read_sdc} {
    puts "HELP $command"
    if {[catch {$command -help} result]} {puts $result}
}
