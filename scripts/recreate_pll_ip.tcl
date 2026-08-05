# Recreate the board PLL IP as a Clocking Wizard.
#
# Usage from repository root:
#   vivado -mode batch -source scripts/recreate_pll_ip.tcl
#
# This removes the Vivado project PLL IP instance and recreates it with:
#   clk_in1_p/n = 200 MHz differential input
#   clk_out1    = 50 MHz peripheral clock
#   clk_out2    = 200 MHz CPU clock

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set project_name digital_twin
set project_dir  [file join $repo_root vivado]
set project_path [file join $project_dir ${project_name}.xpr]
set pll_ip_dir   [file join $project_dir ${project_name}.srcs sources_1 ip pll]
set pll_xci      [file join $pll_ip_dir pll.xci]

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

if {![file exists $project_path]} {
    puts "ERROR: project not found: $project_path"
    puts "ERROR: run scripts/create_project.tcl first, or open/create the project in Vivado."
    exit 1
}

if {[llength [current_project -quiet]] != 0} {
    close_project
}

open_project $project_path

set old_pll_ips [get_ips -quiet pll]
if {[llength $old_pll_ips] != 0} {
    set old_ip_files [get_files -quiet -all -of_objects $old_pll_ips]
    if {[llength $old_ip_files] != 0} {
        remove_files -quiet $old_ip_files
    }
    remove_files -quiet $old_pll_ips
}

set old_pll_files [get_files -quiet -all $pll_xci]
if {[llength $old_pll_files] != 0} {
    remove_files -quiet $old_pll_files
}

file delete -force $pll_ip_dir
file mkdir $pll_ip_dir

create_ip -name clk_wiz -vendor xilinx.com -library ip -version 6.0 \
    -module_name pll -dir $pll_ip_dir

set pll_ip [get_ips pll]
set_property -dict [list \
    CONFIG.Component_Name {pll} \
    CONFIG.PRIM_SOURCE {Differential_clock_capable_pin} \
    CONFIG.PRIM_IN_FREQ {200.000} \
    CONFIG.CLKOUT1_REQUESTED_OUT_FREQ {50.000} \
    CONFIG.CLKOUT2_USED {true} \
    CONFIG.CLKOUT2_REQUESTED_OUT_FREQ {200.000} \
    CONFIG.NUM_OUT_CLKS {2} \
    CONFIG.USE_RESET {false} \
    CONFIG.USE_LOCKED {true} \
] $pll_ip

generate_target all $pll_ip
export_ip_user_files -of_objects $pll_ip -no_script -sync -force -quiet
update_compile_order -fileset sources_1

close_project
puts "INFO: recreated pll as clk_wiz: $pll_xci"
