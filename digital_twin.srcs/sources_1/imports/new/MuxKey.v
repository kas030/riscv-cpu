// =============================================================================
// MuxKey.v —— 通用 key-value 多路选择器外壳
//   供 myCPU_wb_stage 等模块调用，按 key 在 lut 中查找对应 value 输出。
//   实际匹配逻辑由 MuxKeyInternal 完成，本模块负责把 default 接为全 0
//   并禁用 default 路径（HAS_DEFAULT=0）。
// =============================================================================
module MuxKey #(NR_KEY = 2, KEY_LEN = 1, DATA_LEN = 1) (
  output [DATA_LEN-1:0]                       out,
  input  [KEY_LEN-1:0]                        key,
  input  [NR_KEY*(KEY_LEN + DATA_LEN)-1:0]    lut
);
  // 不带 default 的内部例化，未命中时输出由 internal 内部置 0
  MuxKeyInternal #(NR_KEY, KEY_LEN, DATA_LEN, 0) u_mux_inner (
      out, key, {DATA_LEN{1'b0}}, lut
  );
endmodule
