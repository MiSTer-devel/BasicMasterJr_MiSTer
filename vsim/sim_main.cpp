// Verilator harness for the Basic Master Jr. MiSTer core.
//
// Modelled on the Apple-IIgs vsim harness, cut down to what this core needs:
// one 50 MHz clock, a PS/2 keyboard, a tape image over ioctl, and video.
//
//   make && ./obj_dir/Vemu                        # windowed
//   ./obj_dir/Vemu --headless --screenshot 120 --stop-at-frame 130
//   ./obj_dir/Vemu --tape game.cas --send-keys 200:LOAD\n --screenshot 900
//
// Run it from the vsim/ directory: rom*.mem are opened by $readmemh relative
// to the working directory.

#include <verilated.h>
#include "Vemu.h"

// Verilator 4.210+ splits public-flat internals into a root class; older
// releases keep them directly on Vemu. Support both generated layouts.
#if defined(__has_include)
# if __has_include("Vemu___024root.h")
#  include "Vemu___024root.h"
#  define VEMU_SPLIT_ROOT 1
# endif
#endif

#ifndef _MSC_VER
#include <SDL.h>
#include <SDL_opengl.h>
#endif

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>
#include <algorithm>

#include "sim_console.h"
#include "sim_bus.h"
#include "sim_video.h"
#include "sim_input.h"
#include "sim_clock.h"
#define STB_IMAGE_WRITE_IMPLEMENTATION
#include "sim/stb_image_write.h"

// Active picture produced by rtl/video.v
#define VGA_WIDTH  256
#define VGA_HEIGHT 192

// sim.v deliberately uses a 25 MHz timebase to reduce Verilator work while
// preserving the machine's real CPU/video/tape rates. `make SIM_HZ=50000000`
// builds the hardware's 50 MHz timebase (and its 32x tape turbo) instead.
#ifndef SIM_CLK_HZ
#define SIM_CLK_HZ 25000000u
#endif

// 40 us power-on reset. The core needs long enough for the $readmemh ROMs to
// be visible and for the 6800 to fetch its reset vector.
#define INITIAL_RESET_TICKS (SIM_CLK_HZ / 25000u)

vluint64_t main_time = 0;
double sc_time_stamp() { return main_time; }

DebugConsole console;
SimBus       bus(console);
SimInput     input(1, console);
SimVideo     video(VGA_WIDTH, VGA_HEIGHT, 0);
SimClock     clk_sys_clock(1);       // toggles every tick -> one full clk_sys per 2 ticks

Vemu* top = nullptr;

bool headless           = false;
bool trace_cpu          = false;
bool trace_io           = false;
bool trace_tape         = false;
bool trace_key          = false;
// Hold time for each injected key edge, in simulated clk_sys cycles (40 ns each).
// The BASIC keyboard scan only advances a few matrix columns per millisecond,
// so a key has to be held for tens of ms to be seen -- this is the same
// "keyboard eats inputs if typed fast" behaviour MAME notes for this machine.
unsigned int key_hold_cycles = SIM_CLK_HZ * 30 / 1000; // 30 ms
unsigned int tape_bit_period = SIM_CLK_HZ / 300;       // 300 baud
bool fast_tape = true;
bool tape_overlay = true;
bool us_layout = false;   // --keyboard us: OSD Keyboard layout US, and type as on a US keyboard
std::vector<int> rewind_frames;
int  stop_at_frame      = -1;
std::vector<int> screenshot_frames;
std::string tape_image;
int tape_at_frame = 0;            // --tape-at: mount the tape at this frame
std::string tape_list;
std::string record_output;
std::vector<uint8_t> recorded_tape;
std::string screenshot_prefix = "screenshot_frame";
// Set by --screenshot-name: exact output path, used instead of the
// prefix_NNNN.png naming. Only legal with a single --screenshot frame.
std::string screenshot_name;

// --dump-mem ADDR:LEN@FRAME -- snapshot the machine's 64K RAM to a .bin.
// Reads the array straight out of the verilated model (dpram.v marks it
// public_flat_rd), so it works headless and costs nothing when unused.
struct MemDump { int frame; unsigned addr; unsigned len; };
std::vector<MemDump> mem_dumps;

// --poke ADDR=BYTE[,BYTE...]@FRAME -- write straight into the machine's RAM at
// a given frame. Deterministic way to set up a test (filling a bitmap page,
// say) without depending on typing a BASIC line correctly.
struct MemPoke { int frame; unsigned addr; std::vector<uint8_t> bytes; };
std::vector<MemPoke> mem_pokes;

// --watch-pc ADDR[,ADDR...] -- count bus accesses to given addresses. Cheap way
// to tell which branch of a ROM routine is actually being taken.
std::vector<unsigned> watch_pcs;
std::vector<unsigned long long> watch_hits;

struct KeyInjection { int frame; std::string keys; };

// --pad N:BUTTONS -- hold gamepad buttons (joystick_0[11:0]) from frame N
// until the next --pad. BUTTONS is names joined with '+', or empty to let go.
struct PadEvent { int frame; unsigned buttons; };
std::vector<PadEvent> pad_events;
static const char* const pad_names[12] = {
	"RIGHT", "LEFT", "DOWN", "UP", "A", "B", "X", "Y", "L", "R", "SELECT", "START"
};
std::vector<KeyInjection> key_injections;

// ---------------------------------------------------------------------------
// Screenshots
// ---------------------------------------------------------------------------
static void save_screenshot(int frame_number, const char* name = nullptr)
{
	if (!output_ptr) { printf("screenshot: no framebuffer\n"); return; }

	char filename[512];
	if (name)                        snprintf(filename, sizeof(filename), "%s", name);
	else if (!screenshot_name.empty()) snprintf(filename, sizeof(filename), "%s", screenshot_name.c_str());
	else                             snprintf(filename, sizeof(filename), "%s_%04d.png", screenshot_prefix.c_str(), frame_number);

	const int w = video.output_width;
	const int h = video.output_height;
	std::vector<uint8_t> rgb((size_t)w * h * 3);

	for (int y = 0; y < h; y++) {
		for (int x = 0; x < w; x++) {
			// sim_video stores 0xFF000000 | B<<16 | G<<8 | R
			uint32_t p = output_ptr[y * w + x];
			size_t d = ((size_t)y * w + x) * 3;
			rgb[d + 0] = (p >> 0)  & 0xFF;
			rgb[d + 1] = (p >> 8)  & 0xFF;
			rgb[d + 2] = (p >> 16) & 0xFF;
		}
	}

	if (stbi_write_png(filename, w, h, 3, rgb.data(), w * 3))
		printf("Screenshot saved: %s\n", filename);
	else
		printf("Error: failed to write %s\n", filename);
	fflush(stdout);
}

// ---------------------------------------------------------------------------
// Keyboard injection
//
// The core's rtl/keyboard.v decodes raw PS/2 set-2 make codes, so we speak
// scancodes directly. Shifted characters get a shift make/break wrapped round
// the key. Only the keys rtl/keyboard.v actually maps are listed -- anything
// else is reported rather than silently dropped.
// ---------------------------------------------------------------------------
struct Ps2Map { unsigned int code; bool shift; bool ext; };

// --send-keys escapes \U \D \L \R: the arrow keys (E0 75 / 72 / 6B / 74).
enum { ARROW_UP = 0x11, ARROW_DOWN, ARROW_LEFT, ARROW_RIGHT };

// What a US keyboard presses for c, for --keyboard us. Letters and digits
// are as in ascii_to_ps2; the punctuation is on the US keys.
static Ps2Map ascii_to_ps2_us(char c)
{
	Ps2Map m = { 0xFF, false, false };
	switch (c) {
		case '`':  m.code = 0x0e; break;
		case '-':  m.code = 0x4e; break;
		case '=':  m.code = 0x55; break;
		case '[':  m.code = 0x54; break;
		case ']':  m.code = 0x5b; break;
		case '\\': m.code = 0x5d; break;
		case ';':  m.code = 0x4c; break;
		case '\'': m.code = 0x52; break;
		case ',':  m.code = 0x41; break;
		case '.':  m.code = 0x49; break;
		case '/':  m.code = 0x4a; break;
		case '!':  m.code = 0x16; m.shift = true; break;
		case '@':  m.code = 0x1e; m.shift = true; break;
		case '#':  m.code = 0x26; m.shift = true; break;
		case '$':  m.code = 0x25; m.shift = true; break;
		case '%':  m.code = 0x2e; m.shift = true; break;
		case '^':  m.code = 0x36; m.shift = true; break;
		case '&':  m.code = 0x3d; m.shift = true; break;
		case '*':  m.code = 0x3e; m.shift = true; break;
		case '(':  m.code = 0x46; m.shift = true; break;
		case ')':  m.code = 0x45; m.shift = true; break;
		case '_':  m.code = 0x4e; m.shift = true; break;
		case '+':  m.code = 0x55; m.shift = true; break;
		case ':':  m.code = 0x4c; m.shift = true; break;
		case '"':  m.code = 0x52; m.shift = true; break;
		case '<':  m.code = 0x41; m.shift = true; break;
		case '>':  m.code = 0x49; m.shift = true; break;
		case '?':  m.code = 0x4a; m.shift = true; break;
		default: break;
	}
	return m;
}

static Ps2Map ascii_to_ps2(char c)
{
	Ps2Map m = { 0xFF, false, false };

	switch (c) {
		case ARROW_UP:    m.code = 0x75; m.ext = true; return m;
		case ARROW_DOWN:  m.code = 0x72; m.ext = true; return m;
		case ARROW_LEFT:  m.code = 0x6b; m.ext = true; return m;
		case ARROW_RIGHT: m.code = 0x74; m.ext = true; return m;
	}
	if (us_layout) {
		Ps2Map u = ascii_to_ps2_us(c);
		if (u.code != 0xFF) return u;
	}

	if (c >= 'a' && c <= 'z') c = (char)(c - 'a' + 'A');

	static const struct { char ch; unsigned int sc; } letters[] = {
		{'A',0x1c},{'B',0x32},{'C',0x21},{'D',0x23},{'E',0x24},{'F',0x2b},{'G',0x34},
		{'H',0x33},{'I',0x43},{'J',0x3b},{'K',0x42},{'L',0x4b},{'M',0x3a},{'N',0x31},
		{'O',0x44},{'P',0x4d},{'Q',0x15},{'R',0x2d},{'S',0x1b},{'T',0x2c},{'U',0x3c},
		{'V',0x2a},{'W',0x1d},{'X',0x22},{'Y',0x35},{'Z',0x1a},
	};
	for (auto& l : letters) if (l.ch == c) { m.code = l.sc; return m; }

	static const unsigned int digits[] = { 0x45,0x16,0x1e,0x26,0x25,0x2e,0x36,0x3d,0x3e,0x46 };
	if (c >= '0' && c <= '9') { m.code = digits[c - '0']; return m; }

	// One PS/2 key per matrix position; shift is passed through to the machine
	// so it applies its own shifted meanings (- => =, ; => +, : => *).
	switch (c) {
		case ' ':  m.code = 0x29; break;
		case '\n': case '\r': m.code = 0x5a; break;
		case '\b': m.code = 0x66; break;
		case ',':  m.code = 0x41; break;
		case '.':  m.code = 0x49; break;
		case '/':  m.code = 0x4a; break;
		case ';':  m.code = 0x4c; break;
		case ':':  m.code = 0x52; break;
		case '-':  m.code = 0x4e; break;
		case '_':  m.code = 0x51; m.shift = true; break;   // the JIS keys, as in rtl/keyboard.v
		case ']':  m.code = 0x5d; break;
		case '@':  m.code = 0x54; break;
		case '[':  m.code = 0x5b; break;
		case '^':  m.code = 0x55; break;
		case '\\': m.code = 0x6a; break;   // yen
		// shifted second functions of the keys above
		case '+':  m.code = 0x4c; m.shift = true; break;
		case '*':  m.code = 0x52; m.shift = true; break;
		case '=':  m.code = 0x4e; m.shift = true; break;
		case '!':  m.code = 0x16; m.shift = true; break;
		case '"':  m.code = 0x1e; m.shift = true; break;
		case '#':  m.code = 0x26; m.shift = true; break;
		case '$':  m.code = 0x25; m.shift = true; break;
		case '%':  m.code = 0x2e; m.shift = true; break;
		case '&':  m.code = 0x36; m.shift = true; break;
		case '\'': m.code = 0x3d; m.shift = true; break;
		case '(':  m.code = 0x3e; m.shift = true; break;
		case ')':  m.code = 0x46; m.shift = true; break;
		case '<':  m.code = 0x41; m.shift = true; break;
		case '>':  m.code = 0x49; m.shift = true; break;
		case '?':  m.code = 0x4a; m.shift = true; break;
		default: break;
	}
	return m;
}

static void queue_key_string(const std::string& keys)
{
	const unsigned int SHIFT = 0x12;
	for (char c : keys) {
		Ps2Map m = ascii_to_ps2(c);
		if (m.code == 0xFF) {
			printf("send-keys: no mapping for '%c' (0x%02x) -- skipped\n", c, (unsigned char)c);
			continue;
		}
		if (m.shift) input.keyEvents.push(SimInput_PS2KeyEvent(SHIFT, true, false, SHIFT));
		input.keyEvents.push(SimInput_PS2KeyEvent(m.code, true,  m.ext, m.code));
		input.keyEvents.push(SimInput_PS2KeyEvent(m.code, false, m.ext, m.code));
		if (m.shift) input.keyEvents.push(SimInput_PS2KeyEvent(SHIFT, false, false, SHIFT));
	}
}

// Expand backslash escapes accepted by --send-keys
static std::string unescape(const std::string& in)
{
	std::string out;
	for (size_t i = 0; i < in.size(); i++) {
		if (in[i] != '\\' || i + 1 >= in.size()) { out += in[i]; continue; }
		char n = in[++i];
		switch (n) {
			case 'n': out += '\n'; break;
			case 'r': out += '\r'; break;
			case 't': out += '\t'; break;
			case 'b': out += '\b'; break;
			case '\\': out += '\\'; break;
			case 'U': out += (char)ARROW_UP; break;
			case 'D': out += (char)ARROW_DOWN; break;
			case 'L': out += (char)ARROW_LEFT; break;
			case 'R': out += (char)ARROW_RIGHT; break;
			case 'x': {
				if (i + 2 < in.size()) {
					out += (char)strtol(in.substr(i + 1, 2).c_str(), nullptr, 16);
					i += 2;
				}
				break;
			}
			default: out += n; break;
		}
	}
	return out;
}

#ifdef VEMU_SPLIT_ROOT
# define BMJR_MAIN_RAM top->rootp->emu__DOT__core__DOT__ram__DOT__dpram__DOT__mem
#else
# define BMJR_MAIN_RAM top->emu__DOT__core__DOT__ram__DOT__dpram__DOT__mem
#endif

static void save_mem_dump(const MemDump& d)
{
	char filename[256];
	snprintf(filename, sizeof(filename), "memdump_%04X_%04X_f%04d.bin",
	         d.addr, d.addr + d.len - 1, d.frame);
	FILE* f = fopen(filename, "wb");
	if (!f) { printf("dump-mem: cannot write %s\n", filename); return; }
	for (unsigned a = d.addr; a < d.addr + d.len && a < 0x10000; a++)
		fputc(BMJR_MAIN_RAM[a], f);
	fclose(f);
	printf("Memory dump saved: %s\n", filename);
	fflush(stdout);
}

static void apply_poke(const MemPoke& q)
{
	for (size_t i = 0; i < q.bytes.size(); i++) {
		unsigned a = q.addr + (unsigned)i;
		if (a < 0x10000)
			BMJR_MAIN_RAM[a] = q.bytes[i];
	}
	printf("Poked %zu byte(s) at $%04X\n", q.bytes.size(), q.addr);
	fflush(stdout);
}

static void process_key_injections(int frame)
{
	for (auto it = key_injections.begin(); it != key_injections.end(); ) {
		if (it->frame == frame) {
			printf("Injecting keys at frame %d: \"%s\"\n", frame, it->keys.c_str());
			queue_key_string(it->keys);
			it = key_injections.erase(it);
		} else ++it;
	}
}

// ---------------------------------------------------------------------------
// Simulation step
// ---------------------------------------------------------------------------
static uint8_t prev_ce_pix = 0;
static uint64_t reset_ticks = 0;

// Simple $EE80/$EEC0-level I/O trace, decoded the same way core.v does.
static void io_trace()
{
	// io_out in core.v is registered off clk_sys, so it is still the previous
	// access's value on the cycle the address changes. Wait for the bus to be
	// stable a few cycles before believing what is on it -- printing straight
	// away just shows the $FF idle default and looks like a decode failure.
	static uint16_t last_addr = 0xFFFF;
	static uint8_t  last_rw   = 0xFF;
	static int      stable    = -1;
	uint16_t a = top->dbg_cpu_addr;
	uint8_t  rw = top->dbg_cpu_rw;

	if (a != last_addr || rw != last_rw) { last_addr = a; last_rw = rw; stable = 0; return; }
	if (stable < 0 || ++stable != 8) return;

	if (a >= 0xE800 && a <= 0xEFFF) {
		printf("[io ] %10llu %s $%04X %s $%02X\n",
		       (unsigned long long)main_time,
		       rw ? "RD" : "WR", a,
		       rw ? "->" : "<-",
		       rw ? top->dbg_cpu_din : top->dbg_cpu_dout);
	}
}

static void key_trace()
{
	static uint16_t last_ps2 = 0xFFFF;
	static uint8_t  last_key = 0xFF;
	static uint8_t  last_mod = 0xFF;
	if (top->ps2_key != last_ps2) {
		last_ps2 = top->ps2_key;
		printf("[key] ps2_key=%03X code=%02X pressed=%d toggle=%d frame=%d\n",
		       top->ps2_key, top->ps2_key & 0xFF, (top->ps2_key >> 9) & 1,
		       (top->ps2_key >> 10) & 1, video.count_frame);
	}
	static uint8_t last_row0 = 0xFF, last_status = 0xFF;
	if (top->dbg_kb_key != last_key || top->dbg_kb_mod != last_mod
	    || top->dbg_kb_row0 != last_row0 || top->dbg_kb_status != last_status) {
		last_key = top->dbg_kb_key;
		last_mod = top->dbg_kb_mod;
		last_row0 = top->dbg_kb_row0;
		last_status = top->dbg_kb_status;
		printf("[key] matrix col=%X key=%X mod=%X row0=%X status=%d\n",
		       top->dbg_kb_col & 0xF, top->dbg_kb_key, top->dbg_kb_mod,
		       top->dbg_kb_row0, top->dbg_kb_status);
	}
}

static void tape_trace()
{
	// One line per byte actually shifted out: sample the shifter as the player
	// moves on to the next address, which is when the byte is fully sent.
	static unsigned last_addr = 0xFFFFFFFFu;
	if ((unsigned)top->dbg_tape_addr != last_addr) {
		static uint64_t last_t = 0;
		if (last_addr != 0xFFFFFFFFu)
			printf("[tape] byte[%u] = $%02X  %.3f ms since previous\n",
			       last_addr, top->dbg_tape_byte,
			       (main_time - last_t) / (SIM_CLK_HZ / 1000.0));
		last_t = main_time;
		last_addr = top->dbg_tape_addr;
	}
	// Duration of each level on the serial line, so a malformed frame is
	// obvious without having to reason about the state machine.
	static uint8_t  last_serial = 2;
	static uint64_t serial_since = 0;
	static int      edge_count = 0;
	if (top->dbg_tape_bit != last_serial) {
		if (last_serial < 2 && edge_count++ < 30)
			printf("[tape] line %d for %.3f ms\n", last_serial,
			       (main_time - serial_since) / (SIM_CLK_HZ / 1000.0));
		last_serial = top->dbg_tape_bit;
		serial_since = main_time;
	}
	static uint8_t last_state = 0xFF;
	static uint8_t last_motor = 0xFF;
	static uint8_t last_turbo = 0xFF;
	if (top->dbg_tape_state != last_state || top->dbg_tape_motor != last_motor ||
	    top->dbg_tape_turbo != last_turbo) {
		last_state = top->dbg_tape_state;
		last_motor = top->dbg_tape_motor;
		last_turbo = top->dbg_tape_turbo;
		printf("[tape] motor=%d turbo=%d state=%d addr=%u bit=%d frame=%d\n",
		       top->dbg_tape_motor, top->dbg_tape_turbo, top->dbg_tape_state,
		       (unsigned)top->dbg_tape_addr, top->dbg_tape_bit, video.count_frame);
	}
}

static int verilate()
{
	if (Verilated::gotFinish()) {
		top->final();
		delete top;
		exit(0);
	}

	// Power-on reset only. Deliberately NOT extended across an ioctl download:
	// sim.v feeds `reset` to the SDRAM controller's `init`, and holding that
	// high through a transfer throws the whole image away (which is exactly the
	// bug the real BasicMasterJr.sv had). A tape download resets only the
	// recorder in sim.v, as on the hardware: the machine keeps running.
	if (main_time < INITIAL_RESET_TICKS) {
		top->reset = 1;
		reset_ticks = main_time;
	} else if (top->reset && main_time > reset_ticks + INITIAL_RESET_TICKS) {
		top->reset = 0;
	}

	clk_sys_clock.Tick();
	top->clk_sys = clk_sys_clock.clk;

	if (clk_sys_clock.clk != clk_sys_clock.old) {
		if (clk_sys_clock.clk) {
			input.BeforeEval();
			bus.BeforeEval();
		}
		top->eval();
		if (clk_sys_clock.clk) bus.AfterEval();
	} else {
		top->eval();
	}

	if (clk_sys_clock.IsRising()) {
		// One pixel is produced on each clk_vid edge where ce_pix was high
		// (see the else-branch of the always block in rtl/video.v), so the
		// 1->0 transition of CE_PIXEL marks a fresh, settled pixel.
		uint8_t ce = top->CE_PIXEL;
		if (prev_ce_pix && !ce) {
			uint32_t colour = 0xFF000000u | ((uint32_t)top->VGA_B << 16)
			                              | ((uint32_t)top->VGA_G << 8)
			                              | ((uint32_t)top->VGA_R);
			video.Clock(top->VGA_HB, top->VGA_VB, top->VGA_HS, top->VGA_VS, colour);
		}
		prev_ce_pix = ce;

		if (trace_cpu && top->dbg_cpu_ce) {
			printf("[cpu] A=%04X D=%02X %s vma=%d bank=%d\n",
			       top->dbg_cpu_addr,
			       top->dbg_cpu_rw ? top->dbg_cpu_din : top->dbg_cpu_dout,
			       top->dbg_cpu_rw ? "R" : "W",
			       top->dbg_cpu_vma, top->dbg_bank);
		}
		// Sanity: report the measured CPU clock once, a second in.
		static uint64_t cpu_edges = 0;
		if (top->dbg_cpu_ce) cpu_edges++;
		if (main_time == SIM_CLK_HZ)
			printf("[clk] CPU clock measured: %llu Hz over 1.000 s\n",
			       (unsigned long long)cpu_edges);

		if (!watch_pcs.empty()) {
			static uint16_t prev = 0xFFFF;
			uint16_t a = top->dbg_cpu_addr;
			if (a != prev) {
				prev = a;
				for (size_t i = 0; i < watch_pcs.size(); i++)
					if (watch_pcs[i] == a) watch_hits[i]++;
			}
		}

		{
			static uint8_t last_sm = 0xAA;
			if (top->dbg_screen_mode != last_sm) {
				last_sm = top->dbg_screen_mode;
				printf("[vid] screen_mode = $%02X at frame %d\n", last_sm, video.count_frame);
			}
		}

		if (trace_io)   io_trace();
		if (trace_tape) tape_trace();
		if (trace_key)  key_trace();

		if (top->dbg_record_wr) {
			recorded_tape.push_back(top->dbg_record_data);
			if (trace_tape) printf("[record] byte[%u] = $%02X\n",
			       (unsigned)top->dbg_record_addr, top->dbg_record_data);
		}

		main_time++;
	}
	return 1;
}

static void RunBatch(int steps) { for (int i = 0; i < steps; i++) verilate(); }

// Actions that are gated on a frame number, shared by both run loops.
// Returns true when the caller should stop.
static void save_recorded_tape()
{
	if (record_output.empty()) return;
	FILE* f = fopen(record_output.c_str(), "wb");
	if (!f) {
		fprintf(stderr, "Cannot write recorded tape: %s\n", record_output.c_str());
		return;
	}
	if (!recorded_tape.empty())
		fwrite(recorded_tape.data(), 1, recorded_tape.size(), f);
	fclose(f);
	printf("Recorded tape saved: %s (%zu bytes)\n",
	       record_output.c_str(), recorded_tape.size());
}

static void queue_tape()
{
	// Like Main (menu.cpp), put the extension's position in the OSD row's
	// list ("FS1,BMTBINSAV") in bits 7:6 of the index: .bin arrives as $41.
	std::string ext = tape_image.substr(tape_image.find_last_of('.') + 1);
	for (auto& c : ext) c = toupper(c);
	int ext_idx = ext == "BIN" ? 1 : ext == "SAV" ? 2 : 0;
	printf("Loading tape image: %s (ioctl_index $%02X)\n", tape_image.c_str(), (ext_idx << 6) | 1);
	bus.QueueDownload(tape_image, (ext_idx << 6) | 1, 1);
}

static bool frame_actions(int frame)
{
	if (tape_at_frame && frame == tape_at_frame) queue_tape();
	if (!key_injections.empty()) process_key_injections(frame);
	for (const PadEvent& e : pad_events)
		if (e.frame == frame) {
			top->joy = e.buttons;
			if (trace_key) printf("[pad] buttons=%03X frame=%d\n", e.buttons, frame);
		}
	// OSD Rewind tape: hold the button for one frame.
	top->tape_rewind_btn = std::find(rewind_frames.begin(), rewind_frames.end(), frame) != rewind_frames.end();

	for (auto it = mem_pokes.begin(); it != mem_pokes.end(); ) {
		if (it->frame == frame) { apply_poke(*it); it = mem_pokes.erase(it); }
		else ++it;
	}

	for (auto it = mem_dumps.begin(); it != mem_dumps.end(); ) {
		if (it->frame == frame) { save_mem_dump(*it); it = mem_dumps.erase(it); }
		else ++it;
	}

	auto it = std::find(screenshot_frames.begin(), screenshot_frames.end(), frame);
	if (it != screenshot_frames.end()) {
		save_screenshot(frame);
		screenshot_frames.erase(it);
	}

	if (stop_at_frame >= 0 && frame >= stop_at_frame) {
		printf("Reached stop frame %d, exiting\n", frame);
		save_recorded_tape();
		for (size_t i = 0; i < watch_pcs.size(); i++)
			printf("[watch] $%04X hit %llu times\n", watch_pcs[i],
			       (unsigned long long)watch_hits[i]);
		return true;
	}
	return false;
}

// ---------------------------------------------------------------------------
static void usage(const char* argv0)
{
	printf(
	"Basic Master Jr. core simulator\n"
	"\n"
	"Usage: %s [options]\n"
	"\n"
	"  --headless                 run without a window (still renders for screenshots)\n"
	"  --tape <file>              load a tape image over ioctl (index 1)\n"
	"  --tape-at N                mount the --tape image at frame N instead of at start\n"
	"  --tape-list <file>         load a tape list (boot1.rom) over ioctl (index $40)\n"
	"  --record-out <file>        save bytes produced through $EE80 tape output\n"
	"  --screenshot N[,N,...]     write screenshot_frame_NNNN.png at these frames\n"
	"  --screenshot-name <path>   override the output path for a single screenshot\n"
	"  --stop-at-frame N          exit once frame N has been reached\n"
	"  --dump-mem ADDR:LEN@FRAME  snapshot RAM to memdump_*.bin (hex addr and len)\n"
	"  --poke ADDR=BYTES@FRAME    write RAM directly; BYTES is hex, FFx256 repeats\n"
	"  --send-keys N:string       type `string` at frame N (\\n = Return, \\xNN = raw,\n"
	"                             \\U \\D \\L \\R = arrow keys)\n"
	"                             repeatable\n"
	"  --keyboard jis|us          OSD Keyboard layout (default jis); us also types\n"
	"                             --send-keys as on a US keyboard\n"
	"  --pad N:BUTTONS            hold gamepad buttons from frame N, e.g. 300:A+UP;\n"
	"                             300: lets go. Buttons: RIGHT LEFT DOWN UP A B X Y\n"
	"                             L R SELECT START. Repeatable\n"
	"  --trace-cpu                print every CPU bus cycle (very verbose)\n"
	"  --trace-io                 print accesses to $E800-$EFFF\n"
	"  --trace-tape               print cassette state machine transitions\n"
	"  --trace-key                print PS/2 events and the key matrix\n"
	"  --key-hold MS              how long to hold each injected key (default 30 ms)\n"
	"  --tape-baud N              tape bit rate (default 300)\n"
	"  --tape-bit-period N        tape bit period in clk_sys ticks (overrides --tape-baud)\n"
	"  --fast-tape on|off         OSD Tape speed: turbo while a tape loads (default on;\n"
	"                             16x at the default 25 MHz build, 32x with SIM_HZ=50000000)\n"
	"  --tape-overlay on|off      OSD Tape overlay: status bar while the tape plays (default on)\n"
	"  --rewind-at N[,N,...]      press OSD Rewind tape at these frames\n"
	"  -h, --help                 this text\n"
	"\n"
	"Run from the vsim/ directory: the ROM .mem files are opened relative to cwd.\n",
	argv0);
}

int main(int argc, char** argv, char** env)
{
	Verilated::commandArgs(argc, argv);


	for (int i = 1; i < argc; i++) {
		std::string a = argv[i];
		auto next = [&](const char* what) -> std::string {
			if (i + 1 >= argc) { printf("%s needs an argument\n", what); exit(1); }
			return argv[++i];
		};
		if      (a == "-h" || a == "--help") { usage(argv[0]); return 0; }
		else if (a == "--headless")          headless = true;
		else if (a == "--trace-cpu")         trace_cpu = true;
		else if (a == "--trace-io")          trace_io = true;
		else if (a == "--trace-tape")        trace_tape = true;
		else if (a == "--trace-key")         trace_key = true;
		else if (a == "--key-hold")          key_hold_cycles = (unsigned)(atof(next("--key-hold").c_str()) * (SIM_CLK_HZ / 1000.0));
		else if (a == "--tape-baud")         tape_bit_period = (unsigned)(SIM_CLK_HZ / atof(next("--tape-baud").c_str()));
		else if (a == "--tape-bit-period")   tape_bit_period = (unsigned)atoi(next("--tape-bit-period").c_str());
		else if (a == "--fast-tape") {
			std::string value = next("--fast-tape");
			if      (value == "on")  fast_tape = true;
			else if (value == "off") fast_tape = false;
			else { printf("--fast-tape wants on or off\n"); return 1; }
		}
		else if (a == "--tape-overlay") {
			std::string value = next("--tape-overlay");
			if      (value == "on")  tape_overlay = true;
			else if (value == "off") tape_overlay = false;
			else { printf("--tape-overlay wants on or off\n"); return 1; }
		}
		else if (a == "--rewind-at") {
			std::string list = next("--rewind-at");
			for (size_t pos = 0; pos <= list.size();) {
				size_t comma = list.find(',', pos);
				std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
				if (!tok.empty()) rewind_frames.push_back(atoi(tok.c_str()));
				if (comma == std::string::npos) break;
				pos = comma + 1;
			}
		}
		else if (a == "--tape")              tape_image = next("--tape");
		else if (a == "--tape-at")           tape_at_frame = atoi(next("--tape-at").c_str());
		else if (a == "--tape-list")         tape_list = next("--tape-list");
		else if (a == "--record-out")         record_output = next("--record-out");
		else if (a == "--screenshot-name")   screenshot_name = next("--screenshot-name");
		else if (a == "--stop-at-frame")     stop_at_frame = atoi(next("--stop-at-frame").c_str());
		else if (a == "--screenshot" || a == "-screenshot") {
			std::string list = next("--screenshot");
			size_t pos = 0;
			while (pos <= list.size()) {
				size_t comma = list.find(',', pos);
				std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
				if (!tok.empty()) screenshot_frames.push_back(atoi(tok.c_str()));
				if (comma == std::string::npos) break;
				pos = comma + 1;
			}
		}
		else if (a == "--dump-mem") {
			std::string spec = next("--dump-mem");
			unsigned addr = 0, len = 0; int frame = 0;
			if (sscanf(spec.c_str(), "%x:%x@%d", &addr, &len, &frame) != 3 &&
			    sscanf(spec.c_str(), "%x:%u@%d", &addr, &len, &frame) != 3) {
				printf("--dump-mem wants ADDR:LEN@FRAME (hex addr/len), e.g. 1000:100@900\n");
				return 1;
			}
			mem_dumps.push_back({ frame, addr, len });
		}
		else if (a == "--keyboard") {
			std::string value = next("--keyboard");
			if      (value == "jis") us_layout = false;
			else if (value == "us")  us_layout = true;
			else { printf("--keyboard wants jis or us\n"); return 1; }
		}
		else if (a == "--pad") {
			std::string spec = next("--pad");
			size_t colon = spec.find(':');
			if (colon == std::string::npos) { printf("--pad wants N:BUTTONS, e.g. 300:A+UP\n"); return 1; }
			PadEvent e = { atoi(spec.substr(0, colon).c_str()), 0 };
			std::string list = spec.substr(colon + 1);
			for (size_t pos = 0; pos < list.size();) {
				size_t plus = list.find('+', pos);
				std::string tok = list.substr(pos, plus == std::string::npos ? std::string::npos : plus - pos);
				int b = 0;
				while (b < 12 && tok != pad_names[b]) b++;
				if (b == 12) { printf("--pad: unknown button '%s'\n", tok.c_str()); return 1; }
				e.buttons |= 1u << b;
				if (plus == std::string::npos) break;
				pos = plus + 1;
			}
			pad_events.push_back(e);
		}
		else if (a == "--poke") {
			std::string spec = next("--poke");
			size_t eq = spec.find('='), at = spec.rfind('@');
			if (eq == std::string::npos || at == std::string::npos || at < eq) {
				printf("--poke wants ADDR=BYTE[,BYTE...]@FRAME, e.g. 2100=FF,FF@600\n");
				return 1;
			}
			MemPoke q;
			q.addr  = strtoul(spec.substr(0, eq).c_str(), nullptr, 16);
			q.frame = atoi(spec.substr(at + 1).c_str());
			std::string list = spec.substr(eq + 1, at - eq - 1);
			size_t pos = 0;
			while (pos <= list.size()) {
				size_t comma = list.find(',', pos);
				std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
				if (!tok.empty()) {
					// "FFx100" repeats a byte, so a page fill stays one argument
					size_t x = tok.find('x');
					uint8_t v = (uint8_t)strtoul(tok.substr(0, x).c_str(), nullptr, 16);
					unsigned rep = (x == std::string::npos) ? 1 : strtoul(tok.substr(x + 1).c_str(), nullptr, 10);
					for (unsigned r = 0; r < rep; r++) q.bytes.push_back(v);
				}
				if (comma == std::string::npos) break;
				pos = comma + 1;
			}
			mem_pokes.push_back(q);
		}
		else if (a == "--watch-pc") {
			std::string list = next("--watch-pc");
			size_t pos = 0;
			while (pos <= list.size()) {
				size_t comma = list.find(',', pos);
				std::string tok = list.substr(pos, comma == std::string::npos ? std::string::npos : comma - pos);
				if (!tok.empty()) { watch_pcs.push_back(strtoul(tok.c_str(), nullptr, 16)); watch_hits.push_back(0); }
				if (comma == std::string::npos) break;
				pos = comma + 1;
			}
		}
		else if (a == "--send-keys") {
			std::string spec = next("--send-keys");
			size_t colon = spec.find(':');
			if (colon == std::string::npos) { printf("--send-keys wants FRAME:string\n"); return 1; }
			key_injections.push_back({ atoi(spec.substr(0, colon).c_str()),
			                           unescape(spec.substr(colon + 1)) });
		}
		else { printf("Unknown option: %s (try --help)\n", a.c_str()); return 1; }
	}

	if (!screenshot_name.empty() && screenshot_frames.size() != 1) {
		printf("--screenshot-name needs exactly one --screenshot frame\n");
		return 1;
	}

	top = new Vemu();

	bus.ioctl_addr     = &top->ioctl_addr;
	bus.ioctl_index    = &top->ioctl_index;
	bus.ioctl_wait     = &top->ioctl_wait;
	bus.ioctl_download = &top->ioctl_download;
	bus.ioctl_wr       = &top->ioctl_wr;
	bus.ioctl_dout     = &top->ioctl_dout;
	input.ps2_key      = &top->ps2_key;
	input.keyEventWait = key_hold_cycles;
	top->tape_bit_period = tape_bit_period;
	top->fast_tape = fast_tape;
	top->tape_overlay = tape_overlay;
	top->tape_rewind_btn = 0;
	top->joy = 0;
	top->us_layout = us_layout;

	// Main loads boot1.rom at core start, before any tape is mounted.
	if (!tape_list.empty()) {
		printf("Loading tape list: %s (ioctl_index $40)\n", tape_list.c_str());
		bus.QueueDownload(tape_list, 0x40, 1);
	}

	if (!tape_image.empty() && tape_at_frame == 0) queue_tape();

	if (!headless) {
		input.Initialise();
		if (video.Initialise("Basic Master Jr.") == 1) return 1;
	} else if (!output_ptr) {
		// Headless still renders, so screenshots work. Allocate the buffer
		// SimVideo::Initialise would normally have made.
		output_width  = VGA_WIDTH;
		output_height = VGA_HEIGHT;
		output_ptr = (uint32_t*)calloc((size_t)output_width * output_height, 4);
		if (!output_ptr) { fprintf(stderr, "framebuffer alloc failed\n"); return 2; }
	}

	if (headless) {
		printf("Headless mode.\n");
		int last_frame = -1;
		while (true) {
			RunBatch(4096);
			if (video.count_frame != last_frame) {
				last_frame = video.count_frame;
				if (frame_actions(last_frame)) return 0;
			}
		}
	}

#ifndef _MSC_VER
	bool done = false;
	bool run_enable = true;
	int  last_frame = -1;

	while (!done) {
		SDL_Event event;
		while (SDL_PollEvent(&event)) {
			ImGui_ImplSDL2_ProcessEvent(&event);
			if (event.type == SDL_QUIT) done = true;
		}

		video.StartFrame();
		ImGui::NewFrame();

		input.Read();

		if (run_enable) RunBatch(200000);

		if (video.count_frame != last_frame) {
			last_frame = video.count_frame;
			if (frame_actions(last_frame)) done = true;
		}

		ImGui::Begin("Machine");
		ImGui::Text("Frame %d   %.1f fps", video.count_frame, video.stats_fps);
		ImGui::Text("CPU  A=%04X  D=%02X  %s  vma=%d",
		            top->dbg_cpu_addr,
		            top->dbg_cpu_rw ? top->dbg_cpu_din : top->dbg_cpu_dout,
		            top->dbg_cpu_rw ? "R" : "W", top->dbg_cpu_vma);
		ImGui::Text("bank=%d (b000:%s e000:%s f000:%s)",
		            top->dbg_bank,
		            (top->dbg_bank & 1) ? "RAM" : "ROM",
		            (top->dbg_bank & 2) ? "RAM" : "ROM",
		            (top->dbg_bank & 4) ? "RAM" : "ROM");
		ImGui::Text("tape motor=%d turbo=%d state=%d addr=%u/%u bit=%d",
		            top->dbg_tape_motor, top->dbg_tape_turbo, top->dbg_tape_state,
		            (unsigned)top->dbg_tape_addr, (unsigned)top->dbg_tape_size,
		            top->dbg_tape_bit);
		ImGui::Checkbox("Run", &run_enable);
		if (ImGui::Button("Reset")) { main_time = 0; top->reset = 1; }
		ImGui::SameLine();
		if (ImGui::Button("Screenshot")) save_screenshot(video.count_frame);
		ImGui::End();

		ImGui::Begin("Video");
		ImGui::Image(video.texture_id, ImVec2(VGA_WIDTH * 3, VGA_HEIGHT * 3));
		ImGui::End();

		console.Draw("Log", nullptr, ImVec2(500, 400));

		video.UpdateTexture();
	}

	video.CleanUp();
	input.CleanUp();
#endif
	save_recorded_tape();
	return 0;
}
