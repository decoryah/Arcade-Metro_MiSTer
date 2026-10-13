// NEC uPD78C10 (uPD7810 family) CPU core for the Metro sound CPU.  Instruction-atomic, like MAME 0.289's upd7810 (BSD-3-Clause, Juergen Buchmueller),
// whose code this follows:  the instruction handlers are generated from MAME's source by sim/upd78c10/gen_rtl.py (upd78c10_ops.svh, upd78c10_tab.svh,
// upd78c10_vars.svh), the rest (fetch/decode, skip, bus, interrupts, timers, serial receiver, A/D, ports) is transcribed by hand from upd7810.cpp.
//
// Timing is MAME's: every instruction takes the state count of its table entry (one state = 3 clocks of the 12 MHz crystal = 4 MHz) and the
// peripherals advance by that count before the instruction executes.  The engine itself steps on `ce` (its datapath is multicycle) and an instruction
// is paced to its state count with `ce_state` (4 MHz): a bus access that takes longer only makes the instruction late, never early.
//
// Verified against MAME's code compiled standalone (sim/upd78c10/model.cpp) instruction by instruction: state, flags, interrupt requests, port writes.
`default_nettype none
module upd78c10 (
    input  logic        clk,
    input  logic        rst,
    input  logic        ce,            // engine enable
    input  logic        ce_state,      // one pulse per CPU state (4 MHz)
    // memory: external program ROM / banked ROM / external RAM.  req is held, with stable address and data, until ack; ack is held until req drops
    output logic        mem_req,
    output logic        mem_we,
    output logic [15:0] mem_a,
    output logic [7:0]  mem_wd,
    input  logic        mem_ack,
    input  logic [7:0]  mem_rd,
    // ports: what the chip drives (MAME's callback values) and what the board puts on port A
    input  logic [7:0]  pa_in,
    output logic [7:0]  o_pa,
    output logic [7:0]  o_pb,
    output logic [7:0]  o_pc,
    // NMI request (a pulse of any width) and the serial receiver's data pin (the board shifts its latch on rxd_sample)
    input  logic        nmi,
    input  logic        intf2,         // INTF2 pin, logical level (1 = asserted): the YM2151's IRQ. A rising edge sets IRR bit 0x10; PC3 reads the inverted level
    input  logic        rxd_bit,
    output logic        rxd_sample,
    // trace / debug
    output logic        trc_stb,       // pulses at the start of an instruction; the dbg_ values are the state before it
    output logic [63:0] dbg_t,
    output logic [15:0] dbg_pc, dbg_ea, dbg_bc, dbg_de, dbg_hl, dbg_sp, dbg_irr,
    output logic [7:0]  dbg_a, dbg_v, dbg_psw,
    output logic        dbg_iff,
    output logic        dbg_illegal    // sticky: an opcode without a handler (or a logerror path) was executed
);

    // ------------------------------------------------------------------------------------------ architectural state
    logic [15:0] r_pc, r_sp, r_va, r_bc, r_de, r_hl, r_ea, r_va2, r_bc2, r_de2, r_hl2, r_ea2;
    logic [7:0]  r_psw, r_op, r_op2;
    logic        r_iff, r_iff_pending, r_halt, r_nmi, r_ramview;
    logic [7:0]  r_ma, r_mb, r_mcc, r_mc, r_mm, r_mf, r_mt, r_tmm, r_etmm, r_eom, r_sml, r_smh, r_anm, r_panm, r_mkl, r_mkh, r_zcm;
    logic [7:0]  r_pa_out, r_pb_out, r_pc_out, r_pd_out, r_pf_out;
    logic [7:0]  r_cr0, r_cr1, r_cr2, r_cr3, r_txb, r_rxb;
    logic [7:0]  r_cnt0, r_cnt1, r_tm0, r_tm1;
    logic [15:0] r_ecnt, r_ecpt, r_etm0, r_etm1, r_irr, r_itf;
    logic        r_to, r_txd, r_rxd, r_sck, r_co0, r_co1, r_edges, r_illegal;
    logic [15:0] r_rxs;
    logic [3:0]  r_rxcnt;
    logic [31:0] r_ovc0, r_ovc1, r_ovcs, r_adcnt, r_adtot;
    logic [7:0]  r_tmpcr;
    logic        r_shdone;
    logic [1:0]  r_adout, r_adin;
    logic [2:0]  r_adrange;

    logic [7:0] iram [0:255];

    // ------------------------------------------------------------------------------------------ engine registers
    typedef enum logic [4:0] {
        S_FETCH, S_DECODE, S_FETCH2, S_DECODE2, S_TIM, S_EXEC, S_BUS, S_BUSW, S_PAD, S_IRQ0, S_IRQ1, S_IRQ2, S_IRQ3, S_HALT
    } st_e;
    st_e st, bus_ret, tim_next;

    localparam logic [1:0] BUS_NONE = 2'd0, BUS_RD = 2'd1, BUS_WR = 2'd2;
    logic [1:0]  bus_op;
    logic [15:0] bus_a;
    logic [7:0]  bus_wd;
    logic [7:0]  rd_data;
    logic [31:0] rd_data32;
    logic [31:0] x32, xa32, xd32;
    logic [9:0]  hid;
    logic [7:0]  hstep;
    logic        ex_done;
    logic [5:0]  cc;                 // state count of the current instruction
    logic [5:0]  pace;
    logic [3:0]  tsub;
    logic [31:0] t0div, t1div, sio_half;
    logic [15:0] irq_vec, irq_msk;
    logic        skip_iff_update;
    logic [63:0] tstates;
    logic [2:0]  tid;
    logic [26:0] tb;
    logic        illegal_seen;
    logic        sample_q, nmi_lat, intf2_q, intf2_lat;
    logic [2:0]  sio_wait;           // engine ticks to wait after a serial sample, until the board's latch has shifted

    `include "upd78c10_vars.svh"
    `include "upd78c10_tab.svh"

    assign dbg_illegal = r_illegal;

    // ------------------------------------------------------------------------------------------ ports (RP / WP / read_pc / write_pc of upd7810.cpp)
    function automatic [7:0] read_pc_f(input dummy);
        logic [7:0] d;
        begin
            d = (8'h00 & r_mc) | (r_pc_out & ~r_mc);            // no input callback: m_pc_in stays 0
            if (r_mcc[0]) d[0] = r_txd;
            if (r_mcc[1]) d[1] = r_rxd;
            if (r_mcc[2]) d[2] = r_sck;
            if (r_mcc[3]) d[3] = !intf2_q;                      // m_int2: physical (inverted) INT2 pin, reset value 1
            if (r_mcc[4]) d[4] = r_to;
            if (r_mcc[5]) d[5] = 1'b0;                          // CI
            if (r_mcc[6]) d[6] = r_co0;
            if (r_mcc[7]) d[7] = r_co1;
            read_pc_f = d;
        end
    endfunction

    function automatic [7:0] rp(input [31:0] port);
        logic [7:0] d;
        begin
            case (port[2:0])
                3'd0: rp = (pa_in & r_ma) | (r_pa_out & ~r_ma);
                3'd1: rp = (8'h00 & r_mb) | (r_pb_out & ~r_mb);
                3'd2: rp = read_pc_f(1'b0);
                3'd3: case (r_mm[2:0])
                        3'd0:    rp = 8'h00;                    // PD input mode: m_pd_in stays 0
                        3'd1:    rp = r_pd_out;
                        default: rp = 8'hff;
                      endcase
                3'd4: begin
                        d = (8'h00 & r_mf) | (r_pf_out & ~r_mf);
                        case (r_mm[2:1])
                            2'd0: rp = d;
                            2'd1: rp = d | 8'h0f;
                            2'd2: rp = d | 8'h3f;
                            default: rp = 8'hff;
                        endcase
                      end
                default: rp = 8'h00;                            // PT
            endcase
        end
    endfunction

    function automatic [7:0] pc_cb(input [7:0] data);
        logic [7:0] d;
        begin
            d = (data & ~r_mc) | (8'hff & r_mc);
            if (r_mcc[0]) d[0] = r_txd;
            if (r_mcc[1]) d[1] = r_rxd;
            if (r_mcc[2]) d[2] = r_sck;
            if (r_mcc[3]) d[3] = 1'b1;
            if (r_mcc[4]) d[4] = r_to;
            if (r_mcc[5]) d[5] = 1'b0;
            if (r_mcc[6]) d[6] = r_co0;
            if (r_mcc[7]) d[7] = r_co1;
            pc_cb = d;
        end
    endfunction

    function automatic [31:0] sext8(input [31:0] v);
        sext8 = {{24{v[7]}}, v[7:0]};
    endfunction
    function automatic [31:0] sra32(input [31:0] v, input [31:0] n);
        sra32 = $signed(v) >>> n;
    endfunction

    task wp(input [2:0] port, input [7:0] data);
        begin
            case (port)
                3'd0: begin r_pa_out = data; o_pa <= (data & ~r_ma) | (8'hff & r_ma); end
                3'd1: begin r_pb_out = data; o_pb <= (data & ~r_mb) | (8'hff & r_mb); end
                3'd2: begin r_pc_out = data; o_pc <= pc_cb(data); end
                3'd3: r_pd_out = data;
                3'd4: r_pf_out = data;
                default: ;
            endcase
        end
    endtask

    task zhc_add(input [31:0] v_aft, input [31:0] v_bef, input [31:0] carry);
        begin
            if (v_aft == 32'd0) r_psw[6] = 1'b1; else r_psw[6] = 1'b0;
            if (v_aft == v_bef) r_psw[0] = carry[0];
            else if (v_aft < v_bef) r_psw[0] = 1'b1;
            else r_psw[0] = 1'b0;
            if ((v_aft & 32'd15) < (v_bef & 32'd15)) r_psw[4] = 1'b1; else r_psw[4] = 1'b0;
        end
    endtask

    task zhc_sub(input [31:0] v_aft, input [31:0] v_bef, input [31:0] carry);
        begin
            if (v_aft == 32'd0) r_psw[6] = 1'b1; else r_psw[6] = 1'b0;
            if (v_bef == v_aft) r_psw[0] = carry[0];
            else if (v_aft > v_bef) r_psw[0] = 1'b1;
            else r_psw[0] = 1'b0;
            if ((v_aft & 32'd15) > (v_bef & 32'd15)) r_psw[4] = 1'b1; else r_psw[4] = 1'b0;
        end
    endtask

    task do_write_smh(input [7:0] data);
        begin
            if (!r_smh[2] && data[2]) r_irr = r_irr | 16'h0400;      // INTFST
            r_smh = data;
        end
    endtask
    task do_write_eom(input [7:0] data);
        begin
            r_eom = data;                                           // TO / CO0 / CO1 outputs are not wired on the Metro board
        end
    endtask
    task do_write_txb(input [7:0] data);
        begin
            r_txb = data;                                           // the serial transmitter is not used by the sound program
        end
    endtask

    // ------------------------------------------------------------------------------------------ interrupt priority chain (upd7810_take_irq)
    logic [15:0] chain_vec, chain_msk;
    always_comb begin
        chain_vec = 16'h0000; chain_msk = 16'h0000;
        if (r_irr[0]) begin chain_vec = 16'h0004; chain_msk = 16'h0001; end
        else if (r_irr[1]  && !r_mkl[1]) begin chain_vec = 16'h0008; if (r_mkl[2]) chain_msk = 16'h0002; end
        else if (r_irr[2]  && !r_mkl[2]) begin chain_vec = 16'h0008; if (r_mkl[1]) chain_msk = 16'h0004; end
        else if (r_irr[3]  && !r_mkl[3]) begin chain_vec = 16'h0010; if (r_mkl[4]) chain_msk = 16'h0008; end
        else if (r_irr[4]  && !r_mkl[4]) begin chain_vec = 16'h0010; if (r_mkl[3]) chain_msk = 16'h0010; end
        else if (r_irr[5]  && !r_mkl[5]) begin chain_vec = 16'h0018; if (r_mkl[6]) chain_msk = 16'h0020; end
        else if (r_irr[6]  && !r_mkl[6]) begin chain_vec = 16'h0018; if (r_mkl[5]) chain_msk = 16'h0040; end
        else if (r_irr[7]  && !r_mkl[7]) begin chain_vec = 16'h0020; if (r_mkh[0]) chain_msk = 16'h0080; end
        else if (r_irr[8]  && !r_mkh[0]) begin chain_vec = 16'h0020; if (r_mkl[7]) chain_msk = 16'h0100; end
        else if (r_irr[9]  && !r_mkh[1]) begin chain_vec = 16'h0028; if (r_mkh[2]) chain_msk = 16'h0200; end
        else if (r_irr[10] && !r_mkh[2]) begin chain_vec = 16'h0028; if (r_mkh[1]) chain_msk = 16'h0400; end
    end

    // ------------------------------------------------------------------------------------------ the engine
    always @(posedge clk) begin
        sample_q <= 1'b0;
        rxd_sample <= sample_q;
        trc_stb <= 1'b0;
        if (rst) begin
            st <= S_FETCH; bus_ret <= S_FETCH; tim_next <= S_EXEC;
            bus_op <= BUS_NONE; mem_req <= 1'b0; mem_we <= 1'b0; mem_a <= 16'd0; mem_wd <= 8'd0; ex_done <= 1'b0; hstep <= 8'd0; hid <= 10'd0;
            cc <= 6'd0; pace <= 6'd0; tsub <= 4'd0; sio_wait <= 3'd0; nmi_lat <= 1'b0; intf2_q <= 1'b0; intf2_lat <= 1'b0; tstates <= 64'd0; skip_iff_update <= 1'b0;
            bus_a <= 16'd0; bus_wd <= 8'd0; rd_data <= 8'd0; rd_data32 = 32'd0; x32 = 32'd0; illegal_seen = 1'b0; r_illegal <= 1'b0;
            o_pa <= 8'd0; o_pb <= 8'd0; o_pc <= 8'd0;
            r_pc = 16'd0; r_sp = 16'd0; r_va = 16'd0; r_bc = 16'd0; r_de = 16'd0; r_hl = 16'd0; r_ea = 16'd0; r_va2 = 16'd0; r_bc2 = 16'd0; r_de2 = 16'd0; r_hl2 = 16'd0; r_ea2 = 16'd0;
            r_psw = 8'd0; r_op = 8'd0; r_op2 = 8'd0; r_iff = 1'b0; r_iff_pending = 1'b0; r_halt = 1'b0; r_nmi = 1'b0; r_ramview = 1'b1;
            r_ma = 8'hff; r_mb = 8'hff; r_mcc = 8'd0; r_mc = 8'hff; r_mm = 8'd0; r_mf = 8'hff; r_mt = 8'd0; r_tmm = 8'hff; r_etmm = 8'hff; r_eom = 8'd0;
            r_sml = 8'd0; r_smh = 8'd0; r_anm = 8'd0; r_panm = 8'hff; r_mkl = 8'hff; r_mkh = 8'hff; r_zcm = 8'd0;
            r_pa_out = 8'd0; r_pb_out = 8'd0; r_pc_out = 8'd0; r_pd_out = 8'd0; r_pf_out = 8'd0;
            r_cr0 = 8'd0; r_cr1 = 8'd0; r_cr2 = 8'd0; r_cr3 = 8'd0; r_txb = 8'd0; r_rxb = 8'd0;
            r_cnt0 = 8'd0; r_cnt1 = 8'd0; r_tm0 = 8'd0; r_tm1 = 8'd0; r_ecnt = 16'd0; r_ecpt = 16'd0; r_etm0 = 16'd0; r_etm1 = 16'd0; r_irr = 16'd0; r_itf = 16'd0;
            r_to = 1'b0; r_txd = 1'b0; r_rxd = 1'b0; r_sck = 1'b0; r_co0 = 1'b0; r_co1 = 1'b0; r_edges = 1'b0; r_rxs = 16'hffff; r_rxcnt = 4'd0;
            r_ovc0 = 32'd0; r_ovc1 = 32'd0; r_ovcs = 32'd0; r_adcnt = 32'd0; r_adtot = 32'd0; r_tmpcr = 8'd0; r_shdone = 1'b0; r_adout = 2'd0; r_adin = 2'd0; r_adrange = 3'd0;
        end else begin
            if (nmi) nmi_lat <= 1'b1;                                // NMI is edge sensitive: a pulse (any width) sets the request on the next engine step
            intf2_q <= intf2;                                        // INTF2: set_input_line sets IRR when the logical level rises (upd7810.cpp execute_set_input)
            if (intf2 && !intf2_q) intf2_lat <= 1'b1;
            if (ce_state && pace != 6'h3f) pace <= pace + 6'd1;
            if (ce) begin
                if (nmi_lat) begin r_irr = r_irr | 16'h0001; nmi_lat <= 1'b0; end
                if (intf2_lat) begin r_irr = r_irr | 16'h0010; intf2_lat <= 1'b0; end
                case (st)
                // ---------------------------------------------------------------- opcode fetch / decode
                S_FETCH: begin
                    if (r_halt) begin
                        st <= S_HALT;
                    end else begin
                        trc_stb <= 1'b1;
                        dbg_t <= tstates; dbg_pc <= r_pc; dbg_ea <= r_ea; dbg_bc <= r_bc; dbg_de <= r_de; dbg_hl <= r_hl; dbg_sp <= r_sp; dbg_irr <= r_irr;
                        dbg_a <= r_va[7:0]; dbg_v <= r_va[15:8]; dbg_psw <= r_psw; dbg_iff <= r_iff;
                        pace <= 6'd0;
                        bus_a <= r_pc; bus_op <= BUS_RD; bus_ret <= S_DECODE; st <= S_BUS;
                        r_pc = r_pc + 16'd1;
                    end
                end
                S_DECODE: begin
                    r_op = rd_data;
                    tb = tab({3'd0, rd_data});
                    r_psw = r_psw & ~{4'b0, tb[1], tb[0], 2'b00};               // L0 / L1 overlay flags
                    if (tb[13:8] == 6'd0) begin                                  // prefix opcode (cycles = 0 in the first table)
                        bus_a <= r_pc; bus_op <= BUS_RD; bus_ret <= S_DECODE2; st <= S_BUS;
                        r_pc = r_pc + 16'd1;
                    end else if (r_psw[5] && rd_data != 8'h72) begin             // skip flag set, not SOFTI
                        cc <= tb[7:2];
                        r_pc = r_pc + {13'd0, tb[16:14]} - 16'd1;
                        r_psw[5] = 1'b0;
                        tim_next <= S_PAD; tsub <= 4'd0; st <= S_TIM;
                    end else begin
                        cc <= tb[13:8]; hid <= tb[26:17];
                        ex_done <= 1'b0; hstep <= 8'd0; bus_op <= BUS_NONE;
                        tim_next <= S_EXEC; tsub <= 4'd0; st <= S_TIM;
                    end
                end
                S_DECODE2: begin
                    r_op2 = rd_data;
                    case (r_op)
                        8'h48: tid = 3'd1;  8'h4c: tid = 3'd2;  8'h4d: tid = 3'd3;  8'h60: tid = 3'd4;
                        8'h64: tid = 3'd5;  8'h70: tid = 3'd6;  default: tid = 3'd7;
                    endcase
                    tb = tab({tid, rd_data});
                    if (r_psw[5]) begin
                        cc <= tb[7:2];
                        r_pc = r_pc + {13'd0, tb[16:14]} - 16'd2;
                        r_psw[5] = 1'b0;
                        tim_next <= S_PAD; tsub <= 4'd0; st <= S_TIM;
                    end else begin
                        cc <= tb[13:8]; hid <= tb[26:17];
                        ex_done <= 1'b0; hstep <= 8'd0; bus_op <= BUS_NONE;
                        tim_next <= S_EXEC; tsub <= 4'd0; st <= S_TIM;
                    end
                end
                // ---------------------------------------------------------------- peripherals advance by the instruction's state count (handle_timers)
                S_TIM: begin
                    case (tsub)
                    4'd0: begin                                                  // timer 0
                        if (r_tmm[4]) begin r_cnt0 = 8'd0; tsub <= 4'd2; end
                        else begin
                            case (r_tmm[3:2]) 2'd0: t0div = 32'd4; 2'd1: t0div = 32'd128; default: t0div = 32'd0; endcase
                            if (t0div == 32'd0 && r_tmm[3:2] != 2'd0 && r_tmm[3:2] != 2'd1) tsub <= 4'd2;
                            else begin r_ovc0 = r_ovc0 + {26'd0, cc}; tsub <= 4'd1; end
                        end
                    end
                    4'd1: begin
                        if (r_ovc0 >= t0div) begin
                            r_ovc0 = r_ovc0 - t0div;
                            r_cnt0 = r_cnt0 + 8'd1;
                            if (r_cnt0 == r_tm0) begin
                                r_cnt0 = 8'd0;
                                r_irr = r_irr | 16'h0002;                        // INTFT0
                                if (r_tmm[1:0] == 2'd0) r_to = ~r_to;
                                if ((r_tmm & 8'he0) == 8'h60) begin               // timer 1 chained with timer 0
                                    r_cnt1 = r_cnt1 + 8'd1;
                                    if (r_cnt1 == r_tm1) begin
                                        r_cnt1 = 8'd0;
                                        r_irr = r_irr | 16'h0004;                // INTFT1
                                        if (r_tmm[1:0] == 2'd1) r_to = ~r_to;
                                    end
                                end
                            end
                        end else tsub <= 4'd2;
                    end
                    4'd2: begin                                                  // timer 1
                        if (r_tmm[7]) begin r_cnt1 = 8'd0; tsub <= 4'd4; end
                        else begin
                            case (r_tmm[6:5]) 2'd0: t1div = 32'd4; 2'd1: t1div = 32'd128; default: t1div = 32'd0; endcase
                            if (r_tmm[6:5] > 2'd1) tsub <= 4'd4;
                            else begin r_ovc1 = r_ovc1 + {26'd0, cc}; tsub <= 4'd3; end
                        end
                    end
                    4'd3: begin
                        if (r_ovc1 >= t1div) begin
                            r_ovc1 = r_ovc1 - t1div;
                            r_cnt1 = r_cnt1 + 8'd1;
                            if (r_cnt1 == r_tm1) begin
                                r_cnt1 = 8'd0;
                                r_irr = r_irr | 16'h0004;
                                if (r_tmm[1:0] == 2'd1) r_to = ~r_to;
                            end
                        end else tsub <= 4'd4;
                    end
                    4'd4: begin                                                  // timer F/F (cosmetic) and event timer (only the cleared state is used)
                        if ((r_etmm & 8'h0c) == 8'h00) r_ecnt = 16'd0;
                        tsub <= 4'd5;
                    end
                    4'd5: begin                                                  // serial interface, internal clock modes
                        if (r_smh[1:0] == 2'd1 || r_smh[1:0] == 2'd2) begin
                            case (r_smh[1:0]) 2'd1: sio_half = 32'd128; default: sio_half = 32'd8; endcase
                            case (r_sml[1:0]) 2'd2: sio_half = sio_half * 16; 2'd3: sio_half = sio_half * 64; default: ; endcase
                            sio_half = sio_half >> 1;
                            r_ovcs = r_ovcs + {26'd0, cc};
                            tsub <= 4'd6;
                        end else tsub <= 4'd8;
                    end
                    4'd6: begin
                        if (sio_wait != 3'd0) sio_wait <= sio_wait - 3'd1;
                        else if (r_ovcs >= sio_half) begin
                            r_ovcs = r_ovcs - sio_half;
                            r_edges = ~r_edges;
                            if (!r_edges) begin                                  // rising edge: receive
                                if (r_rxcnt != 4'd0) begin
                                    r_rxd = rxd_bit; sample_q <= 1'b1; sio_wait <= 3'd3;
                                    r_rxs = {rxd_bit, r_rxs[15:1]};
                                    r_rxcnt = r_rxcnt - 4'd1;
                                    if (r_rxcnt == 4'd0) begin
                                        r_smh = r_smh & 8'hbf;
                                        r_irr = r_irr | 16'h0200;                // INTFSR
                                        if (r_sml[1:0] != 2'd0) r_illegal <= 1'b1;   // asynchronous formats are not implemented
                                        else r_rxb = r_rxs[15:8];
                                    end
                                end else if (r_smh[3]) begin
                                    if (r_sml[1:0] != 2'd0) r_illegal <= 1'b1;
                                    else if (r_smh[6]) r_rxcnt = 4'd8;
                                end
                            end
                        end else tsub <= 4'd8;
                    end
                    default: begin                                               // A/D converter (the inputs read 0)
                        r_adcnt = r_adcnt + {26'd0, cc};
                        if (r_panm != r_anm) begin
                            r_adcnt = 32'd0;
                            r_adtot = r_anm[4] ? 32'd144 : 32'd192;
                            r_adout = 2'd0; r_shdone = 1'b0;
                            if (r_anm[0]) r_adin = r_anm[3:1];
                            else begin r_adin = 2'd0; r_adrange = {r_anm[3], 2'b00}; end
                        end
                        r_panm = r_anm;
                        if (!r_shdone) begin r_tmpcr = 8'd0; r_shdone = 1'b1; end
                        if (r_adcnt > r_adtot) begin
                            r_adcnt = r_adcnt - r_adtot;
                            case (r_adout) 2'd0: r_cr0 = r_tmpcr; 2'd1: r_cr1 = r_tmpcr; 2'd2: r_cr2 = r_tmpcr; default: r_cr3 = r_tmpcr; endcase
                            if (!r_anm[0]) r_adin = r_adin + 2'd1;
                            r_adout = r_adout + 2'd1;
                            if (r_adout == 2'd0) r_irr = r_irr | 16'h0100;       // INTFAD
                            r_shdone = 1'b0;
                        end
                        st <= tim_next;
                    end
                    endcase
                end
                // ---------------------------------------------------------------- instruction body: generated steps
                S_EXEC: begin
                    if (bus_op != BUS_NONE) begin
                        bus_ret <= S_EXEC; st <= S_BUS;
                    end else if (ex_done) begin
                        ex_done <= 1'b0;
                        st <= S_PAD;
                    end else begin
                        `include "upd78c10_ops.svh"
                    end
                end
                // ---------------------------------------------------------------- bus access (internal RAM at 0xff00 or the external bus)
                S_BUS: begin
                    if (bus_a[15:8] == 8'hff && r_ramview) begin
                        if (bus_op == BUS_WR) iram[bus_a[7:0]] <= bus_wd;
                        else rd_data <= iram[bus_a[7:0]];
                        bus_op <= BUS_NONE;
                        st <= bus_ret;
                    end else begin
                        mem_req <= 1'b1; mem_we <= (bus_op == BUS_WR); mem_a <= bus_a; mem_wd <= bus_wd;
                        st <= S_BUSW;
                    end
                end
                S_BUSW: begin
                    if (mem_ack) begin
                        rd_data <= mem_rd;
                        mem_req <= 1'b0; mem_we <= 1'b0;
                        bus_op <= BUS_NONE;
                        st <= bus_ret;
                    end
                end
                // ---------------------------------------------------------------- end of instruction: pace to the state count, then interrupts
                S_PAD: begin
                    if (pace >= cc) begin
                        tstates <= tstates + {58'd0, cc};
                        irq_vec <= chain_vec; irq_msk <= chain_msk;
                        if (chain_vec != 16'd0) begin
                            r_halt = 1'b0;
                            if (r_iff || r_irr[0]) begin
                                st <= S_IRQ0;
                            end else begin
                                r_iff = r_iff_pending;
                                st <= S_FETCH;
                            end
                        end else begin
                            r_iff = r_iff_pending;
                            st <= S_FETCH;
                        end
                    end
                end
                S_IRQ0: begin
                    r_sp = r_sp - 16'd1;
                    bus_a <= r_sp; bus_wd <= r_psw; bus_op <= BUS_WR; bus_ret <= S_IRQ1; st <= S_BUS;
                end
                S_IRQ1: begin
                    r_sp = r_sp - 16'd1;
                    bus_a <= r_sp; bus_wd <= r_pc[15:8]; bus_op <= BUS_WR; bus_ret <= S_IRQ2; st <= S_BUS;
                end
                S_IRQ2: begin
                    r_sp = r_sp - 16'd1;
                    bus_a <= r_sp; bus_wd <= r_pc[7:0]; bus_op <= BUS_WR; bus_ret <= S_IRQ3; st <= S_BUS;
                end
                S_IRQ3: begin
                    r_iff = 1'b0; r_iff_pending = 1'b0;
                    r_irr = r_irr & ~irq_msk;
                    r_psw = r_psw & ~8'h2c;                                      // SK | L0 | L1
                    r_pc = irq_vec;
                    r_iff = r_iff_pending;
                    st <= S_FETCH;
                end
                // ---------------------------------------------------------------- HLT: one state per tick until an interrupt is pending
                S_HALT: begin
                    if (ce_state) begin
                        cc <= 6'd1; pace <= 6'd1;
                        tstates <= tstates + 64'd1;
                        tim_next <= S_PAD; tsub <= 4'd0; st <= S_TIM;
                    end
                end
                default: st <= S_FETCH;
                endcase
            end
            if (illegal_seen) begin r_illegal <= 1'b1; illegal_seen = 1'b0; end
        end
    end
endmodule
`default_nettype wire
