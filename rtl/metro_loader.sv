// ROM download path of the Metro core: sits between the framework's ioctl stream (the MRA image, tools/metro_rom.py) and the SDRAM arbiter.
//  * the 32-byte configuration block arrives first (image offset 0): board id, rotation, GFX scramble mode, GFX size are captured here;
//  * the GFX ROM (image offset 0x100000, 4 MB slot) is passed through the driver's init permutation (init_dharmak / init_balcube of
//    metro.cpp 0.289) on its way into SDRAM, so the video chip reads MAME's post-init data and the permutation costs nothing at run time;
//  * everything else is passed through unchanged (the SDRAM holds the image as streamed, byte address = image offset).
//
// Configuration bytes: [0] board [1] rotation (0..3) [2] GFX scramble (0 none, 1 init_dharmak, 2 init_balcube) [3:6] GFX size (bytes, LE)
`default_nettype none
module metro_loader (
    input  logic        clk,
    input  logic        dl_wr,                 // one clock per byte
    input  logic [25:0] dl_addr,               // byte address in the image
    input  logic [7:0]  dl_data,
    output logic        o_wr,
    output logic [25:0] o_addr,
    output logic [7:0]  o_data,
    output logic [7:0]  cfg_board,
    output logic [1:0]  cfg_rot,
    output logic [1:0]  cfg_scramble,
    output logic [31:0] cfg_gfxsize,
    output logic        ee_wr,                 // the EEPROM's initial contents (image offset 0x100..0x17F, tools/metro_rom.py EEPROM_OFF): Mahjong Doukyuusei Special's 93C46
    output logic [6:0]  ee_addr,
    output logic [7:0]  ee_data
);
    localparam [25:0] GFX_BASE = 26'h100000;
    localparam [25:0] GFX_END  = 26'h500000;

    logic [7:0] cfg [0:6];
    initial begin
        cfg[0] = 8'd0; cfg[1] = 8'd0; cfg[2] = 8'd0; cfg[3] = 8'd0; cfg[4] = 8'd0; cfg[5] = 8'd0; cfg[6] = 8'd0;
    end
    always_ff @(posedge clk)
        if (dl_wr && dl_addr < 26'd7) cfg[dl_addr[2:0]] <= dl_data;

    assign cfg_board    = cfg[0];
    assign cfg_rot      = cfg[1][1:0];
    assign cfg_scramble = cfg[2][1:0];
    assign cfg_gfxsize  = {cfg[6], cfg[5], cfg[4], cfg[3]};

    // init_dharmak: bytes 1 and 3 of every 4-byte group; init_balcube: every even byte bit-reversed
    // (metro_rom.py init_dharmak / init_balcube; bitswap8 lists the source bit of each output bit from bit 7 down)
    // METRO (family C): the GFX region ends at its own size (a 2 MB set's samples follow it at 0x300000: the permutation ran over them up to the slot's 4 MB and left the
    // even bytes of Mouse Shooter GoGo's and Daitoride's wave ROM bit-reversed); GFX_END is the slot's end for a size the header does not say
    wire [25:0] gfx_end = (cfg_gfxsize[25:0] != 26'd0) ? (GFX_BASE + cfg_gfxsize[25:0]) : GFX_END;
    wire in_gfx = (dl_addr >= GFX_BASE) && (dl_addr < gfx_end);
    logic [7:0] perm;
    always_comb begin
        perm = dl_data;
        if (in_gfx) begin
            case (cfg_scramble)
                2'd1: begin
                    if (dl_addr[1:0] == 2'd1) perm = {dl_data[7], dl_data[3], dl_data[2], dl_data[4], dl_data[5], dl_data[6], dl_data[1], dl_data[0]};
                    if (dl_addr[1:0] == 2'd3) perm = {dl_data[7], dl_data[2], dl_data[5], dl_data[4], dl_data[3], dl_data[6], dl_data[1], dl_data[0]};
                end
                2'd2: begin
                    if (!dl_addr[0]) perm = {dl_data[0], dl_data[1], dl_data[2], dl_data[3], dl_data[4], dl_data[5], dl_data[6], dl_data[7]};
                end
                default: ;
            endcase
        end
    end

    // METRO (family F, Grand Striker 2 = board 19): the 053936's tile ROM (gfx2, 2 MB at image offset 0x100000 + the GFX size + 0x220000) holds 16 x 16 tiles as four 8 x 8
    // quadrants of 64 bytes (TL, TR, BL, BR): a tile row is two 8-byte pieces 64 bytes apart.  The plane engine fetches one tile row per request, so the rows are stored in
    // raster order: byte {qy, y[2:0], qx, x[2:0]} of a tile goes to {qy, y[2:0]} * 16 + qx * 8 + x[2:0] -- bits 6 and 5:3 of the offset swap places (pure address permutation
    // inside each 256-byte tile; the byte pairs stay words).  Blazing Tornado's 8 x 8 tiles are 64 raster bytes already.
    wire [25:0] g2_base = 26'h100000 + 26'(cfg_gfxsize) + 26'h220000;
    wire        in_g2   = (cfg_board == 8'd19) && (dl_addr >= g2_base) && (dl_addr < g2_base + 26'h200000);
    wire [25:0] a_perm  = in_g2 ? {dl_addr[25:8], dl_addr[7], dl_addr[5:3], dl_addr[6], dl_addr[2:0]} : dl_addr;

    assign ee_wr   = dl_wr && dl_addr >= 26'h000100 && dl_addr < 26'h000180;
    assign ee_addr = dl_addr[6:0];
    assign ee_data = dl_data;

    assign o_wr   = dl_wr;
    assign o_addr = a_perm;
    assign o_data = perm;
endmodule
`default_nettype wire
