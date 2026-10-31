`timescale 1ns / 1ps
//============================================================================
//  Simulation top (Verilator) for the Basic Master Jr. core.
//
//  This stands in for BasicMasterJr.sv: same wiring, but hps_io and the Altera
//  PLL are replaced by things sim_main.cpp can drive.
//  Keep it in sync with BasicMasterJr.sv when the real top changes.
//
//  Deliberate differences from BasicMasterJr.sv, all noted inline:
//    * clk_vid is made with a phase accumulator instead of a PLL
//    * the 64 KiB tape RAM uses the behavioural dpram wrapper
//============================================================================

module emu (
	// 50 MHz system clock, toggled by sim_main.cpp
	input             clk_sys,
	input             reset,

	// PS/2 keyboard: [7:0] code, [8] extended, [9] pressed, [10] toggles per event
	input      [10:0] ps2_key,
	input      [11:0] joy,              // gamepad, as hps_io joystick_0[11:0]
	input             us_layout,        // OSD Keyboard layout: US

	// clk_sys ticks per tape bit; --tape-bit-period sweeps this from sim_main
	input      [31:0] tape_bit_period,
	input             fast_tape,        // OSD Tape speed: Nx
	input             tape_overlay,     // OSD Tape overlay: On
	input             tape_rewind_btn,  // OSD Rewind tape (level; rising edge rewinds)

	// HPS file transfer (tape images) -- driven by sim/sim_bus.cpp
	input             ioctl_download,
	input             ioctl_wr,
	input      [24:0] ioctl_addr,
	input       [7:0] ioctl_dout,
	input       [7:0] ioctl_index,
	output            ioctl_wait,

	// Video
	output      [7:0] VGA_R,
	output      [7:0] VGA_G,
	output      [7:0] VGA_B,
	output            VGA_HS,
	output            VGA_VS,
	output            VGA_HB,
	output            VGA_VB,
	output            CE_PIXEL,

	// Audio
	output     [15:0] AUDIO_L,
	output     [15:0] AUDIO_R,

	// --- debug taps for sim_main.cpp -----------------------------------
	// Hierarchical reads out of the core; no RTL changes required.
	output     [15:0] dbg_cpu_addr,
	output      [7:0] dbg_cpu_din,
	output      [7:0] dbg_cpu_dout,
	output            dbg_cpu_rw,
	output            dbg_cpu_vma,
	output            dbg_cpu_ce,      // 1 for one clk_sys tick per CPU cycle
	output      [2:0] dbg_bank,
	output            dbg_tape_start,
	output            dbg_tape_stop,
	output            dbg_tape_bit,
	output            dbg_tape_motor,
	output            dbg_tape_turbo,
	output      [2:0] dbg_tape_state,
	output     [24:0] dbg_tape_addr,
	output     [24:0] dbg_tape_size,
	output      [7:0] dbg_tape_byte,
	output            dbg_record_wr,
	output     [15:0] dbg_record_addr,
	output      [7:0] dbg_record_data,
	output     [16:0] dbg_record_size,
	output            dbg_record_dirty,
	output            dbg_record_overflow,
	output      [7:0] dbg_screen_mode,
	output      [7:0] dbg_kb_col,
	output      [3:0] dbg_kb_key,
	output      [3:0] dbg_kb_mod,
	output            dbg_kb_status,
	output      [3:0] dbg_kb_row0
);

//////////////////////////////  CLOCKS  //////////////////////////////////////
// The simulator uses a 25 MHz system timebase by default instead of the
// hardware's 50 MHz. This halves the number of Verilator evaluations per
// emulated second while leaving enough bandwidth for video.v's
// six-cycle-per-pixel renderer (17.4 MHz minimum at 59 Hz). CPU, video, tape
// and watchdog rates are scaled to preserve real-machine time.
//
// The one thing 25 MHz cannot do is the hardware's 32x tape turbo: a 24 MHz CPU
// enable needs the clock at least twice as fast (rtl/tape_speed.v), so the
// default build loads tapes at 16x. `make SIM_HZ=50000000` builds the
// hardware's timebase and 32x turbo (about half the speed).
//
// 25 / 10.638297 is not an integer, so instead of a divider we run a phase
// accumulator: clk_vid toggles when the accumulator wraps. Worst-case jitter
// is one clk_sys period (40 ns) against a 94 ns half period, which video.v
// (a free-running counter) does not care about, and it keeps the real ~59 Hz
// frame rate so screenshot frame numbers mean the same thing as on hardware.
// One accumulator carry = one clk_vid EDGE, so the increment carries twice per
// clk_vid cycle. Getting that factor of 2 wrong ran the whole video side (and
// therefore every --screenshot / --send-keys frame number) at half speed.
`ifndef SIM_CLK_HZ
`define SIM_CLK_HZ 25000000
`endif
localparam integer SIM_CLK_HZ = `SIM_CLK_HZ;
// round(2 * 10.638297e6 / SIM_CLK_HZ * 2^32): 3,655,291,016 at 25 MHz
// -> 10.6383 MHz, 59.02 Hz frames
localparam [63:0] VID_INC64 = (64'd21_276_594 * 64'd4294967296 + SIM_CLK_HZ / 2) / SIM_CLK_HZ;
localparam [31:0] VID_INC = VID_INC64[31:0];
localparam integer TURBO_SHIFT = SIM_CLK_HZ >= 48_000_000 ? 5 : 4;

reg [31:0] vid_acc = 32'd0;
reg        clk_vid = 1'b0;

always @(posedge clk_sys) begin
	{vid_acc[31:0]} <= vid_acc + VID_INC;
	if (vid_acc + VID_INC < vid_acc) clk_vid <= ~clk_vid;  // carry out => toggle
end

// CPU clock enable and default-on tape turbo, matching BasicMasterJr.sv.
wire tape_motor;
wire tape_end;
wire tape_turbo;
wire tape_active;
wire [31:0] cpu_increment;
wire [31:0] turbo_bit_period;

tape_speed #(.CLK_HZ(SIM_CLK_HZ), .SHIFT(TURBO_SHIFT)) tape_speed (
	.clk          (clk_sys),
	.enable       (fast_tape),
	.motor        (tape_motor),
	.tape_left    (~tape_end),
	.base_period  (tape_bit_period),
	.turbo        (tape_turbo),
	.active       (tape_active),
	.cpu_increment(cpu_increment),
	.bit_period   (turbo_bit_period)
);

reg [31:0] cpu_acc = 32'd0;
wire [32:0] cpu_sum = {1'b0, cpu_acc} + {1'b0, cpu_increment};
wire clk_cpu = cpu_sum[32];

always @(posedge clk_sys)
	cpu_acc <= cpu_sum[31:0];

assign dbg_cpu_ce = clk_cpu;

// As on the hardware top: a tape mount resets only the recorder, not the
// machine (see BasicMasterJr.sv).

//////////////////////////////  TAPE BUFFER  ///////////////////////////////////
// Main sends the file's position in the row's extension list (BMT, BIN, SAV)
// in ioctl_index[7:6] (menu.cpp), so a .bin arrives as $41: match the slot only.
wire tape_ioctl = ioctl_index[5:0] == 6'd1;
wire tape_reset = reset | (ioctl_download & tape_ioctl);
// Match the hardware top: HPS downloads into a dedicated 64 KiB dual-port
// block RAM, and the cassette reads its second port. There is no external
// SDRAM handshake in the tape path, so downloads can accept one byte per tick.
wire [24:0] tape_addr;
wire  [7:0] tape_buffer_data;
wire        tape_write;
wire        tape_out;
wire        recorder_wr;
wire [15:0] recorder_addr;
wire  [7:0] recorder_data;
wire [16:0] recorder_size;
wire        recorder_dirty;
wire        recorder_overflow;

cassette_recorder recorder (
	.clk_sys(clk_sys), .reset(tape_reset), .clear(1'b0), .saved(1'b0),
	.cpu_tick(clk_cpu), .motor(tape_motor), .write_strobe(tape_write),
	.buffer_wr(recorder_wr), .buffer_addr(recorder_addr),
	.buffer_data(recorder_data), .size(recorder_size),
	.dirty(recorder_dirty), .overflow(recorder_overflow)
);

wire [15:0] tape_write_addr = recorder_wr ? recorder_addr : ioctl_addr[15:0];
wire  [7:0] tape_write_data = recorder_wr ? recorder_data : ioctl_dout;

ram tape_buffer (
	.clk    (clk_sys),
	.addr   (tape_write_addr),
	.din    (tape_write_data),
	.dout   (),
	.wr     (recorder_wr | (ioctl_download & ioctl_wr & tape_ioctl)),
	.ce     (1'b1),
	.addr_b (tape_addr[15:0]),
	.dout_b (tape_buffer_data)
);

assign ioctl_wait = 1'b0;


//////////////////////////////  CORE  ////////////////////////////////////////
wire        hs, vs, hb, vb;
wire  [7:0] red, green, blue;
wire  [3:0] kb_key, kb_mod;
wire  [3:0] kb_col;
wire        key_pressed;
wire        ce_pix;
wire        tape_bit;
wire        tape_start;
wire        tape_stop;
wire        break_key;
wire  [4:0] dac_level;

// Tape image size + rewind on mount or Rewind tape, mirroring BasicMasterJr.sv.
reg [24:0] tape_size = 25'd0;
reg        tape_rewind;
always @(posedge clk_sys) begin
	reg old_download, old_rewind_btn;
	old_download <= ioctl_download;
	old_rewind_btn <= tape_rewind_btn;
	tape_rewind <= 1'b0;
	if (ioctl_download & ioctl_wr & tape_ioctl)
		tape_size <= ioctl_addr + 25'd1;
	if (recorder_wr)
		tape_size <= {8'd0, recorder_size};
	if (old_download & ~ioctl_download & tape_ioctl)
		tape_rewind <= 1'b1;
	if (tape_rewind_btn & ~old_rewind_btn)
		tape_rewind <= 1'b1;
end

cassette cassette (
	.clk_sys     (clk_sys),
	.bit_period  (turbo_bit_period),
	.reset       (reset),           // a tape mount rewinds; it must not also reset
	.tape_start  (tape_start),
	.tape_stop   (tape_stop),
	.tape_rewind (tape_rewind),
	.image_size  (tape_size),
	.sdram_addr  (tape_addr),
	.sdram_data  ({8'd0, tape_buffer_data}),
	.sdram_rd    (),
	.sdram_we    (),
	.sdram_wtbt  (),
	.sdram_ready (1'b1),
	.tape_bit    (tape_bit),
	.motor       (tape_motor),
	.tape_end    (tape_end),
	.status      ()
);

core #(.VIDEO_BORDER(0), .SYS_CLK_HZ(SIM_CLK_HZ)) core (
	.reset      (reset),
	.clk_sys    (clk_sys),
	.clk_cpu    (clk_cpu),
	.clk_vid    (clk_vid),
	.kb_col     (kb_col),
	.kb_key     (kb_key),
	.kb_mod     (kb_mod),
	.hs         (hs),
	.vs         (vs),
	.hb         (hb),
	.vb         (vb),
	.ce_pix     (ce_pix),
	.red        (red),
	.green      (green),
	.blue       (blue),
	.break_key  (break_key),
	.tape_bit   (tape_bit),
	.tape_start (tape_start),
	.tape_stop  (tape_stop),
	.tape_write (tape_write),
	.tape_out   (tape_out),
	.dac_level  (dac_level)
);

wire  [95:0] pad_map;   // from tape_hint

keyboard keyboard (
	.reset  (reset),
	.clk_sys(clk_sys),
	.ps2_key(ps2_key),
	.swap_alt_win(1'b0),   // OSD Swap Alt/Win keys; --send-keys can't type Win
	.us_layout(us_layout),
	.joy    (joy),
	.pad_map(pad_map),
	.kb_col (kb_col),
	.kb_key (kb_key),
	.kb_mod (kb_mod),
	.break_key(break_key),
	.status (key_pressed)
);

//////////////////////////////  TAPE OVERLAY  ////////////////////////////////
wire [400:0] tape_status_word;
wire        tape_status_req, tape_status_ack;
wire [23:0] overlay_rgb;

wire         tape_hint_show;
wire   [4:0] tape_hint_len;
wire         tape_hint_two;
wire [351:0] tape_hint_text;

// What to type next while the deck is stopped (load, then start).
tape_hint tape_hint(
	.clk(clk_sys),
	.wr(recorder_wr | (ioctl_download & ioctl_wr & tape_ioctl)),
	.rec(recorder_wr),
	.addr({9'd0, tape_write_addr}),
	.data(tape_write_data),
	.list_wr(ioctl_download & ioctl_wr & (ioctl_index == 8'h40)),
	.list_addr(ioctl_addr),
	.list_data(ioctl_dout),
	.position(tape_addr),
	.length(tape_size),
	.playing(tape_active),
	.ps2_key(ps2_key),
	.show(tape_hint_show),
	.len(tape_hint_len),
	.two(tape_hint_two),
	.text(tape_hint_text),
	.pad_map(pad_map)
);

tape_status tape_status (
	.clk     (clk_sys),
	.loaded  (tape_size != 25'd0),
	.playing (tape_active),
	.fast    (tape_turbo),
	.position(tape_addr),
	.length  (tape_size),
	.hint_show(tape_hint_show),
	.hint_len(tape_hint_len),
	.hint_two(tape_hint_two),
	.hint_text(tape_hint_text),
	.status  (tape_status_word),
	.req     (tape_status_req),
	.ack     (tape_status_ack)
);

// R/G are crossed on purpose -- see BasicMasterJr.sv. video.v emits
// {R,G,B} = {bit2,bit1,bit0} of the pen; the machine's pen order is BRG
// (R=bit1, G=bit2, B=bit0), and this swap turns one into the other.
tape_overlay #(.FACTOR_BCD(TURBO_SHIFT == 5 ? 8'h32 : 8'h16)) overlay (
	.clk    (clk_vid),
	.ce_pix (ce_pix),
	.hblank (hb),
	.vblank (vb),
	.enable (tape_overlay),
	.status (tape_status_word),
	.req    (tape_status_req),
	.ack    (tape_status_ack),
	.rgb_in ({green, red, blue}),
	.rgb_out(overlay_rgb)
);

//////////////////////////////  OUTPUTS  /////////////////////////////////////
assign VGA_R    = overlay_rgb[23:16];
assign VGA_G    = overlay_rgb[15:8];
assign VGA_B    = overlay_rgb[7:0];
assign VGA_HS   = hs;
assign VGA_VS   = vs;
assign VGA_HB   = hb;
assign VGA_VB   = vb;
assign CE_PIXEL = ce_pix;

assign AUDIO_L = {dac_level, 11'd0};
assign AUDIO_R = {dac_level, 11'd0};

//////////////////////////////  DEBUG TAPS  //////////////////////////////////
assign dbg_cpu_addr   = core.cpu_addr;
assign dbg_cpu_din    = core.cpu_din;
assign dbg_cpu_dout   = core.cpu_dout;
assign dbg_cpu_rw     = core.cpu_rw;
assign dbg_cpu_vma    = core.vma;
assign dbg_bank       = core.bank;
assign dbg_tape_start = tape_start;
assign dbg_tape_stop  = tape_stop;
assign dbg_tape_bit   = tape_bit;
assign dbg_tape_motor = tape_motor;
assign dbg_tape_turbo = tape_turbo;
assign dbg_tape_state = cassette.state;
assign dbg_tape_addr  = cassette.sdram_addr;
assign dbg_tape_size  = tape_size;
assign dbg_tape_byte  = cassette.shifter;
assign dbg_record_wr       = recorder_wr;
assign dbg_record_addr     = recorder_addr;
assign dbg_record_data     = recorder_data;
assign dbg_record_size     = recorder_size;
assign dbg_record_dirty    = recorder_dirty;
assign dbg_record_overflow = recorder_overflow;
assign dbg_screen_mode = core.screen_mode;
assign dbg_kb_col     = {4'd0, kb_col};
assign dbg_kb_key     = kb_key;
assign dbg_kb_mod     = kb_mod;
assign dbg_kb_status  = keyboard.status;
assign dbg_kb_row0    = keyboard.keys[0];

endmodule
