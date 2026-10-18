// The real MiSTer top (Metro.sv's `emu`) with its framework dependencies stubbed (sim/emu/hps_io_stub.sv, pll_stub.sv) and a behavioural SDRAM and Avalon DDR3 on its pins.
// sim/emu/tb_emu.cpp plays the HPS: it loads the ROM image through the ioctl port (streamed, or as the MRA's address= attribute does it), sets OSD options, and captures the
// video as the scaler would receive it (VGA_*).
`default_nettype none
module tb_emu_top #(
    parameter int DDR_LAT      = 24,
    parameter int DDR_BUSY_PCT = 10
) (
    input  logic        CLK_50M,
    input  logic        RESET,
    input  logic        dump_go,                // the SDRAM chip's first +SDRLEN bytes are written to +SDRDUMP
    input  logic        OSD_STATUS,             // the OSD is open (the framework's port: the core's EEPROM save asks for an upload when it opens)
    output logic        CLK_VIDEO, CE_PIXEL,
    output logic  [7:0] VGA_R, VGA_G, VGA_B,
    output logic        VGA_HS, VGA_VS, VGA_DE,
    output logic [15:0] AUDIO_L, AUDIO_R,
    output logic [12:0] VIDEO_ARX, VIDEO_ARY,
    output logic        FB_EN,
    output logic [11:0] FB_WIDTH, FB_HEIGHT,
    input  logic [11:0] HDMI_WIDTH, HDMI_HEIGHT     // the scaler's output size the core's Scale option works against
);
    wire  [45:0] HPS_BUS;
    wire         VGA_F1, VGA_SCALER, VGA_DISABLE, HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT;
    wire   [1:0] VGA_SL, LED_POWER, LED_DISK, BUTTONS, AUDIO_MIX;
    wire         LED_USER, AUDIO_S;
    wire   [3:0] ADC_BUS;
    wire         SD_SCK, SD_MOSI, SD_CS;
    wire   [4:0] FB_FORMAT;
    wire  [31:0] FB_BASE;
    wire  [13:0] FB_STRIDE;
    wire         FB_FORCE_BLANK;
    wire         FB_VBL = 1'b0, FB_LL = 1'b0;
    wire         DDRAM_CLK, DDRAM_BUSY, DDRAM_DOUT_READY, DDRAM_RD, DDRAM_WE;
    wire   [7:0] DDRAM_BURSTCNT, DDRAM_BE;
    wire  [28:0] DDRAM_ADDR;
    wire  [63:0] DDRAM_DOUT, DDRAM_DIN;
    wire         SDRAM_CLK, SDRAM_CKE, SDRAM_DQML, SDRAM_DQMH, SDRAM_nCS, SDRAM_nCAS, SDRAM_nRAS, SDRAM_nWE;
    wire  [12:0] SDRAM_A; wire [1:0] SDRAM_BA; wire [15:0] SDRAM_DQ;
    wire         UART_RTS, UART_TXD, UART_DTR;
    wire   [6:0] USER_OUT;
    wire         CLK_AUDIO = 1'b0, SD_MISO = 1'b0, SD_CD = 1'b0, UART_CTS = 1'b0, UART_RXD = 1'b0, UART_DSR = 1'b0;
    wire   [6:0] USER_IN = 7'h7f;

    emu u_emu (.*);

    sdram_model chip (
        .clk(CLK_50M), .DQ(SDRAM_DQ), .A(SDRAM_A), .BA(SDRAM_BA), .DQML(SDRAM_DQML), .DQMH(SDRAM_DQMH),
        .nCS(SDRAM_nCS), .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE), .CKE(SDRAM_CKE)
    );
    ddr_model #(.AW(24), .LAT(DDR_LAT), .BUSY_PCT(DDR_BUSY_PCT), .FB_STORE(1)) ddr (
        .clk(DDRAM_CLK), .DDRAM_BUSY(DDRAM_BUSY), .DDRAM_BURSTCNT(DDRAM_BURSTCNT), .DDRAM_ADDR(DDRAM_ADDR),
        .DDRAM_DOUT(DDRAM_DOUT), .DDRAM_DOUT_READY(DDRAM_DOUT_READY),
        .DDRAM_RD(DDRAM_RD), .DDRAM_DIN(DDRAM_DIN), .DDRAM_BE(DDRAM_BE), .DDRAM_WE(DDRAM_WE)
    );
    string dpath; integer dlen;
    initial begin
        if (!$value$plusargs("SDRDUMP=%s", dpath)) dpath = "";
        if (!$value$plusargs("SDRLEN=%d", dlen)) dlen = 0;
    end
    logic dg_d;
    always @(posedge CLK_50M) begin
        dg_d <= dump_go;
        if (dump_go && !dg_d && dpath != "") begin
            int fd;
            fd = $fopen(dpath, "wb");
            for (int i = 0; i < dlen; i++) $fwrite(fd, "%c", chip.mem_b[i]);
            $fclose(fd);
        end
    end
    /* verilator lint_off UNUSEDSIGNAL */
    wire unused = ^{VGA_F1, VGA_SCALER, VGA_DISABLE, HDMI_FREEZE, HDMI_BLACKOUT, HDMI_BOB_DEINT, VGA_SL, LED_POWER, LED_DISK,
                    BUTTONS, AUDIO_MIX, LED_USER, AUDIO_S, ADC_BUS, SD_SCK, FB_FORMAT, FB_BASE, FB_STRIDE, FB_FORCE_BLANK,
                    SD_MOSI, SD_CS, SDRAM_CLK, UART_RTS, UART_TXD, UART_DTR, USER_OUT};
    /* verilator lint_on UNUSEDSIGNAL */
endmodule
