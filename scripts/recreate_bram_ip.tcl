# Recreate the data memory IP as a Block Memory Generator.
#
# Usage from repository root:
#   vivado -mode batch -source scripts/recreate_bram_ip.tcl
#
# This script recreates the data-memory IP/module with the BRAM name used by RTL.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set project_name digital_twin
set project_dir  [file join $repo_root vivado]
set project_path [file join $project_dir ${project_name}.xpr]
set bram_ip_dir  [file join $project_dir ${project_name}.srcs sources_1 ip BRAM]
set bram_xci     [file join $bram_ip_dir BRAM BRAM.xci]
set bram_coe     [file normalize [file join $repo_root rt-thread bsp mycpu build rtthread.bram.coe]]
set legacy_ip_name [format "%s%s" D RAM]
set legacy_ip_dir  [file join $project_dir ${project_name}.srcs sources_1 ip $legacy_ip_name]
set legacy_xci     [file join $legacy_ip_dir ${legacy_ip_name}.xci]

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

if {![file exists $project_path]} {
    puts "ERROR: project not found: $project_path"
    puts "ERROR: run scripts/create_project.tcl first, or open/create the project in Vivado."
    exit 1
}

if {[llength [current_project -quiet]] != 0} {
    close_project
}

open_project $project_path

set old_legacy_ips [get_ips -quiet $legacy_ip_name]
if {[llength $old_legacy_ips] != 0} {
    set old_ip_files [get_files -quiet -all -of_objects $old_legacy_ips]
    if {[llength $old_ip_files] != 0} {
        remove_files -quiet $old_ip_files
    }
    remove_files -quiet $old_legacy_ips
}

set old_bram_ips [get_ips -quiet BRAM]
if {[llength $old_bram_ips] != 0} {
    set old_ip_files [get_files -quiet -all -of_objects $old_bram_ips]
    if {[llength $old_ip_files] != 0} {
        remove_files -quiet $old_ip_files
    }
    remove_files -quiet $old_bram_ips
}

set old_bram_files [get_files -quiet -all $bram_xci]
if {[llength $old_bram_files] != 0} {
    remove_files -quiet $old_bram_files
}

set old_legacy_files [get_files -quiet -all $legacy_xci]
if {[llength $old_legacy_files] != 0} {
    remove_files -quiet $old_legacy_files
}

file delete -force $legacy_ip_dir
file delete -force $bram_ip_dir
file mkdir $bram_ip_dir

# Vivado keeps an IP module-name reservation in the current in-memory project
# after remove_files. Reopen the project before recreating the same BRAM name.
close_project
open_project $project_path

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name BRAM -dir $bram_ip_dir

set bram_ip [get_ips BRAM]
set_property -dict [list \
    CONFIG.Component_Name {BRAM} \
    CONFIG.Interface_Type {Native} \
    CONFIG.Memory_Type {True_Dual_Port_RAM} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {65536} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Write_Width_B {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Operating_Mode_A {READ_FIRST} \
    CONFIG.Operating_Mode_B {READ_FIRST} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Use_Byte_Write_Enable {true} \
    CONFIG.Byte_Size {8} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortA_Output_of_Memory_Core {false} \
    CONFIG.Register_PortB_Output_of_Memory_Core {false} \
    CONFIG.Load_Init_File {true} \
    CONFIG.Coe_File $bram_coe \
    CONFIG.Port_A_Clock {200} \
    CONFIG.Port_B_Clock {200} \
    CONFIG.Fill_Remaining_Memory_Locations {true} \
    CONFIG.Remaining_Memory_Locations {0} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] $bram_ip

# BRAM_ooc.xdc, while this design drives clka/clkb with the 5 ns cpu clock.
set bram_xci_files [get_files -quiet -all [string map {\\ /} $bram_xci]]
if {[llength $bram_xci_files] == 0} {
    puts "ERROR: BRAM XCI not found after create_ip"
    close_project
    exit 1
}
set_property GENERATE_SYNTH_CHECKPOINT false $bram_xci_files

generate_target all $bram_ip
export_ip_user_files -of_objects $bram_ip -no_script -sync -force -quiet
update_compile_order -fileset sources_1

close_project
puts "INFO: recreated BRAM as globally synthesized blk_mem_gen true dual-port BRAM: $bram_xci"
