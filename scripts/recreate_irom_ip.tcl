# Recreate the instruction ROM as a pipelined dual-port Block Memory Generator.
#
# Usage from repository root:
#   vivado -mode batch -source scripts/recreate_irom_ip.tcl
#
# The existing project must already exist. This script removes the old IROM
# customization and generated products, then creates the same module name with
# the clka/ena/addra/douta and clkb/enb/addrb/doutb ports required by student_top.

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
set project_name digital_twin
set project_dir  [file join $repo_root vivado]
set project_path [file join $project_dir ${project_name}.xpr]
set irom_ip_dir  [file join $project_dir ${project_name}.srcs sources_1 ip IROM]
set irom_xci     [file join $irom_ip_dir IROM IROM.xci]
set irom_coe     [file normalize [file join $repo_root sim coe mext irom-v2.coe]]

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
    puts "ERROR: run scripts/create_project.tcl first."
    exit 1
}

if {![file exists $irom_coe]} {
    puts "ERROR: IROM initialization file not found: $irom_coe"
    exit 1
}

if {[llength [current_project -quiet]] != 0} {
    close_project
}

open_project $project_path

set old_irom_ips [get_ips -quiet IROM]
if {[llength $old_irom_ips] != 0} {
    set old_ip_files [get_files -quiet -all -of_objects $old_irom_ips]
    if {[llength $old_ip_files] != 0} {
        remove_files -quiet $old_ip_files
    }
    remove_files -quiet $old_irom_ips
}

set old_irom_files [get_files -quiet -all [string map {\\ /} $irom_xci]]
if {[llength $old_irom_files] != 0} {
    remove_files -quiet $old_irom_files
}

file delete -force $irom_ip_dir
file mkdir $irom_ip_dir

# Vivado retains the removed module name in the in-memory IP catalog until the
# project is reopened.
close_project
open_project $project_path

create_ip -name blk_mem_gen -vendor xilinx.com -library ip -version 8.4 \
    -module_name IROM -dir $irom_ip_dir

set irom_ip [get_ips IROM]
set_property -dict [list \
    CONFIG.Component_Name {IROM} \
    CONFIG.Interface_Type {Native} \
    CONFIG.Memory_Type {Dual_Port_ROM} \
    CONFIG.PRIM_type_to_Implement {BRAM} \
    CONFIG.Assume_Synchronous_Clk {true} \
    CONFIG.Write_Width_A {32} \
    CONFIG.Write_Depth_A {4096} \
    CONFIG.Read_Width_A {32} \
    CONFIG.Read_Width_B {32} \
    CONFIG.Enable_A {Use_ENA_Pin} \
    CONFIG.Enable_B {Use_ENB_Pin} \
    CONFIG.Register_PortA_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortB_Output_of_Memory_Primitives {false} \
    CONFIG.Register_PortA_Output_of_Memory_Core {false} \
    CONFIG.Register_PortB_Output_of_Memory_Core {false} \
    CONFIG.Load_Init_File {true} \
    CONFIG.Coe_File $irom_coe \
    CONFIG.Port_A_Clock {240} \
    CONFIG.Port_B_Clock {240} \
    CONFIG.Fill_Remaining_Memory_Locations {true} \
    CONFIG.Remaining_Memory_Locations {0} \
    CONFIG.Use_RSTA_Pin {false} \
    CONFIG.Use_RSTB_Pin {false} \
] $irom_ip

# Generate the ROM with the top-level design so both ports inherit the actual
# CPU clock constraint instead of an independent OOC clock constraint.
set irom_xci_files [get_files -quiet -all [string map {\\ /} $irom_xci]]
if {[llength $irom_xci_files] == 0} {
    puts "ERROR: IROM XCI not found after create_ip"
    close_project
    exit 1
}
set_property GENERATE_SYNTH_CHECKPOINT false $irom_xci_files

generate_target all $irom_ip
export_ip_user_files -of_objects $irom_ip -no_script -sync -force -quiet
update_compile_order -fileset sources_1

set memory_type [get_property CONFIG.Memory_Type $irom_ip]
set depth       [get_property CONFIG.Write_Depth_A $irom_ip]
set width_a     [get_property CONFIG.Read_Width_A $irom_ip]
set width_b     [get_property CONFIG.Read_Width_B $irom_ip]
if {$memory_type ne "Dual_Port_ROM" || $depth ne "4096" ||
    $width_a ne "32" || $width_b ne "32"} {
    puts "ERROR: generated IROM configuration verification failed"
    puts "ERROR: Memory_Type=$memory_type Depth=$depth ReadWidthA=$width_a ReadWidthB=$width_b"
    close_project
    exit 1
}

close_project
puts "INFO: recreated IROM as a 4096x32 one-cycle dual-port blk_mem_gen ROM: $irom_xci"
