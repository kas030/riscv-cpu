# Reset the per-user Vivado Tcl Store cache.
#
# Usage:
#   vivado -mode batch -source scripts/reset_tclstore.tcl

if {[catch {tclapp::reset_tclstore} err]} {
    puts "ERROR: failed to reset Tcl Store: $err"
    exit 1
}

puts "INFO: Vivado Tcl Store reset complete"
