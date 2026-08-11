# Run an XSim behavioral simulation for the recreated Vivado project.
#
# Usage:
#   vivado -mode batch -source scripts/run_sim.tcl
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_top
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_i2c_register_master all
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_myCPU all
#   vivado -mode batch -source scripts/run_sim.tcl -tclargs tb_myCPU 500ms

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
if {[info exists ::env(CODEX_REPO_ROOT)] && [file exists [file join $::env(CODEX_REPO_ROOT) AGENTS.md]]} {
    set repo_root [string map {\\ /} $::env(CODEX_REPO_ROOT)]
    set script_dir [file join $repo_root scripts]
} elseif {[file exists [file join [pwd] AGENTS.md]]} {
    set repo_root [file normalize [pwd]]
    set script_dir [file join $repo_root scripts]
}

if {![file exists [file join $repo_root AGENTS.md]]} {
    set fallback_root "C:/Users/ASUS/Desktop/riscv-cpu-main/riscv-cpu-main"
    if {[file exists [file join $fallback_root AGENTS.md]]} {
        set repo_root $fallback_root
        set script_dir [file join $repo_root scripts]
    }
}

set project_path [file join $repo_root vivado digital_twin.xpr]

proc find_vivado_tool {tool_name} {
    set suffix ""
    if {$::tcl_platform(platform) eq "windows"} {
        set suffix ".bat"
    }
    set tool_file "${tool_name}${suffix}"
    set candidates {}

    if {[info exists ::env(XILINX_VIVADO)]} {
        lappend candidates [file join $::env(XILINX_VIVADO) bin $tool_file]
    }

    set search_dir [file dirname [string map {\\ /} [info nameofexecutable]]]
    for {set i 0} {$i < 8} {incr i} {
        lappend candidates [file join $search_dir $tool_file]
        lappend candidates [file join $search_dir bin $tool_file]
        set parent [file dirname $search_dir]
        if {$parent eq $search_dir} {
            break
        }
        set search_dir $parent
    }

    foreach path {
        D:/AMDDesignTools/2025.2.1/Vivado/bin
        C:/Xilinx/Vivado/2025.2.1/bin
    } {
        lappend candidates [file join $path $tool_file]
    }

    foreach candidate $candidates {
        set candidate [string map {\\ /} $candidate]
        if {[file exists $candidate]} {
            return $candidate
        }
    }

    error "cannot find Vivado tool '$tool_file'"
}

proc run_logged {argv} {
    puts "INFO: exec [join $argv { }]"
    if {[catch {exec {*}$argv 2>@1} output]} {
        if {$output ne ""} {
            puts $output
        }
        error $output
    }
    if {$output ne ""} {
        puts $output
    }
}

proc run_manual_xsim {repo_root sim_top runtime} {
    puts "INFO: falling back to manual XSim flow"

    set xvlog [find_vivado_tool xvlog]
    set xelab [find_vivado_tool xelab]
    set xsim  [find_vivado_tool xsim]

    set vivado_root [file dirname [file dirname $xvlog]]
    set glbl_file [string map {\\ /} [file join $vivado_root data verilog src glbl.v]]
    if {![file exists $glbl_file]} {
        error "cannot find Vivado glbl.v: $glbl_file"
    }

    set ordered_files [get_files -compile_order sources -used_in simulation -of_objects [get_filesets sim_1]]
    set hdl_files {}
    foreach file_path $ordered_files {
        set ext [string tolower [file extension $file_path]]
        if {$ext eq ".v" || $ext eq ".sv"} {
            lappend hdl_files [string map {\\ /} $file_path]
        }
    }
    lappend hdl_files $glbl_file

    if {[llength $hdl_files] == 0} {
        error "no HDL files found for simulation"
    }

    set work_dir [string map {\\ /} [file join $repo_root vivado manual_xsim $sim_top]]
    file mkdir $work_dir

    foreach mif_file [list \
        [file join $repo_root vivado digital_twin.srcs sources_1 ip BRAM BRAM BRAM.mif] \
        [file join $repo_root vivado digital_twin.srcs sources_1 ip IROM IROM IROM.mif] \
    ] {
        set mif_file [string map {\\ /} $mif_file]
        if {[file exists $mif_file]} {
            file copy -force $mif_file [file join $work_dir [file tail $mif_file]]
        }
    }

    set include_args [list \
        -i [string map {\\ /} [file join $repo_root rtl common]] \
        -i [string map {\\ /} [file join $repo_root vivado digital_twin.srcs sources_1 ip pll pll]] \
    ]
    set snapshot "${sim_top}_behav"
    set run_tcl [string map {\\ /} [file join $work_dir run_${sim_top}.tcl]]

    set fp [open $run_tcl w]
    set runtime_lc [string tolower $runtime]
    if {$runtime_lc eq "all" || $runtime_lc eq "-all" || $runtime_lc eq "runall"} {
        puts $fp "run -all"
    } else {
        puts $fp "run $runtime"
    }
    puts $fp {foreach sig {/tb_myCPU/led /tb_myCPU/seg /tb_myCPU/cnt_cycles /tb_myCPU/cnt_writeback} {
    if {![catch {get_value -radix hex $sig} value]} {
        puts "INFO: final $sig = $value"
    }
}}
    puts $fp "quit"
    close $fp

    set old_pwd [pwd]
    cd $work_dir
    if {[catch {
        run_logged [concat [list $xvlog] $include_args [list -sv] $hdl_files]
        run_logged [list $xelab -L unisims_ver -L unimacro_ver -L secureip --snapshot $snapshot work.$sim_top work.glbl]
        run_logged [list $xsim $snapshot -tclbatch $run_tcl]
    } err]} {
        if {[file exists $old_pwd]} {
            cd $old_pwd
        } else {
            cd $repo_root
        }
        error $err
    }
    if {[file exists $old_pwd]} {
        cd $old_pwd
    } else {
        cd $repo_root
    }
}

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

set sim_runtime [lindex $argv 1]
if {$sim_runtime eq ""} {
    if {[info exists ::env(VIVADO_SIM_RUNTIME)] && $::env(VIVADO_SIM_RUNTIME) ne ""} {
        set sim_runtime $::env(VIVADO_SIM_RUNTIME)
    } elseif {$sim_top eq "tb_i2c_register_master"} {
        set sim_runtime all
    } else {
        set sim_runtime 10ms
    }
}

set valid_tops {tb_myCPU tb_top tb_uart tb_i2c_register_master}
if {[lsearch -exact $valid_tops $sim_top] < 0} {
    puts "ERROR: invalid simulation top '$sim_top'. Expected one of: $valid_tops"
    exit 1
}

if {![file exists $project_path]} {
    puts "INFO: project not found; recreating it first"
    source [file join $script_dir create_project.tcl]
    open_project $project_path
} elseif {[llength [get_projects -quiet]] == 0} {
    open_project $project_path
}

set i2c_tb [string map {\\ /} [file join $repo_root tb tb_i2c_register_master.sv]]
if {[file exists $i2c_tb] && [llength [get_files -quiet -all $i2c_tb]] == 0} {
    add_files -norecurse -fileset sim_1 $i2c_tb
}

set_property top $sim_top [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime $sim_runtime [get_filesets sim_1]
update_compile_order -fileset sim_1

set runtime $sim_runtime

puts "INFO: launching behavioral simulation top=$sim_top runtime=$runtime"
set use_native_launch 0
if {[info exists ::env(VIVADO_USE_NATIVE_LAUNCH)] && $::env(VIVADO_USE_NATIVE_LAUNCH) eq "1"} {
    set use_native_launch 1
}

if {$use_native_launch} {
    if {[catch {
        launch_simulation -simset sim_1 -mode behavioral
        set runtime_lc [string tolower $runtime]
        if {$runtime_lc eq "all" || $runtime_lc eq "-all" || $runtime_lc eq "runall"} {
            run -all
        } else {
            run $runtime
        }
        close_sim
    } err]} {
        puts "WARN: Vivado launch_simulation failed: $err"
        if {[catch {run_manual_xsim $repo_root $sim_top $runtime} fallback_err]} {
            puts "ERROR: simulation failed: $fallback_err"
            exit 1
        }
    }
} else {
    if {[catch {run_manual_xsim $repo_root $sim_top $runtime} fallback_err]} {
        puts "ERROR: simulation failed: $fallback_err"
        exit 1
    }
}

puts "INFO: simulation completed for $sim_top"
