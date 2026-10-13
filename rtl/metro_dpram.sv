// Derived from searchsolved/Arcade-HyperDuel_MiSTer rtl/hd_dpram.sv at 7f154f1e856ce5863f962821f2b330d1e8a85727 (GPL-3.0-or-later, see ../LICENSE).
// Renamed hd_dpram -> metro_dpram for the Metro core; any functional change from upstream is listed below in a "METRO:" note.
// Dual-port RAM wrapper: Verilator gets inferred arrays (proven sim path),
// Quartus gets explicit altsyncram.
//
// Port A = read/write with byte enables (CPU/blitter side)
// Port B = read-only (renderer side)
//
// Uses BIDIR_DUAL_PORT with port B write disabled. Port B's write
// infrastructure is tied off so Quartus does not build decoder trees
// for it across 100+ M10K blocks.

// METRO: SLICED=1 (16-bit words only) stores each byte as a 5-bit and a 3-bit memory. An M10K holds 10240 bits only in x5/x10/x20/x40 widths
// and a 16-bit word wastes a fifth of every block (the 64Kx16 VRAMs took 128 blocks each); x5 plus x1 slices take about 112, and the 3 VRAMs plus the
// work RAM no longer overflow the device's 553 blocks. Each slice lies inside one byte, so the byte enable is simply the slice's write enable.
// The slices are plain RTL in both the Verilator and the Quartus branch, so the bench exercises the same structure that is synthesised.
// Left alone the fitter maps a deep x5 memory as 5 x 8Kx1 blocks (8192 bits each, 40 blocks for 64Kx5); maximum_depth = 2048 forces its 2Kx5 mode
// (10240 bits per block, 32 blocks) at the price of a little decode and read-mux logic. The x3 slices are already dense as 3 x 8Kx1.

module metro_dpram_raw #(
    parameter int AW = 16,
    parameter int DW = 8,
    parameter int NUMWORDS = (1 << AW),
    parameter int MAXDEPTH = 0          // altsyncram maximum_depth (0 = the fitter's choice), see the METRO: note above
) (
    input  logic              clk,
    input  logic [AW-1:0]     addr_a,
    input  logic [DW-1:0]     d_a,
    input  logic              we_a,
    output logic [DW-1:0]     q_a,
    input  logic [AW-1:0]     addr_b,
    output logic [DW-1:0]     q_b
);

`ifdef VERILATOR
  logic [DW-1:0] mem [0:NUMWORDS-1];

  always_ff @(posedge clk) begin
    if (we_a) mem[addr_a] <= d_a;
    q_a <= mem[addr_a];
  end

  always_ff @(posedge clk)
    q_b <= mem[addr_b];
`else
  altsyncram #(
    .operation_mode          ("BIDIR_DUAL_PORT"),
    .width_a                 (DW),
    .widthad_a               (AW),
    .numwords_a              (NUMWORDS),
    .width_b                 (DW),
    .widthad_b               (AW),
    .numwords_b              (NUMWORDS),
    .maximum_depth           (MAXDEPTH),
    .width_byteena_a         (1),
    .width_byteena_b         (1),
    .clock_enable_input_b    ("BYPASS"),
    .clock_enable_output_a   ("BYPASS"),
    .clock_enable_output_b   ("BYPASS"),
    .indata_reg_b            ("CLOCK1"),
    .outdata_reg_a           ("UNREGISTERED"),
    .outdata_reg_b           ("UNREGISTERED"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
    .wrcontrol_wraddress_reg_b ("CLOCK1"),
    .power_up_uninitialized  ("FALSE"),
    .intended_device_family  ("Cyclone V"),
    .lpm_type                ("altsyncram"),
    .lpm_hint                ("ENABLE_RUNTIME_MOD=NO")
  ) ram (
    .clock0       (clk),
    .address_a    (addr_a),
    .data_a       (d_a),
    .wren_a       (we_a),
    .byteena_a    (1'b1),
    .q_a          (q_a),
    .address_b    (addr_b),
    .data_b       ({DW{1'b0}}),
    .wren_b       (1'b0),
    .byteena_b    (1'b1),
    .q_b          (q_b),
    .aclr0        (1'b0),
    .aclr1        (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .clocken0     (1'b1),
    .clocken1     (1'b1),
    .clocken2     (1'b1),
    .clocken3     (1'b1),
    .clock1       (clk),
    .eccstatus    (),
    .rden_a       (1'b1),
    .rden_b       (1'b1)
  );
`endif

endmodule

module metro_dpram #(
    parameter int AW = 16,
    parameter int DW = 16,
    parameter int NUMWORDS = (1 << AW),
    parameter bit SLICED = 1'b0         // METRO: DW must be 16
) (
    input  logic              clk,
    input  logic [AW-1:0]     addr_a,
    input  logic [DW-1:0]     d_a,
    input  logic              we_a,
    input  logic [DW/8-1:0]   be_a,
    output logic [DW-1:0]     q_a,
    input  logic [AW-1:0]     addr_b,
    output logic [DW-1:0]     q_b
);

generate
if (SLICED) begin : g_sliced
  // byte 0 = bits [4:0] + [7:5], byte 1 = bits [12:8] + [15:13]
  metro_dpram_raw #(.AW(AW), .DW(5), .NUMWORDS(NUMWORDS), .MAXDEPTH(2048)) s0 (.clk(clk),
    .addr_a(addr_a), .d_a(d_a[4:0]),   .we_a(we_a & be_a[0]), .q_a(q_a[4:0]),   .addr_b(addr_b), .q_b(q_b[4:0]));
  metro_dpram_raw #(.AW(AW), .DW(3), .NUMWORDS(NUMWORDS)) s1 (.clk(clk),
    .addr_a(addr_a), .d_a(d_a[7:5]),   .we_a(we_a & be_a[0]), .q_a(q_a[7:5]),   .addr_b(addr_b), .q_b(q_b[7:5]));
  metro_dpram_raw #(.AW(AW), .DW(5), .NUMWORDS(NUMWORDS), .MAXDEPTH(2048)) s2 (.clk(clk),
    .addr_a(addr_a), .d_a(d_a[12:8]),  .we_a(we_a & be_a[1]), .q_a(q_a[12:8]),  .addr_b(addr_b), .q_b(q_b[12:8]));
  metro_dpram_raw #(.AW(AW), .DW(3), .NUMWORDS(NUMWORDS)) s3 (.clk(clk),
    .addr_a(addr_a), .d_a(d_a[15:13]), .we_a(we_a & be_a[1]), .q_a(q_a[15:13]), .addr_b(addr_b), .q_b(q_b[15:13]));
end else begin : g_plain

`ifdef VERILATOR
  logic [DW-1:0] mem [0:NUMWORDS-1];

  always_ff @(posedge clk) begin
    if (we_a)
      for (int i = 0; i < DW/8; i++)
        if (be_a[i]) mem[addr_a][i*8 +: 8] <= d_a[i*8 +: 8];
    q_a <= mem[addr_a];
  end

  always_ff @(posedge clk)
    q_b <= mem[addr_b];
`else
  altsyncram #(
    .operation_mode          ("BIDIR_DUAL_PORT"),
    .width_a                 (DW),
    .widthad_a               (AW),
    .numwords_a              (NUMWORDS),
    .width_b                 (DW),
    .widthad_b               (AW),
    .numwords_b              (NUMWORDS),
    .width_byteena_a         (DW / 8),
    .width_byteena_b         (1),
    .clock_enable_input_b    ("BYPASS"),
    .clock_enable_output_a   ("BYPASS"),
    .clock_enable_output_b   ("BYPASS"),
    .indata_reg_b            ("CLOCK1"),
    .outdata_reg_a           ("UNREGISTERED"),
    .outdata_reg_b           ("UNREGISTERED"),
    .read_during_write_mode_port_a ("NEW_DATA_NO_NBE_READ"),
    .read_during_write_mode_port_b ("NEW_DATA_NO_NBE_READ"),
    .wrcontrol_wraddress_reg_b ("CLOCK1"),
    .power_up_uninitialized  ("FALSE"),
    .intended_device_family  ("Cyclone V"),
    .lpm_type                ("altsyncram"),
    .lpm_hint                ("ENABLE_RUNTIME_MOD=NO")
  ) ram (
    .clock0       (clk),
    .address_a    (addr_a),
    .data_a       (d_a),
    .wren_a       (we_a),
    .byteena_a    (be_a),
    .q_a          (q_a),
    .address_b    (addr_b),
    .data_b       ({DW{1'b0}}),
    .wren_b       (1'b0),
    .byteena_b    (1'b1),
    .q_b          (q_b),
    .aclr0        (1'b0),
    .aclr1        (1'b0),
    .addressstall_a (1'b0),
    .addressstall_b (1'b0),
    .clocken0     (1'b1),
    .clocken1     (1'b1),
    .clocken2     (1'b1),
    .clocken3     (1'b1),
    .clock1       (clk),
    .eccstatus    (),
    .rden_a       (1'b1),
    .rden_b       (1'b1)
  );
`endif

end
endgenerate

endmodule
