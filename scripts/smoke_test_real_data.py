"""
smoke_test_real_data.py
============================================================
Paper 2 v2 - real-data smoke test for pcm_imc_unit.

Strategy:
  1. Pick a specific conv2 MAC slice (25 weights addressed by orig_addr 0..24)
  2. Load weights from the FULL weights_conv2.hex (v1 reference)
  3. Use synthetic V values (1, 2, 3, ..., 25) for predictability
  4. Compute the expected MAC value in Python (ground truth)
  5. Generate a Verilog tb that loads real data and asserts the same value

This validates that:
  - sram_array correctly loads weights_conv2_sram.hex + addr_to_slot_*
  - pcm_crossbar correctly loads weights_conv2_pcm.hex + addr_to_slot_*
  - pcm_imc_unit's combiner produces the same MAC as PyTorch reference

If the value matches, all $readmemh paths and per-layer bit widths are correct.
"""

from pathlib import Path

DATA_DIR = Path('./data/rtl_inputs_A')
TMP_DIR = Path('./data/rtl_inputs_TMP')
OUT_TB = Path('./rtl/tb/tb_pcm_imc_real_smoke.v')


def parse_signed_hex8(s):
    """Parse 2-char hex as signed INT8."""
    v = int(s.strip(), 16)
    if v >= 128:
        v -= 256
    return v


def load_full_weights(path):
    """Load full weight hex (one INT8 per line, signed)."""
    weights = []
    for line in path.read_text().splitlines():
        line = line.strip()
        if line and not line.startswith('//'):
            weights.append(parse_signed_hex8(line))
    return weights


def reconstruct_from_partitions(layer_name, n_total, aw_bits):
    """Reconstruct full weight array from SRAM + PCM partitions.
    Uses addr_to_slot_*_sram.hex and addr_to_slot_*_pcm.hex to figure out
    which partition each original address belongs to, then looks up the
    weight in the corresponding partition's weights_*.hex.

    Returns: list of N_TOTAL signed INT8 weights, indexed by orig_addr."""
    sram_w = load_full_weights(DATA_DIR / f'weights_{layer_name}_sram.hex')
    pcm_w  = load_full_weights(DATA_DIR / f'weights_{layer_name}_pcm.hex')

    sram_map = (DATA_DIR / f'addr_to_slot_{layer_name}_sram.hex').read_text().splitlines()
    pcm_map  = (DATA_DIR / f'addr_to_slot_{layer_name}_pcm.hex').read_text().splitlines()

    invalid_code = (1 << aw_bits) - 1
    full_w = [0] * n_total
    for i in range(n_total):
        sram_slot = int(sram_map[i].strip(), 16)
        pcm_slot  = int(pcm_map[i].strip(), 16)
        in_sram = (sram_slot != invalid_code)
        in_pcm  = (pcm_slot != invalid_code)
        if in_sram and not in_pcm:
            full_w[i] = sram_w[sram_slot]
        elif in_pcm and not in_sram:
            full_w[i] = pcm_w[pcm_slot]
        else:
            raise RuntimeError(
                f"addr {i}: in_sram={in_sram}, in_pcm={in_pcm} "
                f"(should be exactly one)"
            )
    return full_w


def main():
    # Try the v1 reference file first; if absent, reconstruct from v2 partitions
    full_w_path = TMP_DIR / 'weights_conv2.hex'
    if full_w_path.exists():
        full_w = load_full_weights(full_w_path)
        print(f"Loaded {len(full_w)} conv2 weights from {full_w_path.name}")
    else:
        print(f"INFO: {full_w_path} not found")
        print("Reconstructing full conv2 weights from SRAM + PCM partitions...")
        full_w = reconstruct_from_partitions('conv2', n_total=2400, aw_bits=12)
        print(f"Reconstructed {len(full_w)} conv2 weights from v2 partitions")

    # Pick the first 25 weights (orig_addr = 0..24)
    K = 25
    selected_w = full_w[:K]
    selected_addrs = list(range(K))

    # Use synthetic V values: 1, 2, 3, ... (predictable)
    # Limit to small values to avoid INT8 overflow
    V = [(i + 1) for i in range(K)]

    # Compute MAC reference
    mac_ref = sum(v * w for v, w in zip(V, selected_w))

    print(f"\n=== Reference computation ===")
    print(f"V[0..24]    = {V}")
    print(f"W[0..24]    = {selected_w}")
    print(f"MAC ref     = sum(V[i] * W[i]) = {mac_ref}")

    # Print addr-by-addr breakdown of which goes to SRAM vs PCM
    # by reading addr_to_slot maps
    print(f"\n=== Per-channel SRAM/PCM breakdown ===")
    sram_map_path = DATA_DIR / 'addr_to_slot_conv2_sram.hex'
    pcm_map_path  = DATA_DIR / 'addr_to_slot_conv2_pcm.hex'
    sram_map = sram_map_path.read_text().splitlines()
    pcm_map  = pcm_map_path.read_text().splitlines()

    INV_12 = 0xFFF  # AW_CONV2 = 12-bit
    sram_count = 0
    pcm_count = 0
    sram_contrib = 0
    pcm_contrib = 0
    for i in range(K):
        sram_slot = int(sram_map[i].strip(), 16)
        pcm_slot  = int(pcm_map[i].strip(), 16)
        in_sram = (sram_slot != INV_12)
        in_pcm  = (pcm_slot != INV_12)
        assert in_sram != in_pcm, f"addr {i}: should be in exactly one partition"
        path = "SRAM" if in_sram else "PCM"
        contrib = V[i] * selected_w[i]
        if in_sram:
            sram_count += 1
            sram_contrib += contrib
        else:
            pcm_count += 1
            pcm_contrib += contrib
        print(f"  addr={i:2d}  V={V[i]:2d}  W={selected_w[i]:4d}  "
              f"-> {path:4s}  contrib={contrib:5d}")

    print(f"\nSRAM channels: {sram_count}, contribution: {sram_contrib}")
    print(f"PCM  channels: {pcm_count}, contribution: {pcm_contrib}")
    print(f"Total: {sram_contrib + pcm_contrib}  (should == MAC ref {mac_ref})")
    assert sram_contrib + pcm_contrib == mac_ref

    # Generate Verilog tb
    OUT_TB.parent.mkdir(parents=True, exist_ok=True)
    v_packed_lits = ", ".join(f"8'd{V[i]}" for i in reversed(range(K)))
    a_packed_lits = ", ".join(f"16'd{selected_addrs[i]}" for i in reversed(range(K)))

    tb_code = f'''// ============================================================
// tb_pcm_imc_real_smoke.v   (Paper 2 v2 — auto-generated)
// ------------------------------------------------------------
// Real-data smoke test: load weights_conv2_*.hex and
// addr_to_slot_conv2_*.hex via $readmemh, then verify that
// pcm_imc_unit produces the same MAC as the Python reference.
//
// Test vector: V = [1..25], orig_addr = [0..24], layer = conv2
// Expected MAC = {mac_ref}
//   (SRAM contribution = {sram_contrib}, PCM contribution = {pcm_contrib})
// ============================================================

`timescale 1ns / 1ps

module tb_pcm_imc_real_smoke;

    localparam K = 25;
    localparam DW = 8;
    localparam AW = 16;
    localparam ACC = 24;

    reg                       clk;
    reg                       rst_n;
    reg                       start;
    reg  [2:0]                layer_id;
    reg  [K*DW-1:0]           v_bus;
    reg  [K*AW-1:0]           addr_bus;
    reg                       enable_drift;
    reg  [15:0]               drift_t;
    wire signed [ACC-1:0]     mac_result;
    wire                      result_valid;

    pcm_imc_unit #(.DATA_DIR("../data/rtl_inputs_A")) DUT (
        .clk(clk), .rst_n(rst_n), .start(start),
        .layer_id(layer_id), .v_bus(v_bus), .addr_bus(addr_bus),
        .enable_drift(enable_drift), .drift_t(drift_t),
        .mac_result(mac_result), .result_valid(result_valid)
    );

    initial clk = 0;
    always #5 clk = ~clk;

    integer wait_cnt;

    initial begin
        $dumpfile("sim/tb_pcm_imc_real_smoke.vcd");
        $dumpvars(0, tb_pcm_imc_real_smoke);

        $display("============================================================");
        $display("tb_pcm_imc_real_smoke");
        $display("  V = [1, 2, 3, ..., 25]");
        $display("  addr = [0, 1, 2, ..., 24], layer = conv2");
        $display("  expected MAC = {mac_ref}  (SRAM={sram_contrib} + PCM={pcm_contrib})");
        $display("============================================================");

        rst_n = 0;
        start = 0;
        layer_id = 3'd1;  // conv2
        enable_drift = 0;
        drift_t = 16'd1000;
        // Pack V and addrs (channel 0 in low bits)
        v_bus    = {{ {v_packed_lits} }};
        addr_bus = {{ {a_packed_lits} }};
        repeat (3) @(posedge clk);
        @(negedge clk); rst_n = 1;
        @(posedge clk);

        @(negedge clk); start = 1;
        @(posedge clk);
        @(negedge clk); start = 0;

        wait_cnt = 0;
        while (!result_valid && wait_cnt < 50) begin
            @(posedge clk);
            wait_cnt = wait_cnt + 1;
        end
        #1;

        $display("");
        $display("RTL mac_result = %0d", $signed(mac_result));
        $display("Python ref     = {mac_ref}");

        if ($signed(mac_result) == {mac_ref}) begin
            $display("[OK] real-data smoke test PASSED");
        end else begin
            $display("[FAIL] mismatch! diff = %0d", $signed(mac_result) - {mac_ref});
        end
        $finish;
    end

    initial begin
        #50000;
        $display("[FAIL] watchdog timeout");
        $finish;
    end

endmodule
'''
    OUT_TB.write_text(tb_code)
    print(f"\n=== Generated testbench: {OUT_TB} ===")


if __name__ == '__main__':
    main()
