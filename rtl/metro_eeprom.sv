// 93C46 serial EEPROM, 16-bit organisation (64 words), as used by Mahjong Doukyuusei Special (and Gakuensai 1 / 2).  Written from the chip's data sheet (and MAME's eeprom_serial_93cxx
// behaviour: the bits are clocked by the 68000's accesses, metro.cpp dokyusp_eeprom_* / gakusai_eeprom_*).
//
// Protocol (CS high): a start bit 1, a 2-bit opcode, a 6-bit address, each bit taken at a clock edge (DI at the edge):
//   10 READ   after the last address bit DO is 0 (a dummy bit), then every clock edge shifts the next data bit out, MSB first; the address then counts on (sequential read)
//   01 WRITE  16 data bits follow, the word is written after the last one (needs the write enable)
//   11 ERASE  the word becomes FFFF (needs the write enable)
//   00 with address bits 5:4 = 11 EWEN (write enable), 00 EWDS (write disable), 10 ERAL (erase all), 01 WRAL (write all, 16 data bits follow)
// The write cycle is taken as instantaneous (DO = 1, ready, afterwards).  The chip powers up write-disabled.  CS low resets the state machine.
// The contents at power-up come from the image: the loader sends the 128 bytes (big-endian words) of MAME's "eeprom" region (i_ld_*); they are not saved.
`default_nettype none
module metro_eeprom (
    input  logic        clk,
    input  logic        i_cs,
    input  logic        i_clk,            // one clock cycle = one rising edge of the chip's clock input
    input  logic        i_di,
    output logic        o_do,
    input  logic        i_ld_wr,          // initial contents, one byte per clock: byte address 0..127, big endian words
    input  logic [6:0]  i_ld_addr,
    input  logic [7:0]  i_ld_data
);
    logic [15:0] mem [0:63];
    initial for (int i = 0; i < 64; i++) mem[i] = 16'hFFFF;

    typedef enum logic [2:0] {S_START, S_CMD, S_READ, S_WDATA, S_DONE} st_e;
    st_e         st;
    logic [3:0]  cnt;                      // command bits taken
    logic [7:0]  cmd;
    logic [15:0] sh;
    logic [4:0]  shcnt;
    logic [5:0]  addr;
    logic        wen, wall, dout;
    wire  [7:0]  cmd_n = {cmd[6:0], i_di};

    assign o_do = dout;

    always_ff @(posedge clk) begin
        if (i_ld_wr) begin
            if (!i_ld_addr[0]) mem[i_ld_addr[6:1]][15:8] <= i_ld_data;
            else               mem[i_ld_addr[6:1]][7:0]  <= i_ld_data;
        end
        if (!i_cs) begin
            st   <= S_START;
            cnt  <= '0;
            dout <= 1'b1;
        end else if (i_clk) begin
            case (st)
                S_START: if (i_di) begin st <= S_CMD; cnt <= '0; end
                S_CMD: begin
                    cmd <= cmd_n;
                    cnt <= cnt + 4'd1;
                    if (cnt == 4'd7) begin
                        addr <= cmd_n[5:0];
                        case (cmd_n[7:6])
                            2'b10: begin sh <= mem[cmd_n[5:0]]; shcnt <= '0; dout <= 1'b0; st <= S_READ; end
                            2'b01: begin sh <= '0; shcnt <= '0; wall <= 1'b0; st <= S_WDATA; end
                            2'b11: begin if (wen) mem[cmd_n[5:0]] <= 16'hFFFF; dout <= 1'b1; st <= S_DONE; end
                            default: begin
                                case (cmd_n[5:4])
                                    2'b11: wen <= 1'b1;
                                    2'b00: wen <= 1'b0;
                                    2'b10: if (wen) for (int i = 0; i < 64; i++) mem[i] <= 16'hFFFF;
                                    default: begin sh <= '0; shcnt <= '0; wall <= 1'b1; st <= S_WDATA; end      // WRAL
                                endcase
                                if (cmd_n[5:4] != 2'b01) begin dout <= 1'b1; st <= S_DONE; end
                            end
                        endcase
                    end
                end
                S_READ: begin
                    dout  <= sh[15];
                    if (shcnt == 5'd15) begin
                        shcnt <= '0;
                        addr  <= addr + 6'd1;
                        sh    <= mem[addr + 6'd1];
                    end else begin
                        shcnt <= shcnt + 5'd1;
                        sh    <= {sh[14:0], 1'b0};
                    end
                end
                S_WDATA: begin
                    sh    <= {sh[14:0], i_di};
                    shcnt <= shcnt + 5'd1;
                    if (shcnt == 5'd15) begin
                        if (wen) begin
                            if (wall) for (int i = 0; i < 64; i++) mem[i] <= {sh[14:0], i_di};
                            else      mem[addr] <= {sh[14:0], i_di};
                        end
                        dout <= 1'b1;
                        st   <= S_DONE;
                    end
                end
                default: ;
            endcase
        end
    end

    initial begin st = S_START; cnt = 0; dout = 1'b1; wen = 1'b0; wall = 1'b0; end
endmodule
`default_nettype wire
