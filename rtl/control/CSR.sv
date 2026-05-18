// =============================================================================
// CSR.sv —— Machine 模式 CSR 寄存器组
//   位于 EX 级，实现 RV32 中本设计需要的 4 个 M-mode CSR：
//     mstatus(0x300) / mtvec(0x305) / mepc(0x341) / mcause(0x342)
//   支持的操作（由 CCTL 译码出的独热 CSRControll 选择）：
//     bit0 csrrs  - old | rf1
//     bit1 csrrw  - rf1
//     bit2 ecall  - mepc<=pc, mcause<=11, mstatus.MIE 备份
//     bit3 mret   - 从 mstatus 恢复 MIE
//   每个 CSR 都额外保留一份 old_* 备份，使 csrrs 这种"读后写"语义在
//   单周期内即可完成（读 old，写新值），同时也方便异常返回时恢复。
//   csr_npc 输出供 NPC 模块在 ecall (→mtvec) / mret (→mepc) 时重定向 PC。
// =============================================================================
module CSR #(
    parameter   DATAWIDTH = 32
)(
    input  logic                    clk         ,           // 时钟
    input  logic                    rst         ,           // 异步复位
    input  logic [DATAWIDTH-1:0]    pc          ,           // 当前 PC（ecall 时存入 mepc）
    input  logic [DATAWIDTH-1:0]    rf1         ,           // 寄存器堆 rs1 数据，用作写入源
    input  logic [11:0]             csr_idx     ,           // CSR 索引
    input  logic [3:0]              CSRControll ,           // 一热 CSR 操作

    output logic [DATAWIDTH-1:0]    csr_npc     ,           // ecall/mret 重定向地址
    output logic [DATAWIDTH-1:0]    csr_wb                  // CSR 读出值，用于 WB 写回
);
    // 当前生效值 与 上一周期备份值
    reg [DATAWIDTH-1:0] mstatus, mepc, mtvec, mcause;
    reg [DATAWIDTH-1:0] mstatus_q, mepc_q, mtvec_q, mcause_q;
    reg [DATAWIDTH-1:0] mask_reg;                           // 写 mstatus 时的位掩码

    // ------------------------------------------------------------------
    // mask_reg：mstatus 写入时的位掩码，复位置为全 1（允许全位写）
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mask_reg <= 32'hFFFFFFFF;
        end
    end

    // ------------------------------------------------------------------
    // 4 个 CSR 的"上一周期备份" old_*
    //   每个 CSR 都打一拍存在对应的 *_q 里，用于 csrrs 的 old|rf1 语义、
    //   以及 ecall/mret 异常返回时安全地读到老值。
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) mstatus_q <= 32'h0;
        else     mstatus_q <= mstatus;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) mepc_q <= 32'h0;
        else     mepc_q <= mepc;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) mtvec_q <= 32'h0;
        else     mtvec_q <= mtvec;
    end

    always @(posedge clk or posedge rst) begin
        if (rst) mcause_q <= 32'h0;
        else     mcause_q <= mcause;
    end

    // ------------------------------------------------------------------
    // mstatus(0x300) 写入逻辑
    //   csrrs：old | rf1，再用 mask 屏蔽
    //   csrrw：直接写 rf1，再用 mask 屏蔽
    //   ecall：把 MIE(bit3) 备份到 MPIE(bit7)，原 MIE 清 0
    //   mret ：把 MPIE(bit7) 恢复到 MIE，并把 MPIE 置 1，MPP=11
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mstatus <= 32'h1800;                            // 复位为 MPP=11
        end else begin
            case (CSRControll)
                4'b0001: if (csr_idx == 12'h300) mstatus <= mask_reg & (mstatus_q | rf1);
                4'b0010: if (csr_idx == 12'h300) mstatus <= mask_reg & rf1;
                4'b0100: mstatus <= { mstatus_q[31:8], mstatus_q[3], mstatus_q[6:4], mstatus_q[2:0] };
                4'b1000: mstatus <= { mstatus_q[31:13], 2'b11, mstatus_q[10:8], 1'b1, mstatus_q[6:4], mstatus_q[3], mstatus_q[2:0] };
                default: mstatus <= mstatus;                // 其它情况保持
            endcase
        end
    end

    // ------------------------------------------------------------------
    // mtvec(0x305)：异常向量基址，仅 csrrs / csrrw 修改
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mtvec <= 32'h0;
        end else begin
            case (CSRControll)
                4'b0001: if (csr_idx == 12'h305) mtvec <= mtvec_q | rf1;
                4'b0010: if (csr_idx == 12'h305) mtvec <= rf1;
                default: mtvec <= mtvec;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // mepc(0x341)：异常返回 PC
    //   除 csrrs/csrrw 之外，ecall 时自动把当前 pc 锁存进来
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mepc <= 32'h0;
        end else begin
            case (CSRControll)
                4'b0001: if (csr_idx == 12'h341) mepc <= mepc_q | rf1;
                4'b0010: if (csr_idx == 12'h341) mepc <= rf1;
                4'b0100:                         mepc <= pc;
                default:                         mepc <= mepc;
            endcase
        end
    end

    // ------------------------------------------------------------------
    // mcause(0x342)：异常原因
    //   ecall 时自动写入 11 (environment call from M-mode)
    // ------------------------------------------------------------------
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            mcause <= 32'h0;
        end else begin
            case (CSRControll)
                4'b0001: if (csr_idx == 12'h342) mcause <= mcause_q | rf1;
                4'b0010: if (csr_idx == 12'h342) mcause <= rf1;
                4'b0100:                         mcause <= 32'h0b;
                default:                         mcause <= mcause;
            endcase
        end
    end

    // CSR 读出值：根据 csr_idx 选择 4 个 old_* 之一（csrrs 语义需要读旧值）
    assign csr_wb  = {32{csr_idx == 12'h300}} & mstatus_q |
                     {32{csr_idx == 12'h305}} & mtvec_q   |
                     {32{csr_idx == 12'h341}} & mepc_q    |
                     {32{csr_idx == 12'h342}} & mcause_q;

    // 重定向地址：ecall → mtvec（异常入口），mret → mepc（返回 PC）
    assign csr_npc = {32{CSRControll == 4'b0100}} & mtvec_q |
                     {32{CSRControll == 4'b1000}} & mepc_q;
endmodule
