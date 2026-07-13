// =============================================================================
// load_l0_cache.sv —— BRAM load 结果 L0 缓存
//   缓存键仅使用 BRAM 内部字地址，数据为完整 32 位字。byte/half 选择和
//   load 符号扩展由 CPU 在流水边界完成，因此不同宽度访问可共享缓存行。
//   store 保持 write-through，并失效同一字地址对应的缓存行。
//   调用侧只允许 0x8010_0000..0x8013_FFFF 进入缓存，因此地址高 14 位
//   恒定，无需存入 tag。
// =============================================================================
module load_l0_cache #(
    parameter INDEX_WIDTH = 6
) (
    input  logic        clk,
    input  logic        rst,
    input  logic [31:0] lookup_addr,
    output logic        lookup_hit,
    output logic [31:0] lookup_data,
    input  logic [31:0] probe_addr,
    output logic        probe_hit,
    output logic [31:0] probe_data,
    input  logic        fill_en,
    input  logic [31:0] fill_addr,
    input  logic [31:0] fill_data,
    input  logic        store_en,
    input  logic [31:0] store_addr,
    input  logic [31:0] store_data,
    input  logic [1:0]  store_mask
);
    localparam ENTRIES = 1 << INDEX_WIDTH;
    // BRAM 使用 addr[17:2] 作为 16 位字地址，其中低 INDEX_WIDTH 位为索引。
    localparam TAG_WIDTH = 16 - INDEX_WIDTH;

    logic [31:0] data_array [0:ENTRIES-1];
    logic [TAG_WIDTH-1:0] tag_array [0:ENTRIES-1];
    logic valid_array [0:ENTRIES-1];
    logic [INDEX_WIDTH-1:0] lookup_index, fill_index, store_index;
    logic [INDEX_WIDTH-1:0] probe_index;
    logic [TAG_WIDTH-1:0] lookup_tag, probe_tag, fill_tag, store_tag;

    assign lookup_index = lookup_addr[INDEX_WIDTH+1:2];
    assign probe_index  = probe_addr[INDEX_WIDTH+1:2];
    assign fill_index   = fill_addr[INDEX_WIDTH+1:2];
    assign store_index  = store_addr[INDEX_WIDTH+1:2];
    assign lookup_tag   = lookup_addr[17:INDEX_WIDTH+2];
    assign probe_tag    = probe_addr[17:INDEX_WIDTH+2];
    assign fill_tag     = fill_addr[17:INDEX_WIDTH+2];
    assign store_tag    = store_addr[17:INDEX_WIDTH+2];
    assign lookup_hit = valid_array[lookup_index] &&
                        (tag_array[lookup_index] == lookup_tag);
    assign lookup_data = data_array[lookup_index];
    // EX 级只用该端口提前判断下一拍能否完成 load-to-use 前递。
    assign probe_hit = valid_array[probe_index] &&
                       (tag_array[probe_index] == probe_tag);
    assign probe_data = data_array[probe_index];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid_array[i] = 1'b0;
            end
        end else begin
            if (fill_en) begin
                data_array[fill_index]   <= fill_data;
                tag_array[fill_index]    <= fill_tag;
                valid_array[fill_index]  <= 1'b1;
            end else if (store_en && (store_mask == 2'b10) &&
                         valid_array[store_index] &&
                         (tag_array[store_index] == store_tag)) begin
                data_array[store_index] <= store_data;
            end

            if (store_en && fill_en &&
                (fill_addr[17:2] == store_addr[17:2])) begin
                valid_array[fill_index] <= 1'b0;
            end else if (store_en && valid_array[store_index] &&
                         (tag_array[store_index] == store_tag) &&
                         ((store_mask != 2'b10) || fill_en)) begin
                valid_array[store_index] <= 1'b0;
            end
        end
    end
endmodule
