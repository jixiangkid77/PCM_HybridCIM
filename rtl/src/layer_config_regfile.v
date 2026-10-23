//============================================================
// layer_config_regfile.v
// Paper 2 v3 — Per-layer base/size configuration regfile
//============================================================
// Stores 10 layer-config entries (5 SRAM, 5 PCM) plus a control
// register and a drift_t timer. Read port is layer-indexed and
// emits both SRAM and PCM {base, size} for the same layer in
// parallel, so sram_addr_decoder and pcm_addr_decoder can run
// concurrently.
//
// Address map (6-bit wr_addr / rd_addr):
//   0x00 .. 0x04  : SRAM {size[31:16], base[15:0]} for conv1..fc3
//   0x05 .. 0x09  : PCM  {size[31:16], base[15:0]} for conv1..fc3
//   0x20          : control register (write/read asymmetric)
//                     write bit[0] = enable_drift  (R/W)
//                     write bit[1] = cfg_commit    (pulse, sets cfg_valid)
//                     read  bit[0] = enable_drift  (status)
//                     read  bit[1] = cfg_valid     (sticky status)
//   0x21          : drift_t register (lower 16 bits)
//
// Initialisation:
//   When DATA_DIR is non-empty, an `initial` block calls
//   $readmemh("<DATA_DIR>/layer_config.hex", cfg_mem). On synthesis
//   $readmemh is ignored and registers come up at zero; the host
//   CPU / testbench is then responsible for writing every entry
//   before asserting cfg_commit. This matches the boot-time config
//   semantics of a real SoC.
//
// Reset (rst_n = 0):
//   - cfg_valid_reg, enable_drift_reg, drift_t_reg cleared to zero.
//   - cfg_mem is NOT cleared on reset. It retains either the
//     $readmemh-loaded values (simulation) or whatever the host
//     CPU has written (post-synthesis). This is the standard
//     "boot-time configuration" reset semantics.
//
// cfg_commit pulse semantics:
//   Writing wr_data[1] = 1 to address 0x20 sets cfg_valid_reg.
//   Writing wr_data[1] = 0 has no effect on cfg_valid_reg
//   (only reset clears it). This is a fire-once "commit" signal,
//   not a stored bit. The host CPU asserts it exactly once after
//   filling cfg_mem; any subsequent write to 0x20 that toggles
//   enable_drift will not invalidate the committed configuration.
//============================================================

`timescale 1ns/1ps

module layer_config_regfile #(
    parameter DATA_DIR = ""
)(
    input  wire        clk,
    input  wire        rst_n,

    // Write port (testbench / host CPU)
    input  wire        wr_en,
    input  wire [5:0]  wr_addr,
    input  wire [31:0] wr_data,

    // Generic read port (testbench / host CPU verification)
    input  wire [5:0]  rd_addr,
    output wire [31:0] rd_data,

    // Layer-indexed read port (combinational, used by RTL data path)
    //   layer_id: 0=conv1, 1=conv2, 2=fc1, 3=fc2, 4=fc3
    input  wire [2:0]  layer_id,
    output wire [15:0] sram_base,
    output wire [15:0] sram_size,
    output wire [15:0] pcm_base,
    output wire [15:0] pcm_size,

    // Status outputs
    output wire        cfg_valid,
    output wire        enable_drift,
    output wire [15:0] drift_t
);

    // ---- Storage --------------------------------------------------
    // 10 entries, each {size[31:16], base[15:0]}; matches the
    // 32-bit-per-line layer_config.hex format produced by
    // 03_split_protected_v3.py.
    reg [31:0] cfg_mem [0:9];

    // Control state is split into two independent flops to make
    // the asymmetric write semantics (enable_drift R/W vs cfg_commit
    // as a write pulse setting cfg_valid_reg) unambiguous.
    reg        cfg_valid_reg;     // sticky-set by cfg_commit pulse
    reg        enable_drift_reg;  // ordinary R/W
    reg [15:0] drift_t_reg;

    integer i;

    // ---- Initialisation ------------------------------------------
    initial begin
        for (i = 0; i < 10; i = i + 1) begin
            cfg_mem[i] = 32'h0;
        end
        cfg_valid_reg    = 1'b0;
        enable_drift_reg = 1'b0;
        drift_t_reg      = 16'h0;

        if (DATA_DIR != "") begin
            $readmemh({DATA_DIR, "/layer_config.hex"}, cfg_mem);
        end
    end

    // ---- Write logic ---------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cfg_valid_reg    <= 1'b0;
            enable_drift_reg <= 1'b0;
            drift_t_reg      <= 16'h0;
            // cfg_mem intentionally not reset (boot-time config).
        end else if (wr_en) begin
            if (wr_addr <= 6'h09) begin
                cfg_mem[wr_addr[3:0]] <= wr_data;
            end
            else if (wr_addr == 6'h20) begin
                // bit0 = enable_drift   : ordinary R/W
                // bit1 = cfg_commit pulse : when 1, sets cfg_valid_reg;
                //        writing 0 does NOT clear cfg_valid_reg
                enable_drift_reg <= wr_data[0];
                if (wr_data[1]) begin
                    cfg_valid_reg <= 1'b1;
                end
            end
            else if (wr_addr == 6'h21) begin
                drift_t_reg <= wr_data[15:0];
            end
            // Other addresses ignored (acts like read-only / reserved).
        end
    end

    // ---- Generic read mux ----------------------------------------
    // 0x20 readback layout (asymmetric vs write):
    //   bit[0] = enable_drift status
    //   bit[1] = cfg_valid status   (note: write bit[1] is the
    //            commit pulse, not a stored bit -- read returns
    //            the resulting sticky cfg_valid_reg)
    assign rd_data =
        (rd_addr <= 6'h09)  ? cfg_mem[rd_addr[3:0]]                     :
        (rd_addr == 6'h20)  ? {30'h0, cfg_valid_reg, enable_drift_reg}  :
        (rd_addr == 6'h21)  ? {16'h0, drift_t_reg}                      :
                              32'h0;

    // ---- Layer-indexed read --------------------------------------
    // Indices 0..4 hold SRAM partitions; 5..9 hold PCM partitions.
    // Guard layer_id against out-of-range (legal values are 0..4).
    wire layer_in_range = (layer_id <= 3'd4);

    wire [31:0] sram_word = layer_in_range ? cfg_mem[layer_id]      : 32'h0;
    wire [31:0] pcm_word  = layer_in_range ? cfg_mem[layer_id + 5]  : 32'h0;

    assign sram_base = sram_word[15:0];
    assign sram_size = sram_word[31:16];
    assign pcm_base  = pcm_word[15:0];
    assign pcm_size  = pcm_word[31:16];

    assign cfg_valid    = cfg_valid_reg;
    assign enable_drift = enable_drift_reg;
    assign drift_t      = drift_t_reg;

endmodule
