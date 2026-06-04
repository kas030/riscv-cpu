# Recreate the data memory IP as a Block Memory Generator.
#
# Usage from repository root:
#   vivado -mode batch -source scripts/recreate_dram_bram_ip.tcl
#
# This script intentionally keeps the IP/module name as DRAM so existing RTL
# instantiations, hierarchy references, and project file references stay stable.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set project_name digital_twin
set project_dir  [file join $repo_root vivado]
set project_path [file join $project_dir ${project_name}.xpr]
set dram_ip_dir  [file join $project_dir ${project_name}.srcs sources_1 ip DRAM]
set dram_xci     [file join $dram_ip_dir DRAM.xci]
set dram_coe     [file normalize [file join $repo_root sim coe dram.coe]]

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

set old_dram_ips [get_ips -quiet DRAM]
if {[llength $old_dram_ips] != 0} {
    set old_ip_files [get_files -quiet -all -of_objects $old_dram_ips]
    if {[llength $old_ip_files] != 0} {
        remove_files -quiet $old_ip_files
    }
    remove_files -quiet $old_dram_ips
}

set old_dram_files [get_files -quiet -all $dram_xci]
if {[llength $old_dram_files] != 0} {
    remove_files -quiet $old_dram_files
}

file delete -force $dram_ip_dir
file mkdir $dram_ip_dir

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name DRAM -dir $dram_ip_dir

set dram_ip [get_ips DRAM]
set_property -dict [list \
    CONFIG.Component_Name {DRAM} \
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
    CONFIG.Coe_File $dram_coe \
    CONFIG.Fill_Remaining_Memory_Locations {true} \
    CONFIG.Remaining_Memory_Locations {0} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] $dram_ip

generate_target all $dram_ip
export_ip_user_files -of_objects $dram_ip -no_script -sync -force -quiet
update_compile_order -fileset sources_1

close_project
puts "INFO: recreated DRAM as blk_mem_gen true dual-port BRAM: $dram_xci"
