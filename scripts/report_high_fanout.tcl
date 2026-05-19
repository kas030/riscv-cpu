# Report high-fanout nets from an opened Vivado design or project.
#
# Usage examples:
#   vivado -mode batch -source scripts/report_high_fanout.tcl
#   vivado -mode batch -source scripts/report_high_fanout.tcl -tclargs vivado/digital_twin.xpr 64 100
#   vivado -mode batch -source scripts/report_high_fanout.tcl -tclargs vivado/digital_twin.runs/synth_1/top.dcp 64 100
#
# Tcl args:
#   1. project or checkpoint path, optional. Defaults to vivado/digital_twin.xpr.
#   2. fanout threshold, optional. Defaults to 64.
#   3. maximum nets in reports, optional. Defaults to 100.
#   4. native_only, optional. Set to 1 to skip the custom CSV scan.

# Some local Vivado installs can fail to auto-discover Tcl Store support
# packages before opening a checkpoint. Add the known install-side package
# directory when it exists; this is harmless if Vivado already configured it.
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

proc open_best_available_run {} {
    if {[llength [current_design -quiet]] != 0} {
        return
    }

    foreach run_name {impl_1 synth_1} {
        if {[llength [get_runs -quiet $run_name]] == 0} {
            continue
        }

        if {[catch {open_run $run_name} err]} {
            puts "WARN: failed to open $run_name: $err"
        } else {
            puts "INFO: opened run $run_name"
            return
        }
    }

    error "No opened design and neither impl_1 nor synth_1 could be opened. Run synthesis/implementation first."
}

proc net_fanout {net_obj} {
    set sinks [get_pins -quiet -leaf -of_objects $net_obj -filter {DIRECTION == IN}]
    return [llength $sinks]
}

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

set project_path [lindex $argv 0]
if {$project_path eq ""} {
    set project_path [file join $repo_root vivado digital_twin.xpr]
}
set project_path [file normalize $project_path]

set threshold [lindex $argv 1]
if {$threshold eq ""} {
    set threshold 64
}

set max_nets [lindex $argv 2]
if {$max_nets eq ""} {
    set max_nets 100
}

set native_only [lindex $argv 3]
if {$native_only eq ""} {
    set native_only 0
}

set path_ext [string tolower [file extension $project_path]]
if {$path_ext eq ".dcp"} {
    if {[llength [current_design -quiet]] == 0} {
        puts "INFO: opening checkpoint $project_path"
        open_checkpoint $project_path
    }
} elseif {[llength [current_project -quiet]] == 0} {
    puts "INFO: opening project $project_path"
    open_project $project_path
}

if {$path_ext ne ".dcp"} {
    open_best_available_run
}

set out_dir [file join $repo_root reports]
file mkdir $out_dir

set native_report [file join $out_dir high_fanout_nets.txt]
set csv_report    [file join $out_dir high_fanout_nets.csv]

puts "INFO: writing Vivado native report to $native_report"
report_high_fanout_nets \
    -fanout_greater_than $threshold \
    -max_nets $max_nets \
    -file $native_report \
    -quiet

if {$native_only} {
    puts "INFO: skipped CSV scan because native_only=$native_only"
    return
}

puts "INFO: collecting hierarchical nets for CSV"
set rows {}
array set seen_nets {}
foreach net [get_nets -quiet -hierarchical] {
    set fanout [net_fanout $net]
    if {$fanout < $threshold} {
        continue
    }

    set name [get_property NAME $net]
    set parent [get_property PARENT $net]
    set type ""
    catch {set type [get_property TYPE $net]}

    set key $name
    if {$parent ne ""} {
        set key $parent
    }
    if {[info exists seen_nets($key)]} {
        continue
    }
    set seen_nets($key) 1

    lappend rows [list $fanout $name $parent $type]
}

set rows [lsort -integer -decreasing -index 0 $rows]

set fp [open $csv_report w]
puts $fp "fanout,net,parent,type"

set count 0
foreach row $rows {
    if {$count >= $max_nets} {
        break
    }

    lassign $row fanout name parent type
    foreach var {name parent type} {
        set value [set $var]
        set value [string map {\" \"\"} $value]
        set $var "\"$value\""
    }
    puts $fp "$fanout,$name,$parent,$type"
    incr count
}
close $fp

puts "INFO: wrote $count CSV rows to $csv_report"
