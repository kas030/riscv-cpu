// =============================================================================
// mux_key_internal.v —— mux_key 的实际查表实现
//   将 lut 拆分成 NR_KEY 个 (key, data) 对，逐对与输入 key 比较；
//   命中则把对应 data 或上 lut_out，最终用 hit 决定走 lut_out 还是 default。
//   全部使用组合逻辑，可被综合为并行 LUT 网络。
// =============================================================================
module mux_key_internal #(NR_KEY = 2, KEY_LEN = 1, DATA_LEN = 1, HAS_DEFAULT = 0) (
  output reg [DATA_LEN-1:0]                   out,
  input      [KEY_LEN-1:0]                    key,
  input      [DATA_LEN-1:0]                   default_out,
  input      [NR_KEY*(KEY_LEN + DATA_LEN)-1:0] lut
);

  localparam PAIR_LEN = KEY_LEN + DATA_LEN;             // 单个 (key,data) 对的位宽
  wire [PAIR_LEN-1:0] pair_arr [NR_KEY-1:0];            // 拆分后的 (key,data) 数组
  wire [KEY_LEN-1:0]  key_arr  [NR_KEY-1:0];            // 各对 key 部分
  wire [DATA_LEN-1:0] data_arr [NR_KEY-1:0];            // 各对 data 部分

  // 把扁平的 lut 切片到上面三个数组
  genvar gi;
  generate
    for (gi = 0; gi < NR_KEY; gi = gi + 1) begin : g_split
      assign pair_arr[gi] = lut[PAIR_LEN*(gi+1)-1 : PAIR_LEN*gi];
      assign data_arr[gi] = pair_arr[gi][DATA_LEN-1:0];
      assign key_arr [gi] = pair_arr[gi][PAIR_LEN-1:DATA_LEN];
    end
  endgenerate

  reg [DATA_LEN-1:0] match_val;                          // 命中项的 data 累加
  reg                hit_flag;                           // 是否至少命中一项
  integer            ii;
  always @(*) begin
    match_val = {DATA_LEN{1'b0}};                        // .v 文件，避免 SystemVerilog 的 '0 字面量
    hit_flag  = 1'b0;
    // 对每一项做一次相等比较，命中则把 data 或入 match_val
    for (ii = 0; ii < NR_KEY; ii = ii + 1) begin
      match_val = match_val | ({DATA_LEN{key == key_arr[ii]}} & data_arr[ii]);
      hit_flag  = hit_flag  | (key == key_arr[ii]);
    end
    // 不带 default 时直接输出，否则未命中走 default
    if (!HAS_DEFAULT) out = match_val;
    else              out = hit_flag ? match_val : default_out;
  end
endmodule
