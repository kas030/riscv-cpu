`timescale 1ns / 1ps
// =============================================================================
// myCPU.sv —— RV32I CPU 顶层
//   将 5 级流水线的各 stage 模块、4 个流水寄存器、HazardUnit、ForwardingUnit、
//   寄存器堆按数据流方向连接起来。对外暴露的接口仅保留：
//     - cpu_clk / cpu_rst                     时钟与复位
//     - irom_addr / irom_data                 IROM 取指接口（同步只读）
//     - perip_addr / perip_wen / perip_mask /
//       perip_wdata / perip_rdata             外设/DRAM 访存接口
//   内部信号按 IF→ID→EX→MEM→WB 五级分组，每一组对应一个流水寄存器输出端，
//   命名沿用 `<stage>_<信号>` 以便与教材中的经典 5 级流水线对齐。
// =============================================================================
module myCPU (
    input  logic         cpu_rst   ,
    input  logic         cpu_clk   ,

    // ---- IROM 取指接口 ----
    output logic [31:0]  irom_addr ,
    input  logic [31:0]  irom_data ,

    // ---- 外设/DRAM 访存接口 ----
    output logic [31:0]  perip_addr  ,
    output logic         perip_wen   ,
    output logic [ 1:0]  perip_mask  ,
    output logic [31:0]  perip_wdata ,
    input  logic [31:0]  perip_rdata
);
    // ---- 通用参数 ----
    parameter DATAWIDTH  = 32;
    parameter RESET_VAL  = 32'h8000_0000;                   // PC 复位入口
    parameter ADDR_WIDTH = 5;                                // 寄存器堆地址宽度

    // 时钟/复位别名（保持与子模块端口命名一致）
    logic clk, rst;
    assign clk = cpu_clk;
    assign rst = cpu_rst;

    // -------------------------------------------------------------------------
    // Hazard / Forwarding 控制信号
    // -------------------------------------------------------------------------
    logic        Stall, Flush_IF_ID, Flush_ID_EX;
    logic [1:0]  ForwardA, ForwardB;
    logic        BranchTaken;

    // -------------------------------------------------------------------------
    // IF 级信号
    // -------------------------------------------------------------------------
    logic [31:0] IF_pc, IF_npc_redirect, IF_instr;

    // -------------------------------------------------------------------------
    // IF/ID 寄存器输出（即 ID 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] ID_pc, ID_instr;

    // -------------------------------------------------------------------------
    // ID 级信号
    // -------------------------------------------------------------------------
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

    // -------------------------------------------------------------------------
    // ID/EX 寄存器输出（即 EX 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] EX_pc, EX_imm, EX_rR1_data, EX_rR2_data;
    logic [4:0]  EX_rs1, EX_rs2, EX_rd;
    logic        EX_RegWrite, EX_MemWrite, EX_MemRead, EX_isCSR;
    logic [2:0]  EX_MemToReg, EX_funct3;
    logic        EX_ALUSrcA, EX_ALUSrcB;
    logic [13:0] EX_ALUControl;
    logic [1:0]  EX_NpcOp, EX_OffsetOrigin;
    logic [11:0] EX_csr_idx;
    logic [3:0]  EX_CSRControll;

    // -------------------------------------------------------------------------
    // EX 级输出
    // -------------------------------------------------------------------------
    logic [31:0] EX_alu_result, EX_forward_B_out;
    logic [31:0] EX_csr_wb;

    // -------------------------------------------------------------------------
    // EX/MEM 寄存器输出（即 MEM 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] MEM_pcadd4, MEM_alu_result, MEM_rR2_data, MEM_imm;
    logic [4:0]  MEM_rd;
    logic        MEM_RegWrite, MEM_MemWrite, MEM_MemRead, MEM_isCSR;
    logic [2:0]  MEM_MemToReg, MEM_funct3;
    logic [31:0] MEM_csr_wb;

    // MEM 级中转给 EX 级前递的候选数据 / load 子字结果
    logic [31:0] MEM_mdata;
    logic [31:0] MEM_forward_data;

    // -------------------------------------------------------------------------
    // MEM/WB 寄存器输出（即 WB 级输入）
    // -------------------------------------------------------------------------
    logic [31:0] WB_pcadd4, WB_alu_result, WB_mdata, WB_imm;
    logic [4:0]  WB_rd;
    logic        WB_RegWrite;
    logic [2:0]  WB_MemToReg;
    logic [31:0] WB_csr_wb;

    // -------------------------------------------------------------------------
    // WB 级输出（同时也是 RF 写口数据）
    // -------------------------------------------------------------------------
    logic [31:0] WB_wdata;

    // =========================================================================
    // 冒险检测 / 前递选择
    // =========================================================================
    HazardUnit u_hazard (
        .IF_ID_rs1     (ID_instr[19:15]),
        .IF_ID_rs2     (ID_instr[24:20]),
        .ID_EX_rd      (EX_rd          ),
        .ID_EX_MemRead (EX_MemRead     ),
        .BranchTaken   (BranchTaken    ),
        .Stall         (Stall          ),
        .Flush_IF_ID   (Flush_IF_ID    ),
        .Flush_ID_EX   (Flush_ID_EX    )
    );

    ForwardingUnit u_forward (
        .ID_EX_rs1       (EX_rs1      ),
        .ID_EX_rs2       (EX_rs2      ),
        .EX_MEM_rd       (MEM_rd      ),
        .EX_MEM_RegWrite (MEM_RegWrite),
        .MEM_WB_rd       (WB_rd       ),
        .MEM_WB_RegWrite (WB_RegWrite ),
        .ForwardA        (ForwardA    ),
        .ForwardB        (ForwardB    )
    );

    // =========================================================================
    // STAGE 1：IF（取指）
    // =========================================================================
    myCPU_if_stage #(DATAWIDTH, RESET_VAL) u_if_stage (
        .irom_data       (irom_data      ),
        .IF_npc_redirect (IF_npc_redirect),
        .clk             (clk            ),
        .rst             (rst            ),
        .Stall           (Stall          ),
        .BranchTaken     (BranchTaken    ),
        .irom_addr       (irom_addr      ),
        .IF_pc           (IF_pc          ),
        .IF_instr        (IF_instr       )
    );

    // ---- IF/ID 流水寄存器 ----
    myCPU_if_id_reg #(DATAWIDTH) u_if_id_reg (
        .clk         (clk        ),
        .rst         (rst        ),
        .Flush_IF_ID (Flush_IF_ID),
        .Stall       (Stall      ),
        .IF_pc       (IF_pc      ),
        .IF_instr    (IF_instr   ),
        .ID_pc       (ID_pc      ),
        .ID_instr    (ID_instr   )
    );

    // =========================================================================
    // STAGE 2：ID（译码）
    //   寄存器堆 RF 单独例化在顶层，写口取自 WB 级，读口直接出给 ID 级，
    //   形成 WB-ID 内部前递路径
    // =========================================================================
    myCPU_id_stage #(DATAWIDTH) u_id_stage (
        .ID_instr        (ID_instr       ),
        .ID_imm          (ID_imm         ),
        .ID_RegWrite     (ID_RegWrite    ),
        .ID_MemWrite     (ID_MemWrite    ),
        .ID_MemRead      (ID_MemRead     ),
        .ID_isCSR        (ID_isCSR       ),
        .ID_ALUSrcA      (ID_ALUSrcA     ),
        .ID_ALUSrcB      (ID_ALUSrcB     ),
        .ID_MemToReg     (ID_MemToReg    ),
        .ID_NpcOp        (ID_NpcOp       ),
        .ID_OffsetOrigin (ID_OffsetOrigin),
        .ID_ALUControl   (ID_ALUControl  ),
        .ID_csr_idx      (ID_csr_idx     ),
        .ID_CSRControll  (ID_CSRControll ),
        .ID_funct3       (ID_funct3      ),
        .ID_rs1          (ID_rs1         ),
        .ID_rs2          (ID_rs2         ),
        .ID_rd           (ID_rd          )
    );

    RF #(ADDR_WIDTH, DATAWIDTH) rf_inst (                  // 实例名沿用 rf_inst，testbench 层级引用依赖此名
        .clk      (clk        ),
        .rst      (rst        ),
        .wen      (WB_RegWrite),                            // 来自 WB 级
        .waddr    (WB_rd      ),
        .wdata    (WB_wdata   ),
        .rR1      (ID_rs1     ),
        .rR2      (ID_rs2     ),
        .rR1_data (ID_rR1_data),
        .rR2_data (ID_rR2_data)
    );

    // ---- ID/EX 流水寄存器 ----
    myCPU_id_ex_reg #(DATAWIDTH, ADDR_WIDTH) u_id_ex_reg (
        .ID_pc           (ID_pc          ),
        .ID_imm          (ID_imm         ),
        .ID_rR1_data     (ID_rR1_data    ),
        .ID_rR2_data     (ID_rR2_data    ),
        .ID_rs1          (ID_rs1         ),
        .ID_rs2          (ID_rs2         ),
        .ID_rd           (ID_rd          ),
        .ID_RegWrite     (ID_RegWrite    ),
        .ID_MemWrite     (ID_MemWrite    ),
        .ID_MemRead      (ID_MemRead     ),
        .ID_isCSR        (ID_isCSR       ),
        .ID_MemToReg     (ID_MemToReg    ),
        .ID_funct3       (ID_funct3      ),
        .ID_ALUSrcA      (ID_ALUSrcA     ),
        .ID_ALUSrcB      (ID_ALUSrcB     ),
        .ID_ALUControl   (ID_ALUControl  ),
        .ID_NpcOp        (ID_NpcOp       ),
        .ID_OffsetOrigin (ID_OffsetOrigin),
        .ID_csr_idx      (ID_csr_idx     ),
        .ID_CSRControll  (ID_CSRControll ),
        .clk             (clk            ),
        .rst             (rst            ),
        .Flush_ID_EX     (Flush_ID_EX    ),
        .EX_pc           (EX_pc          ),
        .EX_imm          (EX_imm         ),
        .EX_rR1_data     (EX_rR1_data    ),
        .EX_rR2_data     (EX_rR2_data    ),
        .EX_rs1          (EX_rs1         ),
        .EX_rs2          (EX_rs2         ),
        .EX_rd           (EX_rd          ),
        .EX_RegWrite     (EX_RegWrite    ),
        .EX_MemWrite     (EX_MemWrite    ),
        .EX_MemRead      (EX_MemRead     ),
        .EX_isCSR        (EX_isCSR       ),
        .EX_MemToReg     (EX_MemToReg    ),
        .EX_funct3       (EX_funct3      ),
        .EX_ALUSrcA      (EX_ALUSrcA     ),
        .EX_ALUSrcB      (EX_ALUSrcB     ),
        .EX_ALUControl   (EX_ALUControl  ),
        .EX_NpcOp        (EX_NpcOp       ),
        .EX_OffsetOrigin (EX_OffsetOrigin),
        .EX_csr_idx      (EX_csr_idx     ),
        .EX_CSRControll  (EX_CSRControll )
    );

    // =========================================================================
    // STAGE 3：EX（执行）
    //   双路前递选择 → ALU + CSR + NPC 一起在 EX 级算完
    // =========================================================================
    myCPU_ex_stage #(DATAWIDTH) u_ex_stage (
        .MEM_forward_data (MEM_forward_data),
        .WB_wdata         (WB_wdata        ),
        .EX_pc            (EX_pc           ),
        .EX_imm           (EX_imm          ),
        .EX_rR1_data      (EX_rR1_data     ),
        .EX_rR2_data      (EX_rR2_data     ),
        .EX_ALUControl    (EX_ALUControl   ),
        .EX_NpcOp         (EX_NpcOp        ),
        .EX_OffsetOrigin  (EX_OffsetOrigin ),
        .EX_csr_idx       (EX_csr_idx      ),
        .EX_CSRControll   (EX_CSRControll  ),
        .ForwardA         (ForwardA        ),
        .ForwardB         (ForwardB        ),
        .EX_ALUSrcA       (EX_ALUSrcA      ),
        .EX_ALUSrcB       (EX_ALUSrcB      ),
        .clk              (clk             ),
        .rst              (rst             ),
        .IF_npc_redirect  (IF_npc_redirect ),
        .EX_alu_result    (EX_alu_result   ),
        .EX_forward_B_out (EX_forward_B_out),
        .EX_csr_wb        (EX_csr_wb       ),
        .BranchTaken      (BranchTaken     )
    );

    // ---- EX/MEM 流水寄存器 ----
    myCPU_ex_mem_reg #(DATAWIDTH, ADDR_WIDTH) u_ex_mem_reg (
        .EX_pc            (EX_pc           ),
        .EX_alu_result    (EX_alu_result   ),
        .EX_forward_B_out (EX_forward_B_out),
        .EX_imm           (EX_imm          ),
        .EX_csr_wb        (EX_csr_wb       ),
        .EX_rd            (EX_rd           ),
        .EX_RegWrite      (EX_RegWrite     ),
        .EX_MemWrite      (EX_MemWrite     ),
        .EX_MemRead       (EX_MemRead      ),
        .EX_isCSR         (EX_isCSR        ),
        .EX_MemToReg      (EX_MemToReg     ),
        .EX_funct3        (EX_funct3       ),
        .clk              (clk             ),
        .rst              (rst             ),
        .MEM_pcadd4       (MEM_pcadd4      ),
        .MEM_alu_result   (MEM_alu_result  ),
        .MEM_rR2_data     (MEM_rR2_data    ),
        .MEM_imm           (MEM_imm        ),
        .MEM_csr_wb       (MEM_csr_wb      ),
        .MEM_rd           (MEM_rd          ),
        .MEM_RegWrite     (MEM_RegWrite    ),
        .MEM_MemWrite     (MEM_MemWrite    ),
        .MEM_MemRead      (MEM_MemRead     ),
        .MEM_isCSR        (MEM_isCSR       ),
        .MEM_MemToReg     (MEM_MemToReg    ),
        .MEM_funct3       (MEM_funct3      )
    );

    // =========================================================================
    // STAGE 4：MEM（访存）
    //   外设/DRAM 直连；同时把 EX-EX 前递候选 MEM_forward_data 算好回传 EX 级
    // =========================================================================
    myCPU_mem_stage #(DATAWIDTH) u_mem_stage (
        .perip_rdata      (perip_rdata     ),
        .MEM_pcadd4       (MEM_pcadd4      ),
        .MEM_alu_result   (MEM_alu_result  ),
        .MEM_rR2_data     (MEM_rR2_data    ),
        .MEM_imm          (MEM_imm         ),
        .MEM_csr_wb       (MEM_csr_wb      ),
        .MEM_MemToReg     (MEM_MemToReg    ),
        .MEM_funct3       (MEM_funct3      ),
        .MEM_MemWrite     (MEM_MemWrite    ),
        .perip_addr       (perip_addr      ),
        .perip_wdata      (perip_wdata     ),
        .MEM_mdata        (MEM_mdata       ),
        .MEM_forward_data (MEM_forward_data),
        .perip_wen        (perip_wen       ),
        .perip_mask       (perip_mask      )
    );

    // ---- MEM/WB 流水寄存器 ----
    myCPU_mem_wb_reg #(DATAWIDTH, ADDR_WIDTH) u_mem_wb_reg (
        .MEM_pcadd4     (MEM_pcadd4    ),
        .MEM_alu_result (MEM_alu_result),
        .MEM_mdata      (MEM_mdata     ),
        .MEM_imm        (MEM_imm       ),
        .MEM_csr_wb     (MEM_csr_wb    ),
        .MEM_rd         (MEM_rd        ),
        .MEM_RegWrite   (MEM_RegWrite  ),
        .MEM_MemToReg   (MEM_MemToReg  ),
        .clk            (clk           ),
        .rst            (rst           ),
        .WB_pcadd4      (WB_pcadd4     ),
        .WB_alu_result  (WB_alu_result ),
        .WB_mdata       (WB_mdata      ),
        .WB_imm         (WB_imm        ),
        .WB_csr_wb      (WB_csr_wb     ),
        .WB_rd          (WB_rd         ),
        .WB_RegWrite    (WB_RegWrite   ),
        .WB_MemToReg    (WB_MemToReg   )
    );

    // =========================================================================
    // STAGE 5：WB（写回）
    //   5 路 MemToReg 选择；输出直接接到 RF 写口与 ForwardingUnit 的候选源
    // =========================================================================
    myCPU_wb_stage #(DATAWIDTH) u_wb_stage (
        .WB_pcadd4     (WB_pcadd4    ),
        .WB_alu_result (WB_alu_result),
        .WB_mdata      (WB_mdata     ),
        .WB_imm        (WB_imm       ),
        .WB_csr_wb     (WB_csr_wb    ),
        .WB_MemToReg   (WB_MemToReg  ),
        .WB_wdata      (WB_wdata     )
    );

endmodule
