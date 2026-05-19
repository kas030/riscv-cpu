# Recreate the Vivado project from repository sources.
#
# Usage:
#   vivado -mode batch -source scripts/create_project.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]

set project_name digital_twin
set project_dir  [file join $repo_root vivado]
set project_path [file join $project_dir ${project_name}.xpr]
set part_name    xc7k325tffg900-2

# Some local Vivado installs can fail to auto-discover Tcl Store support
# packages before creating/opening a project. Add known install-side package
# directories when they exist; this is harmless when Vivado is already set up.
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

proc add_existing_files {fileset files} {
    set existing {}
    foreach file_path $files {
        set normalized [file normalize $file_path]
        if {[file exists $normalized]} {
            lappend existing $normalized
        } else {
            puts "WARN: missing file skipped: $normalized"
        }
    }

    if {[llength $existing] != 0} {
        add_files -norecurse -fileset $fileset $existing
    }
}

proc import_existing_files {fileset files} {
    set existing {}
    foreach file_path $files {
        set normalized [file normalize $file_path]
        if {[file exists $normalized]} {
            lappend existing $normalized
        } else {
            puts "WARN: missing file skipped: $normalized"
        }
    }

    if {[llength $existing] != 0} {
        import_files -norecurse -fileset $fileset $existing
    }
}

proc glob_existing_files {patterns} {
    set files {}
    foreach pattern $patterns {
        foreach file_path [glob -nocomplain $pattern] {
            if {[file isfile $file_path]} {
                lappend files [file normalize $file_path]
            }
        }
    }
    return [lsort -unique $files]
}

if {[llength [current_project -quiet]] != 0} {
    close_project
}

file mkdir $project_dir

puts "INFO: creating project $project_path"
if {[catch {create_project -force $project_name $project_dir -part $part_name} err]} {
    puts "ERROR: failed to create project: $err"
    puts "ERROR: close any Vivado/XSim process using $project_dir and rerun this script."
    exit 1
}

set_property target_language Verilog [current_project]
set_property simulator_language Mixed [current_project]
set_property default_lib xil_defaultlib [current_project]
set_property source_mgmt_mode All [current_project]
set_property xsim.array_display_limit 1024 [current_project]
set_property xsim.radix hex [current_project]
set_property xsim.time_unit ns [current_project]
set_property xsim.trace_limit 65536 [current_project]

set rtl_files [glob_existing_files [list \
    [file join $repo_root rtl common *.v] \
    [file join $repo_root rtl common *.sv] \
    [file join $repo_root rtl control *.sv] \
    [file join $repo_root rtl datapath *.sv] \
    [file join $repo_root rtl hazard *.sv] \
    [file join $repo_root rtl memory *.sv] \
    [file join $repo_root rtl core *.sv] \
    [file join $repo_root rtl pipeline register *.sv] \
    [file join $repo_root rtl pipeline stage *.sv] \
    [file join $repo_root rtl bus *.sv] \
    [file join $repo_root rtl peripheral *.sv] \
    [file join $repo_root rtl soc *.sv] \
    [file join $repo_root rtl top *.sv] \
]]

set ip_files [list \
    [file join $repo_root ip IROM IROM.xci] \
    [file join $repo_root ip DRAM DRAM.xci] \
    [file join $repo_root ip pll pll.xci] \
]

set mem_files [glob_existing_files [list \
    [file join $repo_root sim coe *.coe] \
    [file join $repo_root vivado tests build *.coe] \
    [file join $repo_root vivado tests build *.mif] \
    [file join $repo_root vivado *.mif] \
]]

add_existing_files sources_1 [concat $mem_files $rtl_files]
import_existing_files sources_1 $ip_files

set imported_coe_dir [file join $project_dir ${project_name}.srcs sources_1 sim coe]
file mkdir $imported_coe_dir
foreach coe_file [glob_existing_files [list [file join $repo_root sim coe *.coe]]] {
    file copy -force $coe_file [file join $imported_coe_dir [file tail $coe_file]]
}

set_property include_dirs [list [file normalize [file join $repo_root rtl common]]] [get_filesets sources_1]
set_property top top [get_filesets sources_1]

add_existing_files constrs_1 [list [file join $repo_root constraints digital_twin.xdc]]

set sim_files [list \
    [file join $repo_root tb tb_myCPU.sv] \
    [file join $repo_root tb tb_top.sv] \
    [file join $repo_root tb tb_uart.sv] \
]
set wcfg_files [glob_existing_files [list [file join $repo_root sim wcfg *.wcfg]]]
add_existing_files sim_1 [concat $sim_files $wcfg_files]
set_property top tb_myCPU [get_filesets sim_1]
set_property top_lib xil_defaultlib [get_filesets sim_1]
set_property xsim.simulate.runtime 10us [get_filesets sim_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1

set xci_files [get_files -quiet *.xci]
if {[llength $xci_files] != 0} {
    puts "INFO: generating IP output products"
    generate_target all $xci_files
    export_ip_user_files -of_objects $xci_files -no_script -sync -force -quiet
}

close_project

if {[file exists $project_path]} {
    set fp [open $project_path r]
    set xpr_text [read $fp]
    close $fp

    set xpr_text [string map {"    <Option Name=\"BoardPart\" Val=\"\"/>\n" ""} $xpr_text]

    set fp [open $project_path w]
    puts -nonewline $fp $xpr_text
    close $fp
}

puts "INFO: project recreated: $project_path"
