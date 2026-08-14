# Run Vivado synthesis, implementation, or bitstream generation.
#
# Usage:
#   vivado -mode batch -source scripts/run_build.tcl
#   vivado -mode batch -source scripts/run_build.tcl -tclargs synth
#   vivado -mode batch -source scripts/run_build.tcl -tclargs impl
#   vivado -mode batch -source scripts/run_build.tcl -tclargs impl Performance_NetDelay_high
#   vivado -mode batch -source scripts/run_build.tcl -tclargs bitstream

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

if {![file exists [file join $repo_root AGENTS.md]]} {
    set fallback_root "C:/Users/ASUS/Desktop/riscv-cpu-main/riscv-cpu-main"
    if {[file exists [file join $fallback_root AGENTS.md]]} {
        set repo_root $fallback_root
        set script_dir [file join $repo_root scripts]
    }
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

set build_mode [lindex $argv 0]
set impl_strategy [lindex $argv 1]
if {$build_mode eq ""} {
    set build_mode bitstream
}
if {$impl_strategy eq ""} {
    # 日常迭代优先缩短实现时间；高强度布局策略由第二参数显式开启。
    set impl_strategy "Vivado Implementation Defaults"
}

set valid_modes {synth impl bitstream}
if {[lsearch -exact $valid_modes $build_mode] < 0} {
    puts "ERROR: invalid build mode '$build_mode'. Expected one of: $valid_modes"
    exit 1
}

proc fail_if_run_failed {run_name} {
    set run_obj [get_runs $run_name]
    set status [get_property STATUS $run_obj]
    set progress [get_property PROGRESS $run_obj]
    puts "INFO: $run_name status='$status' progress=$progress"

    if {[string first "ERROR" $status] >= 0 || $progress ne "100%"} {
        puts "ERROR: $run_name did not complete successfully"
        exit 1
    }
}

proc run_and_wait {run_name args} {
    set run_dir [get_property DIRECTORY [get_runs $run_name]]
    set run_log [file join $run_dir runme.log]
    puts "INFO: launching $run_name $args"
    puts "INFO: run log: $run_log"
    launch_runs $run_name {*}$args

    while {1} {
        after 30000
        set run_obj [get_runs $run_name]
        set status [get_property STATUS $run_obj]
        set progress [get_property PROGRESS $run_obj]
        puts "INFO: $run_name progress=$progress status='$status'"

        if {[string first "ERROR" $status] >= 0 || $progress eq "100%"} {
            break
        }
    }

    fail_if_run_failed $run_name
}

proc configure_memory_init {ip_name coe_path} {
    set normalized_coe [string map {\\ /} [file normalize $coe_path]]
    if {![file exists $normalized_coe]} {
        puts "ERROR: $ip_name initialization file not found: $normalized_coe"
        exit 1
    }

    set memory_ip [get_ips -quiet $ip_name]
    if {[llength $memory_ip] != 1} {
        puts "ERROR: expected exactly one $ip_name IP, found [llength $memory_ip]"
        exit 1
    }

    set_property CONFIG.Load_Init_File true $memory_ip
    set_property CONFIG.Coe_File $normalized_coe $memory_ip
    set memory_xci [get_files -quiet -all *${ip_name}.xci]
    if {[llength $memory_xci] != 0} {
        set_property GENERATE_SYNTH_CHECKPOINT false $memory_xci
    }
    reset_target all $memory_ip
    generate_target all $memory_ip
    puts "INFO: $ip_name initialization refreshed from $normalized_coe"
}

if {![file exists $project_path]} {
    puts "INFO: project not found; recreating it first"
    source [file join $script_dir create_project.tcl]
    open_project $project_path
} elseif {[llength [current_project -quiet]] == 0} {
    open_project $project_path
}

configure_memory_init IROM \
    [file join $repo_root rt-thread bsp mycpu build rtthread.irom.coe]
configure_memory_init BRAM \
    [file join $repo_root rt-thread bsp mycpu build rtthread.bram.coe]
set memory_ips [concat [get_ips -quiet IROM] [get_ips -quiet BRAM]]
export_ip_user_files -of_objects $memory_ips -no_script -sync -force -quiet

update_compile_order -fileset sources_1

if {$build_mode in {synth impl bitstream}} {
    reset_run synth_1
    run_and_wait synth_1 -jobs 8
    set synth_dcp [file join $repo_root vivado digital_twin.runs synth_1 top.dcp]
    puts "INFO: synthesis checkpoint: $synth_dcp"
}

if {$build_mode in {impl bitstream}} {
    set impl_run [get_runs impl_1]
    set_property strategy $impl_strategy $impl_run
    set impl_auto_incremental [expr {$impl_strategy eq "Vivado Implementation Defaults"}]
    set_property AUTO_INCREMENTAL_CHECKPOINT $impl_auto_incremental $impl_run
    puts "INFO: impl_1 strategy=$impl_strategy auto_incremental=$impl_auto_incremental"
    reset_run impl_1
    if {$build_mode eq "bitstream"} {
        run_and_wait impl_1 -to_step write_bitstream -jobs 8
        set bit_file [file join $repo_root vivado digital_twin.runs impl_1 top.bit]
        puts "INFO: bitstream: $bit_file"
    } else {
        run_and_wait impl_1 -jobs 8
        set impl_dcp [file join $repo_root vivado digital_twin.runs impl_1 top_routed.dcp]
        puts "INFO: implementation checkpoint: $impl_dcp"
    }
}

puts "INFO: build completed in mode=$build_mode"
