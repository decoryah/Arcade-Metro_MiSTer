derive_pll_clocks
derive_clock_uncertainty

# ==============================================================================
# SDRAM. The chip is clocked by the PLL's second 96 MHz output, shifted about half a period (pll/pll_0002.v, JTFRAME's phase for MiSTer
# SDRAM); like the owner's other cores the pin's clock is modelled as the machine clock inverted, and the read data -- launched by the chip's
# edge, captured by metro_sdram's input register a few edges after the READ command -- gets a two-cycle path. The register assignments in
# sys/sys.tcl put the SDRAM pins' registers in the IO cells. (Same constraint as taitol-mister / mcatadv-mister.)
# ==============================================================================
set sdram_clk_src [get_pins -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sdram_clk_src] == 0 } {
    set sdram_clk_src [get_pins {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
create_generated_clock -name SDRAM_CLK -source $sdram_clk_src -divide_by 1 -phase 180 [get_ports {SDRAM_CLK}]

set sys_clk [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
if { [get_collection_size $sys_clk] == 0 } {
    set sys_clk [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
}
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -setup -end 2
set_multicycle_path -from [get_clocks {SDRAM_CLK}] -to $sys_clk -hold  -end 2

# ==============================================================================
# fx68k steps on its phase enables, four machine clocks apart (96 MHz / 8 = 12 MHz, metro_cen.sv): its internal paths have that long.
# Only paths inside the CPU are relaxed; the paths between it and the bus logic, the RAMs and DTACK stay single-cycle.
# (Same idea as Arcade-HyperDuel_MiSTer's Arcade-Hyprduel.sdc, which uses the same enable pattern at 80 MHz.)
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_main|*u_cpu|*}] -to [get_registers {emu|u_main|*u_cpu|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_main|*u_cpu|*}] -to [get_registers {emu|u_main|*u_cpu|*}]

# ==============================================================================
# The sound board's blocks step on clock enables, so their internal paths have several clocks (same idea as Arcade-HyperDuel_MiSTer's .sdc):
#   uPD78C10 engine: steps on ce = every 4th clock;  jt6295: cen every 80 clocks;  IKAOPLL and jt51 (YM2151): enable every ~27 clocks (cen_p1 every ~54).
# ==============================================================================
set_multicycle_path -setup -end 4 -from [get_registers {emu|u_snd|u_cpu|*}] -to [get_registers {emu|u_snd|u_cpu|*}]
set_multicycle_path -hold  -end 3 -from [get_registers {emu|u_snd|u_cpu|*}] -to [get_registers {emu|u_snd|u_cpu|*}]
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_snd|u_oki|*}] -to [get_registers {emu|u_snd|u_oki|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_snd|u_oki|*}] -to [get_registers {emu|u_snd|u_oki|*}]
set_multicycle_path -setup -end 2 -from [get_registers {emu|u_snd|u_opll|*}] -to [get_registers {emu|u_snd|u_opll|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_snd|u_opll|*}] -to [get_registers {emu|u_snd|u_opll|*}]
set_multicycle_path -setup -end 4 -from [get_registers {emu|u_snd|u_ym2151|*}] -to [get_registers {emu|u_snd|u_ym2151|*}]
set_multicycle_path -hold  -end 3 -from [get_registers {emu|u_snd|u_ym2151|*}] -to [get_registers {emu|u_snd|u_ym2151|*}]

# ==============================================================================
# The framework's HQ2x scandoubler (sys/hq2x.sv): the blender's registers all advance on `clk_en` = ce_x4 of the scandoubler (video_mixer's `sd`), which is 4 clocks
# apart for this core's 16-clock pixels (never closer than 2 for any pixel clock >= 8 clocks), so a path from one blender register to another has two clocks. Only
# paths inside the blender: the blender's inputs come from registers on the same enable, but other enables (ce_out) are not covered.
# ==============================================================================
set_multicycle_path -setup -end 2 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]
set_multicycle_path -hold  -end 1 -from [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}] -to [get_registers {emu|arcade_video|video_mixer|sd|Hq2x|blender|*}]


# ==============================================================================
# Family F's sound board: the Z80 (modules/cpu-tv80) steps on cen_z80 = every 12th clock (8 MHz of 96), so its internal paths have 12 clocks.  Only paths inside the CPU
# core are relaxed; its bus (A, di, wait_n, the strobes) is logic on the single-cycle clock.  The YM2610 (jt10) runs on the PLL's 48 MHz output with its own enable every
# 6th clock: the paths inside it have 6 of those clocks.
# ==============================================================================
set_multicycle_path -setup -end 12 -from [get_registers {emu|u_sndf|u_z80|*}] -to [get_registers {emu|u_sndf|u_z80|*}]
set_multicycle_path -hold  -end 11 -from [get_registers {emu|u_sndf|u_z80|*}] -to [get_registers {emu|u_sndf|u_z80|*}]

# ==============================================================================
# The image header's configuration bytes (metro_loader cfg[*]: board id, the DIP / option switches the MRA sets) change only while an image is being loaded, with the core
# held in reset, and are static for the whole run: they are not timing paths (the board-dependent decodes they feed ride on the machine clock like any other logic).
# ==============================================================================
set_false_path -from [get_registers {emu|u_loader|cfg[*][*]}]

# ==============================================================================
# Family C's YMF278B (rtl/ymf278b.sv, metro_ymf.sv): the engine advances on a chip-clock enable (33.8688 MHz out of 96: 2 or 3 machine clocks apart), so the paths inside
# it have two clocks.  The wrapper's own registers (the enable generator, the bus strobes) are on the single-cycle clock.
# ==============================================================================
# (only in the builds that have the chip: metrod64; the 32 MB core and the family F core leave it out, NO_YMF)
if {[llength [get_registers -nowarn {emu|u_ymf|u_ymf|*}]] > 0} {
    set_multicycle_path -setup -end 2 -from [get_registers {emu|u_ymf|u_ymf|*}] -to [get_registers {emu|u_ymf|u_ymf|*}]
    set_multicycle_path -hold  -end 1 -from [get_registers {emu|u_ymf|u_ymf|*}] -to [get_registers {emu|u_ymf|u_ymf|*}]
}
