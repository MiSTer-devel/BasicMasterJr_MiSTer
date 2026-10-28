// Cycle-accuracy harness for rtl/m6801.sv against the real 6800's timings.
//
// For every legal opcode: build a tiny program, run it, and count CPU clocks
// from the fetch of that opcode to the fetch of the next instruction. Compare
// with MAME's cycles_6800[] table (see extract_cycles.py).
//
//   ./obj_dir/Vcputb            report every mismatch
//   ./obj_dir/Vcputb --table    emit a Verilog pad table for m6800_pad.v
//   ./obj_dir/Vcputb --trace 01 dump the cycle-by-cycle trace of one opcode
//
// Why this exists: the monitor ROM times cassette bits with software delay
// loops, so instruction timing is not cosmetic -- if the core is fast, tape
// loading needs a fudged bit rate.

#include <verilated.h>
#include "Vcputb.h"

// Verilator 4.210+ splits public-flat internals into a root class; older
// releases keep them directly on Vcputb. Support both generated layouts.
#if defined(__has_include)
# if __has_include("Vcputb___024root.h")
#  include "Vcputb___024root.h"
#  define VCPUTB_SPLIT_ROOT 1
# endif
#endif
#include "cycles_6800.h"

#include <cstdio>
#include <cstring>
#include <cstdlib>
#include <string>
#include <vector>

// From the state_type enum at the top of m6801.sv, in declaration order.
#define ST_RESET  0
#define ST_FETCH  1
#define ST_ERROR  12

// Opcodes this harness cannot time in a straight line, with the reason.
// They are reported rather than silently skipped.
static const char* untimeable(int op)
{
	switch (op) {
		case 0x3E: return "WAI: waits for an interrupt";
		case 0x3F: return "SWI: measured separately (vectors away)";
		case 0x3B: return "RTI: needs a stacked frame";
		default:   return nullptr;
	}
}

static Vcputb* top = nullptr;
static bool pad_on = false;   // --pad runs the core through m6800_pad
static vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

static inline void poke(unsigned a, uint8_t v)
{
#ifdef VCPUTB_SPLIT_ROOT
	top->rootp->cputb__DOT__mem[a] = v;
#else
	top->cputb__DOT__mem[a] = v;
#endif
}

static void tick()
{
	top->clk = 0; top->eval();
	top->clk = 1; top->eval();
	main_time++;
}

// Program layout: opcode at $0200 followed by NOPs, then a jump back. NOP ($01)
// as an operand is harmless in every addressing mode -- direct/indexed land in
// page zero, extended lands at $0101, relative branches skip one byte.
static const uint16_t ORG = 0x0200;

static void load_program(int op)
{
	for (unsigned a = 0; a < 0x10000; a++) poke(a, 0x01);   // NOP everywhere
	poke(ORG, (uint8_t)op);
	poke(ORG + 0x10, 0x7E);                // JMP $0200, so the program loops
	poke(ORG + 0x11, ORG >> 8);
	poke(ORG + 0x12, ORG & 0xFF);
	poke(0xFFFE, ORG >> 8);                // reset vector
	poke(0xFFFF, ORG & 0xFF);
	poke(0xFFF8, 0x02); poke(0xFFF9, 0x00);   // IRQ vector
	poke(0xFFFA, 0x02); poke(0xFFFB, 0x00);   // SWI vector
	poke(0xFFFC, 0x02); poke(0xFFFD, 0x00);   // NMI vector
}

static void reset_cpu()
{
	top->cen = 1; top->irq = 0; top->nmi = 0;
	top->pad_enable = pad_on;
	top->rst = 1;
	for (int i = 0; i < 4; i++) tick();
	top->rst = 0;
}

// Measure the clocks from the fetch of the opcode at $0200 to the next fetch.
//
// Trigger on the fetch ADDRESS, not on dbg_opcode: op_code is registered a
// state later than the fetch it belongs to, so matching on it starts the count
// one instruction late and every long opcode measures as the following NOP.
// Returns -1 if the opcode never came round, -2 if the core hit error_state.
static int measure(int op, bool trace)
{
	load_program(op);
	reset_cpu();

	bool in_fetch = false, counting = false;
	int  count = 0;
	int  first = -1;
	// Two passes: the first sighting may start mid-stream, so take the second.
	int  seen = 0;

	for (long t = 0; t < 20000; t++) {
		int st = top->dbg_state;
		int oc = top->dbg_opcode; (void)oc;

		if (st == ST_ERROR) return -2;

		bool fetch_edge = (st == ST_FETCH) && !in_fetch;
		in_fetch = (st == ST_FETCH);

		if (trace)
			printf("  t=%4ld state=%2d op=$%02X addr=$%04X rw=%d vma=%d%s\n",
			       t, st, oc, top->address, top->rw, top->vma,
			       fetch_edge ? "  <- fetch" : "");

		if (fetch_edge) {
			if (counting) {
				if (++seen >= 1) { first = count; break; }
			}
			if (top->address == ORG && !counting) { counting = true; count = 0; }
		}
		if (counting) count++;
		tick();
	}
	return first;
}

int main(int argc, char** argv)
{
	Verilated::commandArgs(argc, argv);
	top = new Vcputb();

	bool emit_table = false;
	int  trace_op = -1;
	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		if (a == "--table") emit_table = true;
		else if (a == "--pad") pad_on = true;
		else if (a == "--trace" && i + 1 < argc) trace_op = (int)strtol(argv[++i], nullptr, 16);
	}

	if (trace_op >= 0) {
		printf("trace of opcode $%02X (expect %d cycles)\n", trace_op, cycles_6800[trace_op]);
		int m = measure(trace_op, true);
		printf("measured %d\n", m);
		return 0;
	}

	int pad[256];
	memset(pad, 0, sizeof(pad));

	int ok = 0, slow = 0, fast = 0, failed = 0, skipped = 0;
	std::vector<std::string> notes;

	for (int op = 0; op < 256; op++) {
		if (cycles_6800[op] < 0) { skipped++; continue; }
		const char* why = untimeable(op);
		if (why) { skipped++; notes.push_back(std::string("skip $") +
			 (char)("0123456789ABCDEF"[op >> 4]) + (char)("0123456789ABCDEF"[op & 15]) +
			 ": " + why); continue; }

		int want = cycles_6800[op];
		int got  = measure(op, false);

		if (got < 0) {
			printf("$%02X  want %2d  MEASURE FAILED (%s)\n", op, want,
			       got == -2 ? "error_state" : "no second fetch");
			failed++;
			continue;
		}
		if (got == want) { ok++; continue; }
		if (got < want) { fast++; pad[op] = want - got; }
		else            { slow++; }
		printf("$%02X  want %2d  got %2d  %s%d\n", op, want, got,
		       got < want ? "core is fast by " : "core is SLOW by ",
		       got < want ? want - got : got - want);
	}

	printf("\n%d exact, %d too fast, %d too slow, %d unmeasurable, %d skipped\n",
	       ok, fast, slow, failed, skipped);
	for (auto& n : notes) printf("  %s\n", n.c_str());

	if (emit_table) {
		FILE* f = fopen("m6800_pad_table.vh", "w");
		fprintf(f, "// GENERATED by vsim/cputest -- extra clocks per opcode needed to\n"
		           "// bring rtl/m6801.sv up to real 6800 timing. Regenerate with:\n"
		           "//   cd vsim/cputest && make && ./obj_dir/Vcputb --table\n");
		for (int op = 0; op < 256; op++)
			fprintf(f, "  pad_rom[8'h%02X] = 4'd%d;\n", op, pad[op] > 15 ? 15 : pad[op]);
		fclose(f);
		printf("wrote m6800_pad_table.vh\n");
	}

	int over = 0;
	for (int op = 0; op < 256; op++) if (pad[op] > 15) over++;
	if (over) printf("WARNING: %d opcodes need more than 15 pad cycles\n", over);

	top->final();
	return (slow || failed) ? 1 : 0;
}
