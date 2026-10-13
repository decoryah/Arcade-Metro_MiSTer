// Minimal stand-in for MAME's emu.h: just what upd7810_opcodes.cpp / upd7810_table.cpp / the extracted core need.
#pragma once
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <functional>
#include <new>

typedef uint32_t offs_t;
typedef uint8_t  u8;

union PAIR { struct { uint8_t l, h, h2, h3; } b; struct { uint16_t l, h; } w; uint32_t d; };

#define BIT(x, n) (((x) >> (n)) & 1)
#define ATTR_COLD

// byte-wide address space: the environment (model.cpp) installs the callbacks
struct Mem
{
	std::function<uint8_t(uint32_t)> rd;
	std::function<void(uint32_t, uint8_t)> wr;
	uint8_t read_byte(uint32_t a) const { return rd ? rd(a & 0xffff) : 0xff; }
	void write_byte(uint32_t a, uint8_t v) const { if (wr) wr(a & 0xffff, v); }
};

// MAME's internal-RAM view at 0xff00 (MOV MM,A selects/disables it)
struct RamView { bool on = true; void select(int) { on = true; } void disable() { on = false; } };

struct devcb_read8
{
	std::function<uint8_t()> f;
	bool isunset() const { return !f; }
	uint8_t operator()() const { return f ? f() : 0xff; }
	uint8_t operator()(int, uint8_t) const { return (*this)(); }
};
struct devcb_write8 { std::function<void(uint8_t)> f; void operator()(uint8_t d) const { if (f) f(d); } };
struct devcb_write_line { std::function<void(int)> f; void operator()(int s) const { if (f) f(s); } };
struct devcb_read_line { std::function<int()> f; int operator()() const { return f ? f() : 1; } };

extern int g_illegal_count;
#define logerror(...) do { g_illegal_count++; if (g_illegal_count <= 20) { fprintf(stderr, __VA_ARGS__); } } while (0)
#define debugger_instruction_hook(pc) do {} while (0)
#define debugger_wait_hook() do {} while (0)
#define fatalerror(...) do { fprintf(stderr, __VA_ARGS__); exit(1); } while (0)

enum { CLEAR_LINE = 0, ASSERT_LINE = 1 };
