// Golden model of the Metro sound CPU: MAME 0.289's uPD78C10 code (gen_model.py) in the Dharma sound-CPU environment of metro.cpp
// (metro_upd7810_state: upd7810_map, rxd_r, sound_data_w, upd7810_portb_w, upd7810_rombank_w<3>).
//
//   model <audiocpu.bin (128 KB)> <events.txt> <max states> <trace out> [--notrace]
//
// events.txt: "<state> cmd <hex>" = the 68000 writes a sound command byte when the CPU has run <state> states (one state = 3 clocks of the 12 MHz
// crystal, MAME's unit: instruction times are the tables' cycle counts); NMI is pulsed and the byte is latched for the serial input, which shifts it out
// LSB first on every RXD read.  The trace has one line per instruction, the state BEFORE it executes:
//   T PC OP A V EA BC DE HL SP PSW IFF IRR   (T = states so far; hex except T)
// and, in between, the events the board sees:  "E <T> YM <reg|data> <byte>"  "E <T> OKI W <byte>"  "E <T> OKI R"  "E <T> BUSY 0"
#include "emu.h"
#include "upd7810.h"
#include <string>
#include <vector>

int g_illegal_count = 0;

static uint8_t rom[0x20000];
static uint8_t ram[0x800];
static uint8_t iram[0x100];
static int bank = 0;
static uint8_t porta = 0, portb = 0;
static uint8_t sound_data = 0;
static bool busy = false;
static bool g_ym2151 = false;                    // --ym2151: the daitorid_portb_w board (YM2151 on port B bit 6, 8 ROM banks, INTF2 events)
static uint8_t oki_status = 0x00;               // what an idle OKI answers; the RTL bench uses the same
static long long T = 0;
static FILE* tr = nullptr;
static bool trace_on = true;

static uint8_t prog_rd(uint32_t a)
{
	if (a < 0x4000) return rom[a];
	if (a < 0x8000) return rom[(bank & (g_ym2151 ? 7 : 3)) * 0x4000 + (a - 0x4000)];
	if (a >= 0x8000 && a < 0x8800) return ram[a - 0x8000];
	if (a >= 0xff00) return iram[a - 0xff00];
	return 0xff;
}
static void prog_wr(uint32_t a, uint8_t v)
{
	if (a >= 0x8000 && a < 0x8800) ram[a - 0x8000] = v;
	else if (a >= 0xff00) iram[a - 0xff00] = v;
}

static void portb_w(uint8_t data)
{
	if ((portb & 0x80) && !(data & 0x80)) {
		busy = false;
		if (tr) fprintf(tr, "E %lld BUSY 0\n", T);
		portb = data;
		return;
	}
	if (!g_ym2151 && (portb & 0x20) && !(data & 0x20)) {
		if (!(data & 0x04) && tr) fprintf(tr, "E %lld YM %s %02X\n", T, (data & 0x02) ? "data" : "reg", porta);
		portb = data;
		return;
	}
	if (g_ym2151 && (portb & 0x40) && !(data & 0x40)) {       // daitorid_portb_w: bit 6 clocks the YM2151
		if (!(data & 0x04) && tr) fprintf(tr, "E %lld YM %s %02X\n", T, (data & 0x02) ? "data" : "reg", porta);
		if (!(data & 0x08)) porta = (data & 0x02) ? 0x00 : 0xff;     // idle status on odd offsets, 0xff on the data port (the RTL bench uses the same)
		portb = data;
		return;
	}
	if ((portb & 0x04) && !(data & 0x04)) {
		if (!(data & 0x10) && tr) fprintf(tr, "E %lld OKI W %02X\n", T, porta);
	}
	if ((portb & 0x08) && !(data & 0x08)) {
		if (!(data & 0x10)) { porta = oki_status; if (tr) fprintf(tr, "E %lld OKI R\n", T); }
	}
	portb = data;
}

struct Event { long long t; uint8_t v; };
static std::vector<Event> irq2;                  // events.txt "<state> irq2 <0|1>": the INTF2 line (the YM2151's IRQ) goes to that logical level

int main(int argc, char** argv)
{
	if (argc < 5) { fprintf(stderr, "usage: model <audiocpu.bin> <events.txt> <max states> <trace out> [--notrace]\n"); return 2; }
	FILE* f = fopen(argv[1], "rb");
	if (!f) { fprintf(stderr, "cannot open %s\n", argv[1]); return 1; }
	size_t n = fread(rom, 1, sizeof rom, f); fclose(f);
	(void)n;
	std::vector<Event> ev;
	if (strcmp(argv[2], "-") != 0) {
		FILE* e = fopen(argv[2], "r");
		if (!e) { fprintf(stderr, "cannot open %s\n", argv[2]); return 1; }
		char kind[16]; long long t; unsigned v;
		while (fscanf(e, "%lld %15s %x", &t, kind, &v) == 3) { if (!strcmp(kind, "cmd")) ev.push_back({t, (uint8_t)v}); else if (!strcmp(kind, "irq2")) irq2.push_back({t, (uint8_t)v}); }
		fclose(e);
	}
	long long max_states = atoll(argv[3]);
	for (int i = 5; i < argc; i++) { if (!strcmp(argv[i], "--notrace")) trace_on = false; if (!strcmp(argv[i], "--ym2151")) g_ym2151 = true; }
	tr = fopen(argv[4], "w");
	if (!tr) { fprintf(stderr, "cannot write %s\n", argv[4]); return 1; }
	static char buf[1 << 20]; setvbuf(tr, buf, _IOFBF, sizeof buf);

	upd7810_device* cpu = new upd7810_device();
	cpu->configure_ops();
	cpu->m_program.rd = prog_rd;  cpu->m_program.wr = prog_wr;
	cpu->m_opcodes.rd = prog_rd;
	cpu->m_pa_in_cb.f = [] { return porta; };
	cpu->m_pa_out_cb.f = [](uint8_t d) { porta = d; };
	cpu->m_pb_out_cb.f = portb_w;
	cpu->m_pc_out_cb.f = [](uint8_t d) { bank = (d >> 4) & 7; };
	cpu->m_rxd_func.f = [] { int b = sound_data & 1; sound_data >>= 1; return b; };
	cpu->device_reset();

	size_t next_ev = 0, next_irq = 0;
	long long last_report = 0;
	while (T < max_states) {
		{   // commands due at this instruction boundary: the last byte is latched, one NMI (the RTL bench applies them the same way)
			bool any = false; uint8_t last = 0;
			while (next_ev < ev.size() && T >= ev[next_ev].t) { last = ev[next_ev].v; any = true; next_ev++; }
			if (any) {
				sound_data = last; busy = true;
				cpu->execute_set_input(upd7810_device::INPUT_LINE_NMI, 1);
				cpu->execute_set_input(upd7810_device::INPUT_LINE_NMI, 0);
				if (trace_on) fprintf(tr, "E %lld CMD %02X\n", T, last);
			}
			if (next_irq < irq2.size() && T >= irq2[next_irq].t) {       // one INTF2 level change per instruction boundary (the RTL bench applies one)
				cpu->execute_set_input(upd7810_device::UPD7810_INTF2, irq2[next_irq].v ? 1 : 0);
				if (trace_on) fprintf(tr, "E %lld IRQ2 %d\n", T, (int)irq2[next_irq].v);
				next_irq++;
			}
		}
		if (trace_on) {
			uint8_t op = prog_rd(cpu->m_pc.w.l);
			fprintf(tr, "%lld %04X %02X %02X %02X %04X %04X %04X %04X %04X %02X %d %04X\n", T, cpu->m_pc.w.l, op, cpu->m_va.b.l, cpu->m_va.b.h,
			        cpu->m_ea.w.l, cpu->m_bc.w.l, cpu->m_de.w.l, cpu->m_hl.w.l, cpu->m_sp.w.l, cpu->m_psw, cpu->m_iff, cpu->m_irr);
		}
		cpu->m_icount = 1;
		cpu->execute_run();
		T += 1 - cpu->m_icount;
		if (T - last_report >= 100000000LL) { last_report = T; fprintf(stderr, "  ... %lld states\n", T); }
	}
	fprintf(stderr, "regs: TMM=%02X ETMM=%02X MKL=%02X MKH=%02X SML=%02X SMH=%02X EOM=%02X ANM=%02X MA=%02X MB=%02X MC=%02X MCC=%02X MM=%02X TM0=%02X TM1=%02X ETM0=%04X ETM1=%04X IRR=%04X\n",
	        cpu->m_tmm, cpu->m_etmm, cpu->m_mkl, cpu->m_mkh, cpu->m_sml, cpu->m_smh, cpu->m_eom, cpu->m_anm, cpu->m_ma, cpu->m_mb, cpu->m_mc, cpu->m_mcc, cpu->m_mm,
	        cpu->m_tm.b.l, cpu->m_tm.b.h, cpu->m_etm.w.l, cpu->m_etm.w.h, cpu->m_irr);
	fprintf(stderr, "done: %lld states, %d illegal-opcode messages, busy=%d\n", T, g_illegal_count, (int)busy);
	fclose(tr);
	return 0;
}
