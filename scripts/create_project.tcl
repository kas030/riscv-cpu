# Recreate the Vivado project from repository sources.
#
# Usage:
#   vivado -mode batch -source scripts/create_project.tcl

set script_dir [file dirname [file normalize [info script]]]
set repo_root  [file dirname $script_dir]
if {[info exists ::env(CODEX_REPO_ROOT)] && [file exists [file join $::env(CODEX_REPO_ROOT) AGENTS.md]]} {
    set repo_root [string map {\\ /} $::env(CODEX_REPO_ROOT)]
    set script_dir [file join $repo_root scripts]
} elseif {[file exists [file join [pwd] AGENTS.md]]} {
    set repo_root [file normalize [pwd]]
    set script_dir [file join $repo_root scripts]
}

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
        set normalized [string map {\\ /} $file_path]
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
        set normalized [string map {\\ /} $file_path]
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
                lappend files [string map {\\ /} $file_path]
            }
        }
    }
    return [lsort -unique $files]
}

proc create_pll_ip {project_dir project_name} {
    set pll_ip_dir [file join $project_dir ${project_name}.srcs sources_1 ip pll]
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
}

proc create_irom_ip {project_dir project_name repo_root} {
    set irom_ip_dir [file join $project_dir ${project_name}.srcs sources_1 ip IROM]
    set irom_coe [string map {\\ /} [file join $repo_root rt-thread bsp mycpu build rtthread.irom.coe]]
    file delete -force $irom_ip_dir
    file mkdir $irom_ip_dir

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
        CONFIG.Write_Depth_A {16384} \
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
        CONFIG.Port_A_Clock {200} \
        CONFIG.Port_B_Clock {200} \
        CONFIG.Fill_Remaining_Memory_Locations {true} \
        CONFIG.Remaining_Memory_Locations {0} \
        CONFIG.Use_RSTA_Pin {false} \
        CONFIG.Use_RSTB_Pin {false} \
    ] $irom_ip

    set irom_xci_path [string map {\\ /} [file join $irom_ip_dir IROM IROM.xci]]
    set irom_xci [get_files -quiet -all $irom_xci_path]
    if {[llength $irom_xci] == 0} {
        error "IROM XCI not found after create_ip"
    }
    set_property GENERATE_SYNTH_CHECKPOINT false $irom_xci
}

proc create_bram_ip {project_dir project_name repo_root} {
    set bram_ip_dir [file join $project_dir ${project_name}.srcs sources_1 ip BRAM]
    set bram_coe [string map {\\ /} [file join $repo_root rt-thread bsp mycpu build rtthread.bram.coe]]
    file delete -force $bram_ip_dir
    file mkdir $bram_ip_dir

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

    # blk_mem_gen 8.4 does not expose a reliable native-port OOC clock-period
    # property: its generated BRAM_ooc.xdc can remain at the 20 ns default even
    # when Port_A/B_Clock are set to 200 MHz. Synthesize BRAM with the top level
    # so clka/clkb inherit the real 5 ns cpu clock and no stale 50 MHz DCP is used.
    set bram_xci_path [string map {\\ /} [file join $bram_ip_dir BRAM BRAM.xci]]
    set bram_xci [get_files -quiet -all $bram_xci_path]
    if {[llength $bram_xci] == 0} {
        error "BRAM XCI not found after create_ip"
    }
    set_property GENERATE_SYNTH_CHECKPOINT false $bram_xci
}

if {[llength [get_projects -quiet]] != 0} {
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

set mem_files [glob_existing_files [list \
    [file join $repo_root sim coe *.coe] \
    [file join $repo_root sim coe mext *.coe] \
    [file join $repo_root vivado tests build *.coe] \
    [file join $repo_root vivado tests build *.mif] \
    [file join $repo_root vivado *.mif] \
]]

add_existing_files sources_1 [concat $mem_files $rtl_files]
create_irom_ip $project_dir $project_name $repo_root
create_bram_ip $project_dir $project_name $repo_root
create_pll_ip $project_dir $project_name

set imported_coe_dir [file join $project_dir ${project_name}.srcs sources_1 sim coe]
file mkdir $imported_coe_dir
foreach coe_file [glob_existing_files [list [file join $repo_root sim coe *.coe]]] {
    file copy -force $coe_file [file join $imported_coe_dir [file tail $coe_file]]
}
set imported_mext_coe_dir [file join $imported_coe_dir mext]
file mkdir $imported_mext_coe_dir
foreach coe_file [glob_existing_files [list [file join $repo_root sim coe mext *.coe]]] {
    file copy -force $coe_file [file join $imported_mext_coe_dir [file tail $coe_file]]
}

set_property include_dirs [list [string map {\\ /} [file join $repo_root rtl common]]] [get_filesets sources_1]
set_property top top [get_filesets sources_1]

add_existing_files constrs_1 [list [file join $repo_root constraints digital_twin.xdc]]

set sim_files [list \
    [file join $repo_root tb tb_myCPU.sv] \
    [file join $repo_root tb tb_top.sv] \
    [file join $repo_root tb tb_uart.sv] \
    [file join $repo_root tb tb_i2c_register_master.sv] \
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

set irom_ip [get_ips -quiet IROM]
set irom_memory_type [get_property CONFIG.Memory_Type $irom_ip]
set irom_depth       [get_property CONFIG.Write_Depth_A $irom_ip]
set irom_width_a     [get_property CONFIG.Read_Width_A $irom_ip]
set irom_width_b     [get_property CONFIG.Read_Width_B $irom_ip]
set irom_addra_width [get_property CONFIG.C_ADDRA_WIDTH $irom_ip]
set irom_addrb_width [get_property CONFIG.C_ADDRB_WIDTH $irom_ip]
if {$irom_memory_type ne "Dual_Port_ROM" || $irom_depth ne "16384" ||
    $irom_width_a ne "32" || $irom_width_b ne "32" ||
    $irom_addra_width ne "14" || $irom_addrb_width ne "14"} {
    error "IROM generation failed: Memory_Type=$irom_memory_type Depth=$irom_depth ReadWidthA=$irom_width_a ReadWidthB=$irom_width_b AddraWidth=$irom_addra_width AddrbWidth=$irom_addrb_width"
}
puts "INFO: verified IROM: 16384x32, addra/addrb are 14 bits"

set coe_files [get_files -quiet *.coe]
if {[llength $coe_files] != 0} {
    set_property USED_IN {synthesis implementation} $coe_files
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
