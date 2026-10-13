// Lock-step bench of rtl/upd78c10.sv against the golden model (model.cpp): the same Metro sound-CPU environment (program ROM with the bank
// switch on port C, 2 KB RAM at 0x8000, port A latch, port B strobes towards the YM2413 / OKI, the serial command latch) written in SystemVerilog,
// and the same trace format, so that `diff` finds the first instruction where the RTL leaves MAME's behaviour.
//
// The C++ driver (tb_upd78c10.cpp) applies the scripted commands: when the instruction that is about to start has T >= the event's state count it sets
// ev_apply (+ ev_data) for one clock.  Plusargs: +ROM=<hex file, one byte per line>  +TRACE=<output file>
`timescale 1ns/1ps
module tb_upd78c10_top #(parameter int STDIV = 4, parameter int CEDIV = 1) (
    input  logic        clk,
    input  logic        reset,
    input  logic        ev_apply,
    input  logic [7:0]  ev_data,
    input  logic        ev_irq2_set,       // set the INTF2 level to ev_irq2_lvl (one clock, at an instruction boundary)
    input  logic        ev_irq2_lvl,
    input  logic        ym2151,            // 1: the daitorid_portb_w board (port B bit 6 clocks a YM2151, 8 ROM banks)
    output logic        trc_stb,
    output logic [63:0] dbg_t,
    output logic        dbg_illegal
);
    // clock enables
    int cnt_ce = 0, cnt_st = 0;
    logic ce, ce_state;
    always_ff @(posedge clk) begin
        cnt_ce <= (cnt_ce == CEDIV - 1) ? 0 : cnt_ce + 1;
        cnt_st <= (cnt_st == STDIV - 1) ? 0 : cnt_st + 1;
        ce <= (cnt_ce == CEDIV - 1);
        ce_state <= (cnt_st == STDIV - 1);
    end

    // memories
    logic [7:0] rom [0:131071];
    logic [7:0] ram [0:2047];
    string rom_file, trace_file;
    int fd;
    initial begin
        if (!$value$plusargs("ROM=%s", rom_file)) rom_file = "audiocpu.hex";
        if (!$value$plusargs("TRACE=%s", trace_file)) trace_file = "rtl_trace.txt";
        $readmemh(rom_file, rom);
        fd = $fopen(trace_file, "w");
    end

    logic        mem_req, mem_we, mem_ack;
    logic [15:0] mem_a;
    logic [7:0]  mem_wd, mem_rd;
    logic [7:0]  o_pa, o_pb, o_pc, pa_in;
    logic        nmi, rxd_bit, rxd_sample;
    logic        intf2_pin;
    always_ff @(posedge clk) if (reset) intf2_pin <= 1'b0; else if (ev_irq2_set) intf2_pin <= ev_irq2_lvl;
    wire         irq2_rise = ev_irq2_set && ev_irq2_lvl && !intf2_pin;
    logic [15:0] dbg_pc, dbg_ea, dbg_bc, dbg_de, dbg_hl, dbg_sp, dbg_irr;
    logic [7:0]  dbg_a, dbg_v, dbg_psw;
    logic        dbg_iff;

    upd78c10 cpu (
        .clk(clk), .rst(reset), .ce(ce), .ce_state(ce_state),
        .mem_req(mem_req), .mem_we(mem_we), .mem_a(mem_a), .mem_wd(mem_wd), .mem_ack(mem_ack), .mem_rd(mem_rd),
        .pa_in(pa_in), .o_pa(o_pa), .o_pb(o_pb), .o_pc(o_pc),
        .nmi(nmi), .intf2(intf2_pin), .rxd_bit(rxd_bit), .rxd_sample(rxd_sample),
        .trc_stb(trc_stb), .dbg_t(dbg_t), .dbg_pc(dbg_pc), .dbg_ea(dbg_ea), .dbg_bc(dbg_bc), .dbg_de(dbg_de), .dbg_hl(dbg_hl), .dbg_sp(dbg_sp),
        .dbg_irr(dbg_irr), .dbg_a(dbg_a), .dbg_v(dbg_v), .dbg_psw(dbg_psw), .dbg_iff(dbg_iff), .dbg_illegal(dbg_illegal));

    // the bank is selected by port C bits 5:4 (upd7810_rombank_w<3>)
    wire [2:0] bank = ym2151 ? o_pc[6:4] : {1'b0, o_pc[5:4]};
    function automatic [7:0] prog_rd(input [15:0] a, input [2:0] bk);
        if (a < 16'h4000) prog_rd = rom[a];
        else if (a < 16'h8000) prog_rd = rom[{bk, 14'd0} + (a - 16'h4000)];
        else if (a >= 16'h8000 && a < 16'h8800) prog_rd = ram[a - 16'h8000];
        else prog_rd = 8'h00;
    endfunction

    // external bus: acknowledge one clock after the request, hold until it drops
    always_ff @(posedge clk) begin
        if (!mem_req) mem_ack <= 1'b0;
        else if (!mem_ack) begin
            mem_ack <= 1'b1;
            mem_rd <= prog_rd(mem_a, bank);
            if (mem_we && mem_a >= 16'h8000 && mem_a < 16'h8800) ram[mem_a - 16'h8000] <= mem_wd;
        end
    end

    // board: port A latch, port B strobes, serial command latch
    logic [7:0] porta, portb, sound_data;
    logic       busy;
    logic [7:0] prev_pa, prev_pb;
    assign pa_in = porta;
    assign rxd_bit = sound_data[0];
    logic       oki_rd_pend;
    always_ff @(posedge clk) begin
        nmi <= 1'b0;
        if (reset) begin
            porta <= 8'd0; portb <= 8'd0; sound_data <= 8'd0; busy <= 1'b0; prev_pa <= 8'd0; prev_pb <= 8'd0;
        end else begin
            if (rxd_sample) sound_data <= {1'b0, sound_data[7:1]};
            if (ev_apply) begin
                sound_data <= ev_data; busy <= 1'b1; nmi <= 1'b1;
            end
            if (o_pa != prev_pa) begin porta <= o_pa; prev_pa <= o_pa; end
            if (o_pb != prev_pb) begin
                prev_pb <= o_pb;
                if (portb[7] && !o_pb[7]) begin
                    busy <= 1'b0;
                    $fwrite(fd, "E %0d BUSY 0\n", dbg_t);
                    portb <= o_pb;
                end else if (ym2151 && portb[6] && !o_pb[6]) begin
                    if (!o_pb[2] && o_pb[1]) $fwrite(fd, "E %0d YM data %02X\n", dbg_t, porta);
                    if (!o_pb[2] && !o_pb[1]) $fwrite(fd, "E %0d YM reg %02X\n", dbg_t, porta);
                    if (!o_pb[3]) porta <= o_pb[1] ? 8'h00 : 8'hFF;
                    portb <= o_pb;
                end else if (!ym2151 && portb[5] && !o_pb[5]) begin
                    if (!o_pb[2] && o_pb[1]) $fwrite(fd, "E %0d YM data %02X\n", dbg_t, porta);
                    if (!o_pb[2] && !o_pb[1]) $fwrite(fd, "E %0d YM reg %02X\n", dbg_t, porta);
                    portb <= o_pb;
                end else begin
                    if (portb[2] && !o_pb[2] && !o_pb[4]) $fwrite(fd, "E %0d OKI W %02X\n", dbg_t, porta);
                    if (portb[3] && !o_pb[3] && !o_pb[4]) begin porta <= 8'h00; $fwrite(fd, "E %0d OKI R\n", dbg_t); end
                    portb <= o_pb;
                end
            end
        end
    end

    // trace: the state before each instruction (same format as model.cpp), the command event first
    always_ff @(posedge clk) begin
        if (trc_stb && !reset) begin
            if (ev_apply) $fwrite(fd, "E %0d CMD %02X\n", dbg_t, ev_data);
            if (ev_irq2_set) $fwrite(fd, "E %0d IRQ2 %0d\n", dbg_t, ev_irq2_lvl);
            $fwrite(fd, "%0d %04X %02X %02X %02X %04X %04X %04X %04X %04X %02X %0d %04X\n", dbg_t, dbg_pc, prog_rd(dbg_pc, bank), dbg_a, dbg_v, dbg_ea, dbg_bc, dbg_de, dbg_hl,
                    dbg_sp, dbg_psw, dbg_iff, dbg_irr | (ev_apply ? 16'h0001 : 16'h0000) | (irq2_rise ? 16'h0010 : 16'h0000));
        end
    end
    final $fclose(fd);
endmodule
