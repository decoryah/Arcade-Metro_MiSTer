// Derived from searchsolved/Arcade-HyperDuel_MiSTer rtl/i4220_blitter.sv at 7f154f1e856ce5863f962821f2b330d1e8a85727 (GPL-3.0-or-later, see ../LICENSE).
// Renamed i4220_blitter -> metro_blitter for the Metro core; any functional change from upstream is listed below in a "METRO:" note.
// I4220 blitter (docs/i4220_spec.md sec 4).
//
// Reads an opcode stream from GFX ROM and writes one byte lane of VRAM
// words. Semantics verified against the MAME-port oracle
// (sim/oracle/metro_blitter_oracle.py) by sim/tb/tb_blitter.sv.
//
// ROM port is a request/valid handshake so the integration can arbitrate
// GFX ROM (SDRAM) between blitter, tile fetch and sprite fetch. Protocol:
// o_rom_rd rises with a stable o_rom_addr and stays high until i_rom_valid
// delivers the byte; o_rom_rd then drops for at least one cycle before the
// next request. Because o_rom_rd is registered it is still high during the
// delivery cycle itself: the server MUST NOT treat that cycle as a new
// request (accept only when rd is high and its own valid is low). VRAM
// port carries a 16-bit write mask, always one byte lane.
//
// o_done pulses only when a blit terminates on the STOP opcode (0x00);
// this drives IRQ cause bit 2. A start with an invalid destination tilemap
// returns to idle without o_done, matching MAME.

module metro_blitter #(
    parameter int GFX_AW = 24   // GFX ROM address bits (16 MB)
) (
    input  logic        clk,
    input  logic        rst_n,

    // register interface: values of the 3 blitter register pairs,
    // start pulses when the trigger register (0x7884C) is written
    input  logic        i_start,
    input  logic        i_hold,            // METRO: 1 = the blit in progress waits (the renderer is reading the tile RAM)
    input  logic [31:0] i_tmap,
    input  logic [31:0] i_src,
    input  logic [31:0] i_dst,

    // GFX ROM read port (byte)
    output logic              o_rom_rd,
    output logic [GFX_AW-1:0] o_rom_addr,
    input  logic [15:0]       i_rom_data,        // METRO: a burst of 16 aligned bytes arrives as 8 words (the even byte in [15:8]), one i_rom_valid each
    input  logic              i_rom_valid,

    // VRAM write port
    output logic        o_vram_we,
    output logic [1:0]  o_vram_layer,   // 0..2
    output logic [15:0] o_vram_addr,
    output logic [15:0] o_vram_wdata,
    output logic [15:0] o_vram_wmask,

    output logic        o_busy,
    output logic        o_pend,            // METRO: a start is queued behind the blit in progress (one deep)
    output logic        o_done
);

  typedef enum logic [1:0] {
    S_IDLE, S_OP_RD, S_DATA_RD, S_WRITE
  } state_e;

  state_e      state;
  logic [1:0]  layer;          // tmap - 1
  logic [31:0] src;            // masked to GFX_AW on the bus
  logic [31:0] dst;            // raw >> 8 word offset, upper bits live
  logic        lane_lo;        // dst raw bit 7: 1 = low byte lane
  logic [7:0]  col_restore;    // dst raw bits 15:8
  logic [15:0] b2;             // fill value (inc fills count past 8 bits)
  logic [6:0]  count;          // 1..64
  logic [1:0]  op;

  wire [15:0] dst_word = dst[15:0];
  wire [15:0] wmask = lane_lo ? 16'h00FF : 16'hFF00;

  function automatic logic [15:0] lane_data(input logic [15:0] v);
    // (value << shift) truncated to 16 bits; shift = 8 unless low lane
    lane_data = lane_lo ? v : {v[7:0], 8'h00};
  endfunction

  // count = ((~opcode_byte) & 0x3F) + 1, range 1..64
  function automatic logic [6:0] blit_count(input logic [7:0] b);
    blit_count = {1'b0, ~b[5:0]} + 7'd1;
  endfunction

  // METRO: read-ahead.  The stream is sequential, so a miss fetches the aligned 16 bytes holding the next byte (o_rom_rd stays up for the 8 words) and the following
  // bytes come from the buffer at one a clock.
  logic [7:0]  pf [0:15];
  logic        pf_ok, pf_fill;
  logic [GFX_AW-5:0] pf_tag;
  logic [2:0]  pf_cnt;
  wire  [GFX_AW-5:0] src_blk = src[GFX_AW-1:4];
  wire         pf_hit  = pf_ok && (pf_tag == src_blk);
  wire  [7:0]  pf_byte = pf[src[3:0]];
  assign o_rom_addr = {src[GFX_AW-1:4], 4'b0000};
  assign o_busy = (state != S_IDLE);
  // METRO: one start that arrives while a blit runs (or is held) is kept and runs next (MAME executes every blit the moment the register is written; the chip would drop it).
  logic        q_v;
  assign o_pend = q_v;
  logic [31:0] q_tmap, q_src, q_dst;
  wire  [31:0] go_tmap = q_v ? q_tmap : i_tmap;
  wire  [31:0] go_src  = q_v ? q_src  : i_src;
  wire  [31:0] go_dst  = q_v ? q_dst  : i_dst;
  wire         go      = q_v || i_start;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state        <= S_IDLE;
      q_v          <= 1'b0;
      pf_ok        <= 1'b0;
      pf_fill      <= 1'b0;
      pf_cnt       <= '0;
      pf_tag       <= '0;
      o_vram_we    <= 1'b0;
      o_done       <= 1'b0;
      o_rom_rd     <= 1'b0;
      layer        <= '0;
      src          <= '0;
      dst          <= '0;
      lane_lo      <= 1'b0;
      col_restore  <= '0;
      b2           <= '0;
      count        <= '0;
      op           <= '0;
    end else begin
      o_vram_we <= 1'b0;
      o_done    <= 1'b0;

      // a start while busy (or behind a queued one) is queued, one deep
      if (i_start && (state != S_IDLE || q_v)) begin
        if (!q_v || state == S_IDLE) begin q_v <= 1'b1; q_tmap <= i_tmap; q_src <= i_src; q_dst <= i_dst; end
      end

      // the burst's words
      if (pf_fill && i_rom_valid) begin
        pf[{pf_cnt, 1'b0}] <= i_rom_data[15:8];
        pf[{pf_cnt, 1'b1}] <= i_rom_data[7:0];
        pf_cnt <= pf_cnt + 3'd1;
        if (pf_cnt == 3'd7) begin pf_fill <= 1'b0; pf_ok <= 1'b1; o_rom_rd <= 1'b0; end
      end

      if (i_hold && state != S_IDLE) begin
        // held: nothing advances (a burst in flight still lands in the read-ahead buffer above)
      end else unique case (state)
        S_IDLE: begin
          if (go) begin
            if (q_v && !i_start) q_v <= 1'b0;                 // the queued one runs (a start now takes its place, above)
            pf_ok       <= 1'b0;
            lane_lo     <= go_dst[7];
            col_restore <= go_dst[15:8];
            dst         <= go_dst >> 8;
            src         <= go_src;
            if (go_tmap >= 32'd1 && go_tmap <= 32'd3) begin
              layer <= 2'(go_tmap - 32'd1);
              state <= S_OP_RD;   // S_OP_RD arms the read itself
            end
            // invalid tilemap: stay idle, no done (MAME: return, no IRQ)
          end
        end

        // fetch opcode byte
        S_OP_RD: begin
          if (!pf_hit && !pf_fill) begin
            pf_fill <= 1'b1;                         // miss: fetch the aligned 16 bytes (the address is stable: src does not move meanwhile)
            pf_cnt  <= 3'd0;
            pf_tag  <= src_blk;
            pf_ok   <= 1'b0;
            o_rom_rd <= 1'b1;
          end else if (pf_hit) begin
            src <= src + 1;
            op  <= pf_byte[7:6];
            count <= blit_count(pf_byte);
            unique case (pf_byte[7:6])
              2'd0: begin
                if (pf_byte == 8'h00) begin          // STOP
                  o_done <= 1'b1;
                  state  <= S_IDLE;
                end else begin                       // COPY: data per write
                  state <= S_DATA_RD;
                end
              end
              2'd1, 2'd2: state <= S_DATA_RD;        // one data byte first
              2'd3: begin                            // SKIP, no data bytes
                if (pf_byte == 8'hC0) begin          // next row, restore col
                  dst <= ((dst + 32'h100) & ~32'hFF) | 32'(col_restore);
                end else begin
                  dst <= dst + {25'd0, blit_count(pf_byte)};
                end
                // stay in S_OP_RD; re-arms next cycle
              end
            endcase
          end
        end

        // fetch a data byte (copy: every write; fills: once)
        S_DATA_RD: begin
          if (!pf_hit && !pf_fill) begin
            pf_fill <= 1'b1;
            pf_cnt  <= 3'd0;
            pf_tag  <= src_blk;
            pf_ok   <= 1'b0;
            o_rom_rd <= 1'b1;
          end else if (pf_hit) begin
            src   <= src + 1;
            b2    <= {8'h00, pf_byte};
            state <= S_WRITE;
          end
        end

        S_WRITE: begin
          o_vram_we    <= 1'b1;
          o_vram_layer <= layer;
          o_vram_addr  <= dst_word;
          o_vram_wdata <= lane_data(b2);
          o_vram_wmask <= wmask;
          // dst &= 0xFFFF, then wrap increment within the 256-word row
          dst <= {16'h0000, dst_word[15:8], dst_word[7:0] + 8'd1};
          if (op == 2'd1) b2 <= b2 + 16'd1;
          if (count == 7'd1) begin
            state <= S_OP_RD;
          end else begin
            count <= count - 7'd1;
            if (op == 2'd0) state <= S_DATA_RD;  // COPY: next byte from ROM
            // fills: stay in S_WRITE
          end
        end

        default: state <= S_IDLE;
      endcase
    end
  end

endmodule
