foreach command {open_design get_path_delay close_design dump_design_info} {
 puts "HELP $command"
 if {[catch {$command -help} result]} {puts $result}
}
