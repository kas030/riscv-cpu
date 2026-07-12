// =============================================================================
// load_l0_cache.sv —— BRAM load 结果 L0 缓存
//   缓存键由 BRAM 内部字地址、字节偏移和访问宽度组成，数据为 bram_driver 已完成
//   byte/half/word 选择后的零扩展结果。load 符号扩展仍由原 load_mask 完成。
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
    input  logic [1:0]  lookup_width,
    output logic        lookup_hit,
    output logic [31:0] lookup_data,
    input  logic        fill_en,
    input  logic [31:0] fill_addr,
    input  logic [1:0]  fill_width,
    input  logic [31:0] fill_data,
    input  logic        store_en,
    input  logic [31:0] store_addr
);
    localparam ENTRIES = 1 << INDEX_WIDTH;
    // BRAM 使用 addr[17:2] 作为 16 位字地址，其中低 INDEX_WIDTH 位为索引。
    localparam TAG_WIDTH = 16 - INDEX_WIDTH;

    logic [31:0] data_array [0:ENTRIES-1];
    logic [TAG_WIDTH-1:0] tag_array [0:ENTRIES-1];
    logic [1:0] offset_array [0:ENTRIES-1];
    logic [1:0] width_array [0:ENTRIES-1];
    logic valid_array [0:ENTRIES-1];
    logic [INDEX_WIDTH-1:0] lookup_index, fill_index, store_index;
    logic [TAG_WIDTH-1:0] lookup_tag, fill_tag, store_tag;

    assign lookup_index = lookup_addr[INDEX_WIDTH+1:2];
    assign fill_index   = fill_addr[INDEX_WIDTH+1:2];
    assign store_index  = store_addr[INDEX_WIDTH+1:2];
    assign lookup_tag   = lookup_addr[17:INDEX_WIDTH+2];
    assign fill_tag     = fill_addr[17:INDEX_WIDTH+2];
    assign store_tag    = store_addr[17:INDEX_WIDTH+2];
    assign lookup_hit = valid_array[lookup_index] &&
                        (tag_array[lookup_index] == lookup_tag) &&
                        (offset_array[lookup_index] == lookup_addr[1:0]) &&
                        (width_array[lookup_index] == lookup_width);
    assign lookup_data = data_array[lookup_index];

    integer i;
    always_ff @(posedge clk) begin
        if (rst) begin
            for (i = 0; i < ENTRIES; i = i + 1) begin
                valid_array[i] <= 1'b0;
            end
        end else begin
            if (fill_en) begin
                data_array[fill_index]   <= fill_data;
                tag_array[fill_index]    <= fill_tag;
                offset_array[fill_index] <= fill_addr[1:0];
                width_array[fill_index]  <= fill_width;
                valid_array[fill_index]  <= 1'b1;
            end
            if (store_en &&
                ((valid_array[store_index] &&
                  (tag_array[store_index] == store_tag)) ||
                 (fill_en && (fill_addr[17:2] == store_addr[17:2])))) begin
                valid_array[store_index] <= 1'b0;
            end
        end
    end
endmodule
