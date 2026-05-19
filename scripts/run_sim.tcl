# Run an XSim behavioral simulation for the recreated Vivado project.
#
# Usage:
#   vivado -mode batch -source scripts/run_sim.tcl
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_top

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set project_path [file join $repo_root vivado digital_twin.xpr]

foreach tclstore_root {
    D:/AMDDesignTools/2025.2.1/Vivado/data/XilinxTclStore
    C:/Xilinx/Vivado/2025.2.1/data/XilinxTclStore
} {
    foreach pattern [list \
        [file join $tclstore_root support *] \
        [file join $tclstore_root tclapp * *] \
    ] {
        foreach tclapp_dir [glob -nocomplain -type d $pattern] {
            if {[file exists [file join $tclapp_dir pkgIndex.tcl]] && [lsearch -exact $::auto_path $tclapp_dir] < 0} {
                lappend ::auto_path $tclapp_dir
            }
        }
    }
}

set sim_top [lindex $argv 0]
if {$sim_top eq ""} {
    set sim_top tb_myCPU
}

set valid_tops {tb_myCPU tb_top tb_uart}
if {[lsearch -exact $valid_tops $sim_top] < 0} {
    puts "ERROR: invalid simulation top '$sim_top'. Expected one of: $valid_tops"
    exit 1
}

if {![file exists $project_path]} {
    puts "INFO: project not found; recreating it first"
    source [file join $script_dir create_project.tcl]
} elseif {[llength [current_project -quiet]] == 0} {
    open_project $project_path
}

set_property top $sim_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime 10us [get_filesets sim_1]
update_compile_order -fileset sim_1

set runtime [get_property xsim.simulate.runtime [get_filesets sim_1]]
if {$runtime eq ""} {
    set runtime 10us
}

puts "INFO: launching behavioral simulation top=$sim_top runtime=$runtime"
if {[catch {
    launch_simulation -simset sim_1 -mode behavioral
    run $runtime
    close_sim
} err]} {
    puts "ERROR: simulation failed: $err"
    exit 1
}

puts "INFO: simulation completed for $sim_top"
