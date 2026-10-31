//============================================================================
//
//  This program is free software; you can redistribute it and/or modify it
//  under the terms of the GNU General Public License as published by the Free
//  Software Foundation; either version 2 of the License, or (at your option)
//  any later version.
//
//  This program is distributed in the hope that it will be useful, but WITHOUT
//  ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or
//  FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public License for
//  more details.
//
//  You should have received a copy of the GNU General Public License along
//  with this program; if not, write to the Free Software Foundation, Inc.,
//  51 Franklin Street, Fifth Floor, Boston, MA 02110-1301 USA.
//
//============================================================================

module emu
(
	`include "sys/emu_ports.vh"
);

///////// Default values for ports not used in this core /////////

assign ADC_BUS  = 'Z;
assign USER_OUT = '1;
assign {UART_RTS, UART_TXD, UART_DTR} = 0;
assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
assign SDRAM_CLK = clk_sys;
assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

assign VGA_F1 = 0;
assign VGA_SCALER = 0;
assign VGA_DISABLE = 0;
assign HDMI_FREEZE = 0;
assign HDMI_BLACKOUT = 0;
assign HDMI_BOB_DEINT = 0;

// $EE80 bits 5:1 drive a 5-bit R-2R ladder into the speaker amp (IC40 +
// R36-R45 on the schematic). Unsigned, mono, same level on both channels.
assign AUDIO_S = 0;
assign AUDIO_L = {dac_level, 11'd0};
assign AUDIO_R = {dac_level, 11'd0};
assign AUDIO_MIX = 0;

assign LED_USER = 0;
assign LED_DISK = 0;
assign LED_POWER = 0;
assign BUTTONS = 0;

//////////////////////////////////////////////////////////////////

wire [1:0] ar = status[122:121];

assign VIDEO_ARX = (!ar) ? 12'd4 : (ar - 1'd1);
assign VIDEO_ARY = (!ar) ? 12'd3 : 12'd0;

`include "build_id.v"
localparam CONF_STR = {
	"BasicMasterJr;;",
	"-;",
	// The extension field is 3-character extensions concatenated, so "Tape"
	// was malformed (read as "Tap" plus a stray "e"). Tape images are .bin.
	// Row order follows the usual MiSTer computer-core layout
	// where it makes sense: media, machine, video, input, reset. The menu
	// stays flat (a few rows don't need pages), and every setting acts at once
	// (none of them changes the running machine), so there is no
	// "Changes pending" / "Apply and reset". [118] was the old "Fast tape
	// loading" and is left unused. FS1 also mounts a growable .SAV sidecar
	// that recordings are written to (see the flush below).
	"FS1,BMTBINSAV,Tape;",
	"-;",
	"O[124],Tape speed,32x,Normal;",
	"T[126],Rewind tape;",
	"T[119],New tape recording;",
	"-;",
	"O[117:115],Scandoubler Fx,None,HQ2x,CRT 25%,CRT 50%,CRT 75%;",
	"O[122:121],Aspect ratio,Original,Full Screen,[ARC1],[ARC2];",
	"O[125],Tape overlay,On,Off;",
	"-;",
	// JIS: keys by position, as on a Japanese keyboard. US: keys type their
	// legend, and the arrows move the cursor (keyboard.v).
	"O[123],Keyboard layout,JIS,US;",
	"O[127],Swap Alt/Win keys,No,Yes;",
	"-;",
	"R[0],Reset and close OSD;",
	// I, lines are not drawn, but Main's Enter handler counts them as rows
	// (menu.cpp), so one above a button makes Enter on that button do nothing.
	"I,Tape ready (rewound);",
	// Gamepad buttons type keys: the tape list's pad map for the loaded
	// program, else cursor keys, Space and Return (tape_hint). The J lines
	// must come after every menu row; Main counts them as rows otherwise.
	"J1,A,B,X,Y,L,R,Select,Start;",
	"jn,A,B,X,Y,L,R,Select,Start;",
	"V,v",`BUILD_DATE
};

wire forced_scandoubler;
wire [21:0] gamma_bus;
wire   [1:0] buttons;
wire [127:0] status;
wire  [10:0] ps2_key;
wire  [31:0] joystick_0;

wire [24:0] ioctl_addr;
wire  [7:0] ioctl_dout;
wire  [7:0] ioctl_index;
wire ioctl_wr;
wire ioctl_download;
wire ioctl_wait;
reg  tape_info_req = 1'b0;   // pulses after a tape mount: "Tape ready (rewound)"
wire [31:0] sd_lba[1];
wire        sd_rd = 1'b0;
reg         sd_wr = 1'b0;
wire        sd_ack;
wire [13:0] sd_buff_addr;
wire  [7:0] sd_buff_dout;
wire  [7:0] sd_buff_din[1];
wire        sd_buff_wr;
wire        img_mounted;
wire        img_readonly;
wire [63:0] img_size;

hps_io #(.CONF_STR(CONF_STR)) hps_io
(
	.clk_sys(clk_sys),
	.HPS_BUS(HPS_BUS),
	.EXT_BUS(),
	.gamma_bus(gamma_bus),

	.forced_scandoubler(forced_scandoubler),

	.buttons(buttons),
	.status(status),
	.status_menumask(16'd0),

	.ps2_key(ps2_key),
	.joystick_0(joystick_0),
	.info_req(tape_info_req),
	.info(8'd1),

	.ioctl_download(ioctl_download),
	.ioctl_wr(ioctl_wr),
	.ioctl_addr(ioctl_addr),
	.ioctl_dout(ioctl_dout),
	.ioctl_wait(ioctl_wait),
	.ioctl_index(ioctl_index),

	.sd_lba(sd_lba),
	.sd_rd(sd_rd),
	.sd_wr(sd_wr),
	.sd_ack(sd_ack),
	.sd_buff_addr(sd_buff_addr),
	.sd_buff_dout(sd_buff_dout),
	.sd_buff_din(sd_buff_din),
	.sd_buff_wr(sd_buff_wr),
	.img_mounted(img_mounted),
	.img_readonly(img_readonly),
	.img_size(img_size)
);

///////////////////////   CLOCKS   ///////////////////////////////

wire clk_sys, clk_vid;
pll pll
(
	.refclk(CLK_50M),
	.rst(0),
	.outclk_0(clk_sys),
	.outclk_1(clk_vid) // 25 MHz video_mixer master; 4 clocks per pixel
);


// HD46800 CPU clock enable, a phase accumulator stepping at 750 kHz on
// clk_sys. OSD Tape speed 32x (the default) runs the CPU and the tape 32 times
// faster together while a tape loads, preserving the monitor ROM's 2500 CPU
// cycles per tape bit. See rtl/tape_speed.v.
wire tape_motor;
wire tape_end;
wire tape_turbo;
wire tape_active;
wire [31:0] cpu_increment;
wire [31:0] tape_bit_period;

tape_speed #(.CLK_HZ(50_000_000), .SHIFT(5)) tape_speed(
  .clk(clk_sys),
  .enable(~status[124]),
  .motor(tape_motor),
  .tape_left(~tape_end),
  // 50 MHz / 300 baud. This is the real rate -- it works because
  // rtl/m6800_pad.v makes the CPU keep 6800 time. If tapes stop loading,
  // check the CPU timing first (cd vsim/cputest && make && ./obj_dir/Vcputb --pad).
  .base_period(32'd166667),
  .turbo(tape_turbo),
  .active(tape_active),
  .cpu_increment(cpu_increment),
  .bit_period(tape_bit_period)
);

reg [31:0] cpu_acc = 32'd0;
wire [32:0] cpu_sum = {1'b0, cpu_acc} + {1'b0, cpu_increment};
wire clk_cpu = cpu_sum[32];

always @(posedge clk_sys)
  cpu_acc <= cpu_sum[31:0];

wire reset = RESET | status[0] | buttons[1];

// Main sends the file's position in the row's extension list (BMT, BIN, SAV)
// in ioctl_index[7:6] (menu.cpp), so a .bin arrives as $41: match the slot only.
wire tape_ioctl = ioctl_index[5:0] == 6'd1;

// Mounting a tape is like swapping the cassette: the machine keeps running,
// so a CALL $E37E typed before the mount, or a program loaded from another
// tape, survives it. Only the recorder (and its save flush), which share the
// tape buffer with the download, start over. The player keeps its motor
// state and rewinds when the download ends.
wire tape_reset = reset | (ioctl_download & tape_ioctl);

// The SDRAM controller must NOT be re-initialised while a tape image is being
// written into it: `init` forces its state machine back to STATE_STARTUP every
// cycle it is high, so every byte of the transfer was being thrown away.
wire sdram_init = RESET | status[0] | buttons[1];

//////////////////////////////////////////////////////////////////

wire hs, vs, hb, vb;
wire [7:0] red, green, blue;
wire [3:0] kb_key, kb_mod;
wire [3:0] kb_col;

wire adc_cassette_bit;
wire ce_pix;
wire break_key;
wire [4:0] dac_level;

// The cassette reads the on-chip tape buffer. Keep the physical SDRAM
// controller initialized and idle so its external pins remain well defined.
wire [24:0] cassette_sdram_addr;
wire tape_start;
wire tape_stop;
wire tape_write;
wire tape_out;

// The tape image lives in a dedicated dual-port 64 KiB block RAM. hps_io
// writes one port at full speed while the cassette reads the other, avoiding
// the edge-triggered external SDRAM handshake and byte-lane hazards.
assign ioctl_wait = 1'b0;

// Latch how many bytes the tape image holds, so the player knows where the
// tape ends instead of wrapping through stale buffer data. Rewind whenever a
// new image is mounted (and say so: "Tape ready (rewound)") or on OSD Rewind
// tape.
//
// The native .bmt image is the same decoded byte stream used by playback.
// Recording overwrites it from byte zero after "New tape recording" and then
// appends across motor stops, matching bm2's overwrite/append lifecycle.
reg  [24:0] tape_size = 25'd0;
reg         tape_rewind = 1'b0;
reg         old_download = 1'b0;
reg         old_rewind_button = 1'b0;
wire  [7:0] tape_buffer_data;
wire        recorder_wr;
wire [15:0] recorder_addr;
wire  [7:0] recorder_data;
wire [16:0] recorder_size;
wire        recorder_dirty;
wire        recorder_overflow;
reg         recorder_saved = 1'b0;

cassette_recorder recorder (
  .clk_sys(clk_sys),
  .reset(tape_reset),
  .clear(status[119]),
  .saved(recorder_saved),
  .cpu_tick(clk_cpu),
  .motor(tape_motor),
  .write_strobe(tape_write),
  .buffer_wr(recorder_wr),
  .buffer_addr(recorder_addr),
  .buffer_data(recorder_data),
  .size(recorder_size),
  .dirty(recorder_dirty),
  .overflow(recorder_overflow)
);

always @(posedge clk_sys) begin
  old_download <= ioctl_download;
  old_rewind_button <= status[126];
  tape_rewind <= 1'b0;
  tape_info_req <= 1'b0;
  if (ioctl_download & ~old_download & tape_ioctl)
    tape_size <= 25'd0;
  if (ioctl_download & ioctl_wr & tape_ioctl)
    tape_size <= ioctl_addr + 25'd1;
  if (old_download & ~ioctl_download & tape_ioctl) begin
    tape_rewind <= 1'b1;
    tape_info_req <= 1'b1;
  end
  if (status[126] & ~old_rewind_button)
    tape_rewind <= 1'b1;
  if (status[119]) begin
    tape_size <= 25'd0;
    tape_rewind <= 1'b1;
  end
  if (recorder_wr)
    tape_size <= {8'd0, recorder_size};
end

// FS1 makes MiSTer mount a growable save sidecar as virtual disk 0. When the
// motor stops, write all occupied 512-byte sectors. The final sector is padded
// with mark bytes ($FF), which are harmless KCS leader in the raw stream.
reg        save_mounted = 1'b0;
reg  [2:0] flush_state = 3'd0;
reg  [6:0] flush_lba = 7'd0;
reg  [6:0] flush_last_lba = 7'd0;
reg        tape_motor_d = 1'b0;
localparam FLUSH_IDLE = 3'd0, FLUSH_REQ = 3'd1, FLUSH_DROP = 3'd2;

wire [15:0] save_ram_addr = {flush_lba, sd_buff_addr[8:0]};
wire [16:0] save_byte_offset = {1'b0, save_ram_addr};
wire [16:0] tape_last_byte = tape_size[16:0] - 17'd1;
assign sd_lba[0] = {25'd0, flush_lba};
assign sd_buff_din[0] = (save_byte_offset < tape_size[16:0])
                       ? tape_buffer_data : 8'hff;

always @(posedge clk_sys) begin
  tape_motor_d <= tape_motor;
  recorder_saved <= 1'b0;
  if (img_mounted)
    save_mounted <= ~img_readonly;

  if (tape_reset) begin
    sd_wr <= 1'b0;
    flush_state <= FLUSH_IDLE;
  end
  else begin
    case (flush_state)
      FLUSH_IDLE: begin
        sd_wr <= 1'b0;
        if (tape_motor_d & ~tape_motor & recorder_dirty & save_mounted
            & (tape_size != 25'd0)) begin
          flush_lba <= 7'd0;
          flush_last_lba <= tape_last_byte[15:9];
          flush_state <= FLUSH_REQ;
        end
      end
      FLUSH_REQ: begin
        sd_wr <= 1'b1;
        if (sd_ack) begin
          sd_wr <= 1'b0;
          flush_state <= FLUSH_DROP;
        end
      end
      FLUSH_DROP: begin
        if (!sd_ack) begin
          if (flush_lba == flush_last_lba) begin
            recorder_saved <= 1'b1;
            flush_state <= FLUSH_IDLE;
          end
          else begin
            flush_lba <= flush_lba + 7'd1;
            flush_state <= FLUSH_REQ;
          end
        end
      end
      default: flush_state <= FLUSH_IDLE;
    endcase
  end
end


sdram sdram_inst(
  .init(sdram_init),
  .clk(clk_sys),
  .wtbt(2'b00),
  .addr(25'd0),
  .dout(),
  .din(16'd0),
  .we(1'b0),
  .rd(1'b0),
  .ready(),
  .SDRAM_CKE(SDRAM_CKE),
  .SDRAM_A(SDRAM_A),
  .SDRAM_BA(SDRAM_BA),
  .SDRAM_DQ(SDRAM_DQ),
  .SDRAM_DQML(SDRAM_DQML),
  .SDRAM_DQMH(SDRAM_DQMH),
  .SDRAM_nCS(SDRAM_nCS),
  .SDRAM_nRAS(SDRAM_nRAS),
  .SDRAM_nCAS(SDRAM_nCAS),
  .SDRAM_nWE(SDRAM_nWE)
);

wire flushing = (flush_state != FLUSH_IDLE);
wire [15:0] tape_buffer_addr = flushing ? save_ram_addr
                                       : cassette_sdram_addr[15:0];
wire [15:0] tape_buffer_write_addr = recorder_wr ? recorder_addr
                                             : ioctl_addr[15:0];
wire  [7:0] tape_buffer_write_data = recorder_wr ? recorder_data
                                             : ioctl_dout;

ram tape_buffer(
  .clk(clk_sys),
  .addr(tape_buffer_write_addr),
  .din(tape_buffer_write_data),
  .dout(),
  .wr(recorder_wr | (ioctl_download & ioctl_wr & tape_ioctl)),
  .ce(1'b1),
  .addr_b(tape_buffer_addr),
  .dout_b(tape_buffer_data)
);

cassette cassette(
  .clk_sys(clk_sys),
  .bit_period(tape_bit_period),
  .reset(reset),
  .tape_start(tape_start),
  .tape_stop(tape_stop),
  .tape_rewind(tape_rewind),
  .image_size(tape_size),
  .sdram_addr(cassette_sdram_addr),
  .sdram_data({8'd0, tape_buffer_data}),
  .sdram_rd(),
  .sdram_we(),
  .sdram_wtbt(),
  .sdram_ready(1'b1),
  .tape_bit(adc_cassette_bit),
  .motor(tape_motor),
  .tape_end(tape_end),
  .status()
);

core core(
  .reset(reset),
  .clk_sys(clk_sys),
  .clk_cpu(clk_cpu),
  .clk_vid(clk_vid),
  .kb_col(kb_col),
  .kb_key(kb_key),
  .kb_mod(kb_mod),
  .hs(hs),
  .vs(vs),
  .hb(hb),
  .vb(vb),
	.ce_pix(ce_pix),
  .red(red),
  .green(green),
  .blue(blue),
  .break_key(break_key),
  .tape_bit(adc_cassette_bit),
  .tape_start(tape_start),
  .tape_stop(tape_stop),
  .tape_write(tape_write),
  .tape_out(tape_out),
  .dac_level(dac_level)
);

wire  [95:0] pad_map;   // from tape_hint

keyboard keyboard(
  .reset(reset),
  .clk_sys(clk_sys),
  .ps2_key(ps2_key),
  .swap_alt_win(status[127]),
  .us_layout(status[123]),
  .joy(joystick_0[11:0]),
  .pad_map(pad_map),
  .kb_col(kb_col),
  .kb_key(kb_key),
  .kb_mod(kb_mod),
  .break_key(break_key),
  .status()
);

assign CLK_VIDEO = clk_vid;

wire [2:0] video_fx = status[117:115];
wire [2:0] scanline_fx = video_fx ? video_fx - 3'd1 : 3'd0;
wire scandoubler = forced_scandoubler | (video_fx != 3'd0);
assign VGA_SL = scanline_fx[1:0];

// Tape status bar, between the machine's picture and video_mixer.
wire [400:0] tape_status_word;
wire        tape_status_req, tape_status_ack;
wire [23:0] overlay_rgb;

wire         tape_hint_show;
wire   [4:0] tape_hint_len;
wire         tape_hint_two;
wire [351:0] tape_hint_text;

// What to type next while the deck is stopped (load, then start).
// It watches the buffer's write port, so a recording updates it like a download.
tape_hint tape_hint(
  .clk(clk_sys),
  .wr(recorder_wr | (ioctl_download & ioctl_wr & tape_ioctl)),
  .rec(recorder_wr),
  .addr({9'd0, tape_buffer_write_addr}),
  .data(tape_buffer_write_data),
  // Tape list: Main loads games/BasicMasterJr/boot1.rom at core start as
  // index 1<<6 (slot 0).
  .list_wr(ioctl_download & ioctl_wr & (ioctl_index == 8'h40)),
  .list_addr(ioctl_addr),
  .list_data(ioctl_dout),
  .position(cassette_sdram_addr),
  .length(tape_size),
  .playing(tape_active),
  .ps2_key(ps2_key),
  .show(tape_hint_show),
  .len(tape_hint_len),
  .two(tape_hint_two),
  .text(tape_hint_text),
  .pad_map(pad_map)
);

tape_status tape_status(
  .clk(clk_sys),
  .loaded(tape_size != 25'd0),
  .playing(tape_active),
  .fast(tape_turbo),
  .position(cassette_sdram_addr),
  .length(tape_size),
  .hint_show(tape_hint_show),
  .hint_len(tape_hint_len),
  .hint_two(tape_hint_two),
  .hint_text(tape_hint_text),
  .status(tape_status_word),
  .req(tape_status_req),
  .ack(tape_status_ack)
);

tape_overlay #(.FACTOR_BCD(8'h32)) tape_overlay(
  .clk(clk_vid),
  .ce_pix(ce_pix),
  .hblank(hb),
  .vblank(vb),
  .enable(~status[125]),
  .status(tape_status_word),
  .req(tape_status_req),
  .ack(tape_status_ack),
  // Preserve the board's established red/green mapping.
  .rgb_in({green, red, blue}),
  .rgb_out(overlay_rgb)
);

video_mixer #(
  .LINE_LENGTH(324),
  .HALF_DEPTH(0),
  .GAMMA(1)
) video_mixer (
  .CLK_VIDEO(clk_vid),
  .ce_pix(ce_pix),
  .CE_PIXEL(CE_PIXEL),
  .scandoubler(scandoubler),
  .hq2x(video_fx == 3'd1),
  .gamma_bus(gamma_bus),
  .R(overlay_rgb[23:16]),
  .G(overlay_rgb[15:8]),
  .B(overlay_rgb[7:0]),
  .HSync(hs),
  .VSync(vs),
  .HBlank(hb),
  .VBlank(vb),
  .HDMI_FREEZE(1'b0),
  .freeze_sync(),
  .VGA_R(VGA_R),
  .VGA_G(VGA_G),
  .VGA_B(VGA_B),
  .VGA_VS(VGA_VS),
  .VGA_HS(VGA_HS),
  .VGA_DE(VGA_DE)
);


endmodule
