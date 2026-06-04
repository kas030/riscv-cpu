// =============================================================================
// csr_ctrl_decode.sv - Zicsr/system instruction decode
//   CSRControll bit map:
//     bit0 csrrw/csrrwi
//     bit1 csrrs/csrrsi
//     bit2 csrrc/csrrci
//     bit3 ecall
//     bit4 mret
//     bit5 use immediate zimm instead of rs1 data
// =============================================================================
module csr_ctrl_decode (
    input  logic [31:0] instr,
    output logic [11:0] csr_idx,
    output logic [4:0]  csr_zimm,
    output logic [5:0]  CSRControll
);
    logic is_system;

    assign is_system = (instr[6:0] == 7'b1110011);
    assign csr_idx   = instr[31:20];
    assign csr_zimm  = instr[19:15];

    assign CSRControll[0] = is_system && ((instr[14:12] == 3'b001) || (instr[14:12] == 3'b101));
    assign CSRControll[1] = is_system && ((instr[14:12] == 3'b010) || (instr[14:12] == 3'b110));
    assign CSRControll[2] = is_system && ((instr[14:12] == 3'b011) || (instr[14:12] == 3'b111));
    assign CSRControll[3] = (instr == 32'h0000_0073);
    assign CSRControll[4] = (instr == 32'h3020_0073);
    assign CSRControll[5] = is_system && instr[14];
endmodule
