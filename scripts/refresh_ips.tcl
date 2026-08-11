# Refresh/upgrade IPs in the recreated Vivado project and regenerate outputs.
#
# Usage:
#   vivado -mode batch -source scripts/refresh_ips.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
if {[info exists ::env(CODEX_REPO_ROOT)] &&
    [file exists [file join $::env(CODEX_REPO_ROOT) AGENTS.md]]} {
    set repo_root [string map {\\ /} $::env(CODEX_REPO_ROOT)]
    set script_dir [file join $repo_root scripts]
} elseif {[file exists [file join [pwd] AGENTS.md]]} {
    set repo_root [file normalize [pwd]]
    set script_dir [file join $repo_root scripts]
}
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

if {![file exists $project_path]} {
    puts "ERROR: project not found: $project_path"
    exit 1
}

if {[llength [current_project -quiet]] != 0} {
    close_project
}

open_project $project_path
report_ip_status

set ips [get_ips -quiet]
if {[llength $ips] != 0} {
    foreach ip $ips {
        puts "INFO: refreshing IP [get_property NAME $ip]"
        catch {upgrade_ip $ip} upgrade_err
        if {$upgrade_err ne ""} {
            puts "WARN: upgrade_ip returned: $upgrade_err"
        }
        reset_target all $ip
        if {[get_property NAME $ip] in {BRAM IROM}} {
            set memory_xci [get_files -quiet -all *[get_property NAME $ip].xci]
            if {[llength $memory_xci] != 0} {
                set_property GENERATE_SYNTH_CHECKPOINT false $memory_xci
                puts "INFO: [get_property NAME $ip] uses global synthesis to inherit the top-level clock"
            }
        }
        generate_target all $ip
    }
    export_ip_user_files -of_objects $ips -no_script -sync -force -quiet
}

update_compile_order -fileset sources_1
close_project
puts "INFO: IP refresh complete"
