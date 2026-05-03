`timescale 1ns / 1ps
// =============================================================================
// myCPU_mem_stage.sv —— MEM（访存）级
//   - 把 EX 级算出的 alu_result 当作访存地址送给外设/DRAM
//   - rs2 数据作为写数据送给外设；funct3 低 2 位作为字节使能 mask
//   - 外设返回的 rdata 经 Mask 模块做子字符号扩展后输出 MEM_mdata
//   - 顺手用 MemToReg 选好"前递候选" MEM_forward_data，让非 ALU 结果类指令
//     （auipc/lui/jal/jalr/csr）也能享受 EX-EX 前递路径
// =============================================================================
module myCPU_mem_stage #(
    parameter DATAWIDTH = 32
) (
    input  logic [DATAWIDTH - 1:0] perip_rdata     ,        // 外设/DRAM 读返回数据
    input  logic [DATAWIDTH - 1:0] MEM_pcadd4      ,
    input  logic [DATAWIDTH - 1:0] MEM_alu_result  ,        // 访存地址 / 普通运算结果
    input  logic [DATAWIDTH - 1:0] MEM_rR2_data    ,        // store 写数据
    input  logic [DATAWIDTH - 1:0] MEM_imm         ,
    input  logic [DATAWIDTH - 1:0] MEM_csr_wb      ,
    input  logic [2:0]             MEM_MemToReg    ,        // WB 级 5 路选择，提前用来选前递
    input  logic [2:0]             MEM_funct3      ,
    input  logic                   MEM_MemWrite    ,
    output logic [DATAWIDTH - 1:0] perip_addr      ,
    output logic [DATAWIDTH - 1:0] perip_wdata     ,
    output logic [DATAWIDTH - 1:0] MEM_mdata       ,        // 子字符号扩展后的 load 数据
    output logic [DATAWIDTH - 1:0] MEM_forward_data,        // EX-EX 前递候选
    output logic                   perip_wen       ,
    output logic [1:0]             perip_mask
);
    // 选好本指令在 WB 阶段会写回的"非 load"数据，作为前递候选送回 EX 级
    //   3'b100 csr / 3'b011 imm(lui) / 3'b000 pcadd4(jal·jalr) / 其它走 alu_result
    assign MEM_forward_data = (MEM_MemToReg == 3'b100) ? MEM_csr_wb     :
                              (MEM_MemToReg == 3'b011) ? MEM_imm        :
                              (MEM_MemToReg == 3'b000) ? MEM_pcadd4     :
                                                         MEM_alu_result ;

    // 直连外设接口：地址 / 写使能 / 字节 mask / 写数据
    assign perip_addr  = MEM_alu_result;
    assign perip_wen   = MEM_MemWrite;
    assign perip_mask  = MEM_funct3[1:0];
    assign perip_wdata = MEM_rR2_data;

    // 子字符号扩展（lb / lh / 其它）
    Mask #(DATAWIDTH) u_mask (
        .mask  (MEM_funct3 ),
        .dout  (perip_rdata),
        .mdata (MEM_mdata  )
    );
endmodule
