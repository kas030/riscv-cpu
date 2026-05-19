`timescale 1ns / 1ps
// =============================================================================
// myCPU_mem_stage.sv —— MEM（访存）级
//   - 把 EX/MEM 锁存出的专用访存地址副本送给外设/DRAM
//   - rs2 数据作为写数据送给外设；funct3 低 2 位作为字节使能 mask
//   - MEM_mdata 保留外设原始读数，符号扩展后移到 WB 级完成
// =============================================================================
module myCPU_mem_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] perip_rdata     ,        // 外设/DRAM 读返回数据
    input  logic [DATAWIDTH - 1:0] MEM_perip_addr  ,        // 独立访存地址副本
    input  logic [DATAWIDTH - 1:0] MEM_rR2_data    ,        // store 写数据
    input  logic [2:0]             MEM_funct3      ,
    input  logic                   MEM_MemWrite    ,
    output logic [DATAWIDTH - 1:0] perip_addr      ,
    output logic [DATAWIDTH - 1:0] perip_wdata     ,
    output logic [DATAWIDTH - 1:0] MEM_mdata       ,        // 外设/DRAM 原始读数
    output logic                   perip_wen       ,
    output logic [1:0]             perip_mask
);
    // 直连外设接口：地址 / 写使能 / 字节 mask / 写数据
    assign perip_addr  = MEM_perip_addr;
    assign perip_wen   = MEM_MemWrite;
    assign perip_mask  = MEM_funct3[1:0];
    assign perip_wdata = MEM_rR2_data;
    assign MEM_mdata   = perip_rdata;
endmodule
