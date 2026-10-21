foreach command {set_max_skew define_attribute get_path_delay report_property report_attribute report_cdc set_false_path} {
    puts "HELP $command"
    if {[catch {$command -help} result]} {puts $result}
}
