`timescale 1ns / 1ps

// 复用经过回归验证的 CPU-only IROM/BRAM/MMIO 模型。该 wrapper 只增加
// bind probe，不改变 tb_cpu_only 的时钟、复位、完成条件或存储器返回拍数。
module tb_visual_trace;
    tb_cpu_only sim();
endmodule

bind mycpu visual_trace_probe u_visual_trace_probe (
    .*,
    .csr_write_en_i   (u_ex_stage.u_csr_file.csr_write_en),
    .csr_trap_enter_i (u_ex_stage.u_csr_file.trap_enter),
    .csr_trap_return_i(u_ex_stage.u_csr_file.trap_return),
    .csr_next_i       (u_ex_stage.u_csr_file.csr_next),
    .csr_mstatus_i    (u_ex_stage.u_csr_file.mstatus),
    .csr_mtvec_i      (u_ex_stage.u_csr_file.mtvec),
    .csr_mscratch_i   (u_ex_stage.u_csr_file.mscratch),
    .csr_mepc_i       (u_ex_stage.u_csr_file.mepc),
    .csr_mcause_i     (u_ex_stage.u_csr_file.mcause),
    .alu_in_a_i       (u_ex_stage.alu_in_a),
    .alu_in_b_i       (u_ex_stage.alu_in_b),
    .alu_in_a_s1_i    (u_ex_stage_s1.alu_in_a),
    .alu_in_b_s1_i    (u_ex_stage_s1.alu_in_b),
    .hint_hit_i       (u_if_stage.dual_hint_hit),
    .IF_slot_raw_hazard_i(u_if_stage.IF_slot_raw_hazard),
    .IF_slot_waw_hazard_i(u_if_stage.IF_slot_waw_hazard),
    .IF_slot_mem_conflict_i(u_if_stage.IF_slot_mem_conflict),
    .IF_slot_m_conflict_i(u_if_stage.IF_slot_m_conflict),
    .IF_dual_candidate_i(u_if_stage.IF_dual_candidate),
    .hint_train_i     (u_if_stage.dual_hint_pending_valid),
    .hint_current_index_i(u_if_stage.dual_hint_index),
    .hint_current_tag_i(u_if_stage.dual_hint_tag[u_if_stage.dual_hint_index]),
    .hint_current_valid_i(u_if_stage.dual_hint_valid[u_if_stage.dual_hint_index]),
    .hint_current_value_i(u_if_stage.dual_hint_value[u_if_stage.dual_hint_index]),
    .bht_current_index_i(u_if_stage.u_branch_predictor.IF_index),
    .bht_current_counter_i(u_if_stage.u_branch_predictor.bht[u_if_stage.u_branch_predictor.IF_index]),
    .bht_current_valid_i(u_if_stage.u_branch_predictor.bht_valid[u_if_stage.u_branch_predictor.IF_index]),
    .l0_store_en_i    (u_load_l0_cache.store_en),
    .l0_store_addr_i  (u_load_l0_cache.store_addr)
);
