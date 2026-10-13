// YMF278B wrapper bench (rtl/metro_ymf.sv): MAME's logged writes (C++ driver) into the engine, the wave ROM served like metro_sdram's OKI client (a fixed latency), the mono
// output sampled to a file.
`timescale 1ns/1ps
module tb_ymf_top (
    input  logic        clk,
    input  logic        rst,
    input  logic        wr,
    input  logic  [2:0] a,
    input  logic  [7:0] d,
    input  logic        rd,
    input  logic  [7:0] lat,
    output logic  [7:0] status,
    output logic        irq,
    output logic signed [15:0] audio,
    output logic        stall
);
    logic [7:0] rom [0:4194303];
    initial begin : load
        string p; int fd, n;
        if ($value$plusargs("ROM=%s", p)) begin
            fd = $fopen(p, "rb");
            if (fd == 0) $fatal(1, "cannot open %s", p);
            n = $fread(rom, fd);
            $fclose(fd);
            $display("tb_ymf_top: rom %0d bytes", n);
        end
    end
    logic [21:0] addr;
    logic  [7:0] data;
    logic        ok;
    logic [21:0] served, pend;
    logic        have;
    logic  [7:0] cnt;
    always_ff @(posedge clk) begin
        if (rst) begin have <= 1'b0; served <= '0; pend <= 22'h3FFFFF; cnt <= 8'd0; end
        else if (!have || addr != served) begin
            if (pend != addr) begin pend <= addr; cnt <= lat; end
            else if (cnt != 8'd0) cnt <= cnt - 8'd1;
            else begin served <= addr; data <= rom[addr]; have <= 1'b1; end
        end
    end
    assign ok = have && (addr == served);

    metro_ymf dut (
        .clk(clk), .rst(rst), .i_wr(wr), .i_a(a), .i_d(d), .i_rd(rd), .o_status(status), .o_irq(irq),
        .o_addr(addr), .i_data(data), .i_ok(ok), .o_audio(audio), .o_stall(stall)
    );
endmodule
