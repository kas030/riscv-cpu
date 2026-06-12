`timescale 1ns / 1ps
// =============================================================================
// mycpu_mem_stage.sv —— MEM（访存）级
//   - 把 EX/MEM 锁存出的专用访存地址副本送给外设/BRAM
//   - rs2 数据作为写数据送给外设；funct3 低 2 位作为字节使能 mask
//   - MEM_mdata 保留外设原始读数，符号扩展后移到 WB 级完成
// =============================================================================
module mycpu_mem_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] perip_rdata     ,        // 外设/BRAM 读返回数据
    input  logic [DATAWIDTH - 1:0] MEM_perip_addr  ,        // 独立访存地址副本
    input  logic [DATAWIDTH - 1:0] MEM_rR2_data    ,        // store 写数据
    input  logic [2:0]             MEM_funct3      ,
    input  logic                   MEM_MemWrite    ,
    output logic [DATAWIDTH - 1:0] perip_addr      ,
    output logic [DATAWIDTH - 1:0] perip_wdata     ,
    output logic [DATAWIDTH - 1:0] MEM_mdata       ,        // 外设/BRAM 原始读数
    output logic                   perip_wen       ,
    output logic [1:0]             perip_mask
);
    mycpu_lsu #(DATAWIDTH) u_lsu (
        .lsu_addr_i   (MEM_perip_addr),
        .store_data_i (MEM_rR2_data  ),
        .funct3_i     (MEM_funct3    ),
        .mem_write_i  (MEM_MemWrite  ),
        .bus_rdata_i  (perip_rdata   ),
        .bus_addr_o   (perip_addr    ),
        .bus_wen_o    (perip_wen     ),
        .bus_mask_o   (perip_mask    ),
        .bus_wdata_o  (perip_wdata   ),
        .load_raw_o   (MEM_mdata     )
    );
endmodule
