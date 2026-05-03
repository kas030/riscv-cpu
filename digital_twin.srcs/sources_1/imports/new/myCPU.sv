`timescale 1ns / 1ps
module myCPU (
    input  logic         cpu_rst,
    input  logic         cpu_clk,

    // Interface to IROM
    output logic [31:0]  irom_addr,
    input  logic [31:0]  irom_data,

    // Interface to DRAM
    output logic [31:0]  perip_addr,
    output logic         perip_wen,
    output logic [ 1:0]  perip_mask,
    output logic [31:0]  perip_wdata,
    input  logic [31:0]  perip_rdata
);
    parameter   DATAWIDTH = 32;
    parameter   RESET_VAL = 32'h8000_0000;
    parameter   ADDR_WIDTH = 5;

    logic clk, rst;
    assign clk = cpu_clk;
    assign rst = cpu_rst;

    // ==========================================
    // Hazard & Forwarding signals
    // ==========================================
    logic        Stall, Flush_IF_ID, Flush_ID_EX;
    logic [1:0]  ForwardA, ForwardB;
    logic        BranchTaken;

    // ==========================================
    // IF stage signals
    // ==========================================
    logic [31:0] IF_pc, IF_npc_redirect, IF_instr;

    // ==========================================
    // IF/ID register outputs
    // ==========================================
    logic [31:0] ID_pc, ID_instr;

    // ==========================================
    // ID stage signals
    // ==========================================
    logic [31:0] ID_imm, ID_rR1_data, ID_rR2_data;
    logic        ID_RegWrite, ID_MemWrite, ID_MemRead, ID_isCSR;
    logic        ID_ALUSrcA, ID_ALUSrcB;
    logic [2:0]  ID_MemToReg;
    logic [1:0]  ID_NpcOp, ID_OffsetOrigin;
    logic [13:0] ID_ALUControl;
    logic [11:0] ID_csr_idx;
    logic [3:0]  ID_CSRControll;
    logic [2:0]  ID_funct3;
    logic [4:0]  ID_rs1, ID_rs2, ID_rd;

    // ==========================================
    // ID/EX register outputs
    // ==========================================
    logic [31:0] EX_pc, EX_imm, EX_rR1_data, EX_rR2_data;
    logic [4:0]  EX_rs1, EX_rs2, EX_rd;
    logic        EX_RegWrite, EX_MemWrite, EX_MemRead, EX_isCSR;
    logic [2:0]  EX_MemToReg, EX_funct3;
    logic        EX_ALUSrcA, EX_ALUSrcB;
    logic [13:0] EX_ALUControl;
    logic [1:0]  EX_NpcOp, EX_OffsetOrigin;
    logic [11:0] EX_csr_idx;
    logic [3:0]  EX_CSRControll;

    // ==========================================
    // EX stage signals
    // ==========================================
    logic [31:0] EX_alu_result, EX_forward_B_out;
    logic [31:0] EX_csr_wb;

    // ==========================================
    // EX/MEM register outputs
    // ==========================================
    logic [31:0] MEM_pcadd4, MEM_alu_result, MEM_rR2_data, MEM_imm;
    logic [4:0]  MEM_rd;
    logic        MEM_RegWrite, MEM_MemWrite, MEM_MemRead, MEM_isCSR;
    logic [2:0]  MEM_MemToReg, MEM_funct3;
    logic [31:0] MEM_csr_wb;

    // ==========================================
    // MEM stage signals
    // ==========================================
    logic [31:0] MEM_mdata;

    // ==========================================
    // MEM/WB register outputs
    // ==========================================
    logic [31:0] WB_pcadd4, WB_alu_result, WB_mdata, WB_imm;
    logic [4:0]  WB_rd;
    logic        WB_RegWrite;
    logic [2:0]  WB_MemToReg;
    logic [31:0] WB_csr_wb;

    // ==========================================
    // WB stage signals
    // ==========================================
    logic [31:0] WB_wdata;

    // ==========================================
    // MEM stage forwarding data
    // ==========================================
    logic [31:0] MEM_forward_data;

    // ==========================================
    // Hazard Unit
    // ==========================================
    HazardUnit hazard_unit (
        .IF_ID_rs1     (ID_instr[19:15]),
        .IF_ID_rs2     (ID_instr[24:20]),
        .ID_EX_rd      (EX_rd),
        .ID_EX_MemRead (EX_MemRead),
        .BranchTaken   (BranchTaken),
        .Stall         (Stall),
        .Flush_IF_ID   (Flush_IF_ID),
        .Flush_ID_EX   (Flush_ID_EX)
    );

    // ==========================================
    // Forwarding Unit
    // ==========================================
    ForwardingUnit forward_unit (
        .ID_EX_rs1        (EX_rs1),
        .ID_EX_rs2        (EX_rs2),
        .EX_MEM_rd        (MEM_rd),
        .EX_MEM_RegWrite  (MEM_RegWrite),
        .MEM_WB_rd        (WB_rd),
        .MEM_WB_RegWrite  (WB_RegWrite),
        .ForwardA         (ForwardA),
        .ForwardB         (ForwardB)
    );

    // ==========================================
    // STAGE 1: IF (Instruction Fetch)
    // ==========================================
    myCPU_if_stage #(DATAWIDTH, RESET_VAL) if_stage_inst (
        .irom_data        (irom_data),
        .IF_npc_redirect  (IF_npc_redirect),
        .clk              (clk),
        .rst              (rst),
        .Stall            (Stall),
        .BranchTaken      (BranchTaken),
        .irom_addr        (irom_addr),
        .IF_pc            (IF_pc),
        .IF_instr         (IF_instr)
    );

    // ==========================================
    // IF/ID Pipeline Register
    // ==========================================
    myCPU_if_id_reg #(DATAWIDTH) if_id_reg_inst (
        .clk         (clk),
        .rst         (rst),
        .Flush_IF_ID (Flush_IF_ID),
        .Stall       (Stall),
        .IF_pc       (IF_pc),
        .IF_instr    (IF_instr),
        .ID_pc       (ID_pc),
        .ID_instr    (ID_instr)
    );

    // ==========================================
    // STAGE 2: ID (Instruction Decode)
    // ==========================================
    myCPU_id_stage #(DATAWIDTH) id_stage_inst (
        .ID_instr        (ID_instr),
        .ID_imm          (ID_imm),
        .ID_RegWrite     (ID_RegWrite),
        .ID_MemWrite     (ID_MemWrite),
        .ID_MemRead      (ID_MemRead),
        .ID_isCSR        (ID_isCSR),
        .ID_ALUSrcA      (ID_ALUSrcA),
        .ID_ALUSrcB      (ID_ALUSrcB),
        .ID_MemToReg     (ID_MemToReg),
        .ID_NpcOp        (ID_NpcOp),
        .ID_OffsetOrigin (ID_OffsetOrigin),
        .ID_ALUControl   (ID_ALUControl),
        .ID_csr_idx      (ID_csr_idx),
        .ID_CSRControll  (ID_CSRControll),
        .ID_funct3       (ID_funct3),
        .ID_rs1          (ID_rs1),
        .ID_rs2          (ID_rs2),
        .ID_rd           (ID_rd)
    );

    RF #(ADDR_WIDTH, DATAWIDTH) rf_inst (
        .clk      (clk),
        .rst      (rst),
        .wen      (WB_RegWrite),
        .waddr    (WB_rd),
        .wdata    (WB_wdata),
        .rR1      (ID_rs1),
        .rR2      (ID_rs2),
        .rR1_data (ID_rR1_data),
        .rR2_data (ID_rR2_data)
    );

    // ==========================================
    // ID/EX Pipeline Register
    // ==========================================
    myCPU_id_ex_reg #(DATAWIDTH, ADDR_WIDTH) id_ex_reg_inst (
        .ID_pc           (ID_pc),
        .ID_imm          (ID_imm),
        .ID_rR1_data     (ID_rR1_data),
        .ID_rR2_data     (ID_rR2_data),
        .ID_rs1          (ID_rs1),
        .ID_rs2          (ID_rs2),
        .ID_rd           (ID_rd),
        .ID_RegWrite     (ID_RegWrite),
        .ID_MemWrite     (ID_MemWrite),
        .ID_MemRead      (ID_MemRead),
        .ID_isCSR        (ID_isCSR),
        .ID_MemToReg     (ID_MemToReg),
        .ID_funct3       (ID_funct3),
        .ID_ALUSrcA      (ID_ALUSrcA),
        .ID_ALUSrcB      (ID_ALUSrcB),
        .ID_ALUControl   (ID_ALUControl),
        .ID_NpcOp        (ID_NpcOp),
        .ID_OffsetOrigin (ID_OffsetOrigin),
        .ID_csr_idx      (ID_csr_idx),
        .ID_CSRControll  (ID_CSRControll),
        .clk             (clk),
        .rst             (rst),
        .Flush_ID_EX     (Flush_ID_EX),
        .EX_pc           (EX_pc),
        .EX_imm          (EX_imm),
        .EX_rR1_data     (EX_rR1_data),
        .EX_rR2_data     (EX_rR2_data),
        .EX_rs1          (EX_rs1),
        .EX_rs2          (EX_rs2),
        .EX_rd           (EX_rd),
        .EX_RegWrite     (EX_RegWrite),
        .EX_MemWrite     (EX_MemWrite),
        .EX_MemRead      (EX_MemRead),
        .EX_isCSR        (EX_isCSR),
        .EX_MemToReg     (EX_MemToReg),
        .EX_funct3       (EX_funct3),
        .EX_ALUSrcA      (EX_ALUSrcA),
        .EX_ALUSrcB      (EX_ALUSrcB),
        .EX_ALUControl   (EX_ALUControl),
        .EX_NpcOp        (EX_NpcOp),
        .EX_OffsetOrigin (EX_OffsetOrigin),
        .EX_csr_idx      (EX_csr_idx),
        .EX_CSRControll  (EX_CSRControll)
    );

    // ==========================================
    // STAGE 3: EX (Execute)
    // ==========================================
    myCPU_ex_stage #(DATAWIDTH) ex_stage_inst (
        .MEM_forward_data (MEM_forward_data),
        .WB_wdata         (WB_wdata),
        .EX_pc            (EX_pc),
        .EX_imm           (EX_imm),
        .EX_rR1_data      (EX_rR1_data),
        .EX_rR2_data      (EX_rR2_data),
        .EX_ALUControl    (EX_ALUControl),
        .EX_NpcOp         (EX_NpcOp),
        .EX_OffsetOrigin  (EX_OffsetOrigin),
        .EX_csr_idx       (EX_csr_idx),
        .EX_CSRControll   (EX_CSRControll),
        .ForwardA         (ForwardA),
        .ForwardB         (ForwardB),
        .EX_ALUSrcA       (EX_ALUSrcA),
        .EX_ALUSrcB       (EX_ALUSrcB),
        .clk              (clk),
        .rst              (rst),
        .IF_npc_redirect  (IF_npc_redirect),
        .EX_alu_result    (EX_alu_result),
        .EX_forward_B_out (EX_forward_B_out),
        .EX_csr_wb        (EX_csr_wb),
        .BranchTaken      (BranchTaken)
    );

    // ==========================================
    // EX/MEM Pipeline Register
    // ==========================================
    myCPU_ex_mem_reg #(DATAWIDTH, ADDR_WIDTH) ex_mem_reg_inst (
        .EX_pc            (EX_pc),
        .EX_alu_result    (EX_alu_result),
        .EX_forward_B_out (EX_forward_B_out),
        .EX_imm           (EX_imm),
        .EX_csr_wb        (EX_csr_wb),
        .EX_rd            (EX_rd),
        .EX_RegWrite      (EX_RegWrite),
        .EX_MemWrite      (EX_MemWrite),
        .EX_MemRead       (EX_MemRead),
        .EX_isCSR         (EX_isCSR),
        .EX_MemToReg      (EX_MemToReg),
        .EX_funct3        (EX_funct3),
        .clk              (clk),
        .rst              (rst),
        .MEM_pcadd4       (MEM_pcadd4),
        .MEM_alu_result   (MEM_alu_result),
        .MEM_rR2_data     (MEM_rR2_data),
        .MEM_imm          (MEM_imm),
        .MEM_csr_wb       (MEM_csr_wb),
        .MEM_rd           (MEM_rd),
        .MEM_RegWrite     (MEM_RegWrite),
        .MEM_MemWrite     (MEM_MemWrite),
        .MEM_MemRead      (MEM_MemRead),
        .MEM_isCSR        (MEM_isCSR),
        .MEM_MemToReg     (MEM_MemToReg),
        .MEM_funct3       (MEM_funct3)
    );

    // ==========================================
    // STAGE 4: MEM (Memory Access)
    // ==========================================
    myCPU_mem_stage #(DATAWIDTH) mem_stage_inst (
        .perip_rdata      (perip_rdata),
        .MEM_pcadd4       (MEM_pcadd4),
        .MEM_alu_result   (MEM_alu_result),
        .MEM_rR2_data     (MEM_rR2_data),
        .MEM_imm          (MEM_imm),
        .MEM_csr_wb       (MEM_csr_wb),
        .MEM_MemToReg     (MEM_MemToReg),
        .MEM_funct3       (MEM_funct3),
        .MEM_MemWrite     (MEM_MemWrite),
        .perip_addr       (perip_addr),
        .perip_wdata      (perip_wdata),
        .MEM_mdata        (MEM_mdata),
        .MEM_forward_data (MEM_forward_data),
        .perip_wen        (perip_wen),
        .perip_mask       (perip_mask)
    );

    // ==========================================
    // MEM/WB Pipeline Register
    // ==========================================
    myCPU_mem_wb_reg #(DATAWIDTH, ADDR_WIDTH) mem_wb_reg_inst (
        .MEM_pcadd4     (MEM_pcadd4),
        .MEM_alu_result (MEM_alu_result),
        .MEM_mdata      (MEM_mdata),
        .MEM_imm        (MEM_imm),
        .MEM_csr_wb     (MEM_csr_wb),
        .MEM_rd         (MEM_rd),
        .MEM_RegWrite   (MEM_RegWrite),
        .MEM_MemToReg   (MEM_MemToReg),
        .clk            (clk),
        .rst            (rst),
        .WB_pcadd4      (WB_pcadd4),
        .WB_alu_result  (WB_alu_result),
        .WB_mdata       (WB_mdata),
        .WB_imm         (WB_imm),
        .WB_csr_wb      (WB_csr_wb),
        .WB_rd          (WB_rd),
        .WB_RegWrite    (WB_RegWrite),
        .WB_MemToReg    (WB_MemToReg)
    );

    // ==========================================
    // STAGE 5: WB (Write Back)
    // ==========================================
    myCPU_wb_stage #(DATAWIDTH) wb_stage_inst (
        .WB_pcadd4     (WB_pcadd4),
        .WB_alu_result (WB_alu_result),
        .WB_mdata      (WB_mdata),
        .WB_imm        (WB_imm),
        .WB_csr_wb     (WB_csr_wb),
        .WB_MemToReg   (WB_MemToReg),
        .WB_wdata      (WB_wdata)
    );

endmodule
