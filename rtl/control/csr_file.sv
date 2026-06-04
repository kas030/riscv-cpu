// =============================================================================
// csr_file.sv - Minimal M-mode CSR file for Zicsr and ecall/mret
//   Implemented CSRs:
//     mstatus(0x300), mtvec(0x305), mscratch(0x340), mepc(0x341), mcause(0x342)
//   The design is M-mode only. mstatus keeps MPP=11 and implements the MIE/MPIE
//   behavior needed by trap entry and mret.
// =============================================================================
module csr_file #(
    parameter DATAWIDTH = 32
) (
    input  logic                   clk,
    input  logic                   rst,
    input  logic [DATAWIDTH-1:0]   pc,
    input  logic [DATAWIDTH-1:0]   csr_wdata,
    input  logic [11:0]            csr_idx,
    input  logic [5:0]             CSRControll,

    output logic [DATAWIDTH-1:0]   csr_npc,
    output logic [DATAWIDTH-1:0]   csr_wb
);
    localparam CSR_MSTATUS = 12'h300;
    localparam CSR_MTVEC   = 12'h305;
    localparam CSR_MSCRATCH = 12'h340;
    localparam CSR_MEPC    = 12'h341;
    localparam CSR_MCAUSE  = 12'h342;

    localparam CSR_MSTATUS_MIE  = 3;
    localparam CSR_MSTATUS_MPIE = 7;
    localparam CSR_MSTATUS_MPP_LSB = 11;

    logic [DATAWIDTH-1:0] mstatus, mtvec, mscratch, mepc, mcause;
    logic [DATAWIDTH-1:0] csr_old;
    logic [DATAWIDTH-1:0] csr_next;
    logic [DATAWIDTH-1:0] mstatus_write_value;
    logic csr_write_en;

    assign csr_write_en = CSRControll[0] ||
                          (CSRControll[1] && (csr_wdata != '0)) ||
                          (CSRControll[2] && (csr_wdata != '0));

    always_comb begin
        unique case (csr_idx)
            CSR_MSTATUS: csr_old = mstatus;
            CSR_MTVEC:   csr_old = mtvec;
            CSR_MSCRATCH: csr_old = mscratch;
            CSR_MEPC:    csr_old = mepc;
            CSR_MCAUSE:  csr_old = mcause;
            default:     csr_old = '0;
        endcase
    end

    always_comb begin
        csr_next = csr_old;
        if (CSRControll[0]) begin
            csr_next = csr_wdata;
        end else if (CSRControll[1]) begin
            csr_next = csr_old | csr_wdata;
        end else if (CSRControll[2]) begin
            csr_next = csr_old & ~csr_wdata;
        end
    end

    always_comb begin
        mstatus_write_value = 32'h0000_1800;
        mstatus_write_value[CSR_MSTATUS_MIE]  = csr_next[CSR_MSTATUS_MIE];
        mstatus_write_value[CSR_MSTATUS_MPIE] = csr_next[CSR_MSTATUS_MPIE];
        mstatus_write_value[CSR_MSTATUS_MPP_LSB +: 2] = 2'b11;
    end

    always_ff @(posedge clk) begin
        if (rst) begin
            mstatus <= 32'h0000_1800;
            mtvec   <= '0;
            mscratch <= '0;
            mepc    <= '0;
            mcause  <= '0;
        end else if (CSRControll[3]) begin
            mstatus[CSR_MSTATUS_MIE] <= 1'b0;
            mstatus[CSR_MSTATUS_MPIE] <= mstatus[CSR_MSTATUS_MIE];
            mstatus[CSR_MSTATUS_MPP_LSB +: 2] <= 2'b11;
            mepc   <= {pc[DATAWIDTH-1:2], 2'b00};
            mcause <= 32'd11;
        end else if (CSRControll[4]) begin
            mstatus[CSR_MSTATUS_MIE] <= mstatus[CSR_MSTATUS_MPIE];
            mstatus[CSR_MSTATUS_MPIE] <= 1'b1;
            mstatus[CSR_MSTATUS_MPP_LSB +: 2] <= 2'b11;
        end else if (csr_write_en) begin
            unique case (csr_idx)
                CSR_MSTATUS: mstatus <= mstatus_write_value;
                CSR_MTVEC:   mtvec   <= csr_next;
                CSR_MSCRATCH: mscratch <= csr_next;
                CSR_MEPC:    mepc    <= {csr_next[DATAWIDTH-1:2], 2'b00};
                CSR_MCAUSE:  mcause  <= csr_next;
                default: begin
                end
            endcase
        end
    end

    assign csr_wb = csr_old;

    assign csr_npc = {DATAWIDTH{CSRControll[3]}} & {mtvec[DATAWIDTH-1:2], 2'b00} |
                     {DATAWIDTH{CSRControll[4]}} & {mepc[DATAWIDTH-1:1], 1'b0};
endmodule
