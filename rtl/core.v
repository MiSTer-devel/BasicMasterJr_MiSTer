
module core #(
  // Hardware exposes the MP-1710's 32x24-pixel border around the 256x192
  // machine image. The desktop simulator disables it to retain compact
  // native-resolution regression captures.
  parameter VIDEO_BORDER = 1,
  // The hardware system clock is 50 MHz. The simulator may use a lower
  // timebase to avoid evaluating idle system-clock cycles, while preserving
  // timers in real units.
  parameter SYS_CLK_HZ = 50_000_000
)(
  input reset,

  input clk_sys,
  input clk_cpu,   // 750 kHz clock ENABLE on clk_sys, not a clock
  input clk_vid,

  output reg [3:0] kb_col,
  input [3:0] kb_key,
  input [3:0] kb_mod,

  output hs,
  output vs,
  output hb,
  output vb,
  output ce_pix,
  output [7:0] red,
  output [7:0] green,
  output [7:0] blue,

  input break_key,       // BREAK key, active high -> NMI when armed

  input tape_bit,
  output reg tape_start,
  output reg tape_stop,
  output reg tape_write,
  output reg tape_out,

  output [4:0] dac_level  // 5-bit R-2R ladder value for the speaker
);

assign dac_level = dac;

wire [15:0] cpu_addr;
wire [7:0] cpu_dout;
wire cpu_rw;
wire vma;

wire [7:0] mux_out;
wire [7:0] mux = ~mux_out;

reg [7:0] io_out;
wire [7:0] ram_dout;
wire [7:0] rom0_dout, romB_dout, romDF_dout, romE_dout;
wire [7:0] rom_dout = romB_dout | romDF_dout | romE_dout;

wire romB_sel = cpu_rw & ~bank[0] & (mux[3]|mux[4]);
wire romD_sel = cpu_rw & ~bank[0] & mux[5];
wire romE_sel = cpu_rw & ~bank[1] & mux[6] & ~cpu_addr[11];
wire romF_sel = cpu_rw & ~bank[2] & mux[7];

wire rom_sel = romB_sel | romD_sel | romE_sel | romF_sel;
wire ram_sel = ~rom_sel;
wire io_sel = mux[6] & cpu_addr[11];

wire [7:0] cpu_din =
  io_sel ? io_out :
  rom_sel ? rom_dout :
  ram_sel ? ram_dout : 8'hff;

// MP-1710 attribute latch: writing $0100-$03FF also stores the current
// $E890 colour into the parallel attribute RAM, but only on a CPU *write*
// and only while $E892 bit 0 (色情報書き込み許可 / colour write enable) is set.
// Reads used to latch too, which let the video scanner scribble over
// attributes. [bm2 bm2mem.c:77-83]
wire vram_write = vma & ~cpu_rw & color_board[0]
               & (cpu_addr >= 16'h100) & (cpu_addr < 16'h400);

wire [15:0] video_ram_addr;
wire [7:0] video_ram_data;
wire [10:0] video_char_addr;

video #(.BORDER(VIDEO_BORDER)) video(
  .clk_sys(clk_sys),
  .clk_vid(clk_vid),
  .hs(hs),
  .vs(vs),
  .hb(hb),
  .vb(vb),
  .red(red),
  .green(green),
  .blue(blue),
  .ce_pix(ce_pix),
  .hcount(),
  .vcount(),
  .frame(),
  .ram_addr(video_ram_addr),
  .char_addr(video_char_addr),
  .ram_data(video_ram_data),
  .char_data(rom0_dout),
  .color_board(mp1710on),
  .inverted(xor_disp[7]),
  .border_color(xor_disp[7] ? bckreg[6:4] : bckreg[2:0]),
  .screen_mode(screen_mode),
  .charcolor(charcolor),
  .color_ram_addr(cpu_addr[9:0] - 10'h100),
  .color_ram_wr(vram_write)
);

// ---------------------------------------------------------------------------
// Interrupts
//
// IRQ  : ~60 Hz timer, taken from the vertical blank. Disabled while $EFD0
//        bit 4 is set (bm2 main.c:47-51). The handler acknowledges by reading
//        $EF40 just before its RTI ($F0B9); the watchdog below is only there so
//        a program that leaves the line asserted cannot wedge the machine.
// NMI  : the BREAK key, armed by $EEC0 bit 7.
// ---------------------------------------------------------------------------
// NOTE: this all runs on clk_sys, NOT clk_cpu. irq_ack is a single-cycle pulse
// from the clk_sys I/O decoder, and clk_cpu only ticks once every 67 clk_sys
// cycles -- sampling the pulse there misses it almost every time, the IRQ never
// clears, and the CPU lives in the handler. (It does: keyboard input dies.)
reg irq;
reg [19:0] irq_age;
(* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
reg vs_meta, vs_sys;
reg old_vs;
wire timer_dis = bank_mode[4];
wire irq_vector_fetch = cpu_rw & (cpu_addr == 16'hFFF8);
localparam integer IRQ_WATCHDOG_TICKS = SYS_CLK_HZ * 16 / 1000;

always @(posedge clk_sys) begin
  vs_meta <= vs;
  vs_sys  <= vs_meta;
  old_vs  <= vs_sys;
  if (reset) begin
    irq     <= 1'b0;
    irq_age <= 20'd0;
  end
  else begin
    if (old_vs & ~vs_sys & ~timer_dis) begin
      irq     <= 1'b1;
      irq_age <= 20'd0;
    end
    else if (irq) begin
      irq_age <= irq_age + 20'd1;
      // Drop the line as soon as the CPU commits to the interrupt, i.e. when
      // it fetches the IRQ vector at $FFF8. Holding it until the handler reads
      // $EF40 does not work: the ROM does not acknowledge on every path, so a
      // level-triggered IRQ re-enters immediately after RTI and the foreground
      // never runs (typing stops dead). bm2 sidesteps this by injecting a
      // one-shot interrupt rather than driving a level.
      if (irq_vector_fetch || irq_ack || irq_age == IRQ_WATCHDOG_TICKS[19:0]) irq <= 1'b0;
    end
  end
end

// BREAK key -> NMI, edge triggered, gated by the $EEC0 bit 7 arm bit.
reg nmi;
reg old_break;
always @(posedge clk_sys) begin
  old_break <= break_key;
  if (reset) nmi <= 1'b0;
  else begin
    if (break_key & ~old_break & kb_nmi_en) nmi <= 1'b1;
    else if (~kb_nmi_en) nmi <= 1'b0;   // clearing the arm bit clears a pending NMI
  end
end

// The CPU core is a 6801; this machine has a 6800. m6800_pad stalls the core
// so each opcode takes the number of clocks a 6800 would. See rtl/m6800_pad.v.
//
// Both run on clk_sys with clk_cpu as a clock ENABLE. clk_cpu is `div == 0`, a
// one-tick-in-67 pulse decoded from a counter -- driving a clock port with it
// asks the fitter to build a clock out of fabric logic, which glitches on the
// counter's bit skew and leaves the whole CPU outside TimeQuest's analysis.
// Every register in m6801.sv is gated by `cen` (the port is (*direct_enable*)),
// and m6800_pad gates on cen_in, so enabling is cycle-for-cycle identical to
// clocking and keeps the CPU, the RAM and the ROMs in one 50 MHz domain.
wire cpu_cen;
wire cpu_in_decode;
wire [7:0] cpu_opcode;

m6800_pad cpu_pad(
  .clk(clk_sys),
  .rst(reset),
  .cen_in(clk_cpu),
  .in_decode(cpu_in_decode),
  .opcode(cpu_opcode),
  .cen_out(cpu_cen)
);

m6801 cpu(
  .clk(clk_sys),
  .rst(reset),
  .cen(cpu_cen),
  .rw(cpu_rw),
  .vma(vma),
  .address(cpu_addr),
  .data_in(cpu_din),
  .data_out(cpu_dout),
  .halt(1'b0),
  .halted(),
  .irq(irq),
  .nmi(nmi),
  .irq_icf(),
  .irq_ocf(),
  .irq_tof(),
  .irq_sci(),
  .in_decode(cpu_in_decode),
  .cur_opcode(cpu_opcode)
);

// rom mux
x74138 rom_mux(
  .G1(cpu_addr[15]),
  .G2A(1'b0),
  .G2B(1'b0),
  .A(cpu_addr[14:12]),
  .Y(mux_out)
);

ram ram(
  .clk(clk_sys),
  .addr(cpu_addr),
  .din(cpu_dout),
  .dout(ram_dout),
  .wr(~cpu_rw & vma),
  .ce(ram_sel),
  .addr_b(video_ram_addr),
  .dout_b(video_ram_data)
);

// read by video
rom #(.MEMFILE("rom0.mem"), .DW(8), .AW(11)) rom0(
  .clk(clk_sys),
  .addr(video_char_addr),
  .dout(rom0_dout),
  .ce(1'b1)
);

rom #(.MEMFILE("romb.mem"), .DW(8), .AW(13)) romB(clk_sys, { ~cpu_addr[12], cpu_addr[11:0] }, romB_dout, romB_sel);
rom #(.MEMFILE("romdf.mem"), .DW(8), .AW(13)) romDF(clk_sys, { cpu_addr[13], cpu_addr[11:0] }, romDF_dout, romD_sel|romF_sel);
rom #(.MEMFILE("rome.mem"), .DW(8), .AW(11)) romE(
  .clk(clk_sys),
  .addr(cpu_addr[10:0]),
  .dout(romE_dout),
  .ce(romE_sel)
);


// IO map
reg [7:0] xor_disp;
reg [7:0] charcolor;
reg [7:0] color_board;
reg       mp1710on;     // set once $E892 has been written: colour adapter present
reg [7:0] bank_mode;    // $EFD0, read back verbatim
reg [7:0] bckreg;       // $E891, MP-1710 screen background / border colour
reg [7:0] screen_mode;  // $EFE0
reg       kb_nmi_en;
reg       irq_ack;      // pulses when the handler reads $EF40
reg [4:0] dac;          // $EE80 bits 5:1 -> 5-bit R-2R ladder

// $EFD0: ---x ---- timer IRQ disable, ---- -x-- $F000 RAM,
//        ---- --x- $E000 RAM, ---- ---x $B000 RAM
wire [2:0] bank = bank_mode[2:0];

always @(posedge clk_sys) begin
  io_out <= 8'hff;
  tape_start <= 1'b0;
  tape_stop <= 1'b0;
  tape_write <= 1'b0;
  irq_ack <= 1'b0;
  if (reset) begin
    charcolor <= 8'b0000_0111;
    xor_disp <= 8'd0;
    bank_mode <= 8'd0;      // all three regions ROM, timer IRQ enabled
    mp1710on <= 1'b0;
    bckreg <= 8'h70;        // bm2's no-adapter default
    screen_mode <= 8'd0;
    color_board <= 8'd0;
    kb_nmi_en <= 1'b0;
    kb_col <= 4'd0;
    dac <= 5'd0;
    tape_out <= 1'b0;
  end
  else if (io_sel) begin
    case (cpu_addr)
      16'he890: begin
        if (cpu_rw)
          io_out <= charcolor;
        else
          charcolor <= cpu_dout;
      end
      16'he891: // MP-1710 screen background / border colour
        if (cpu_rw)
          io_out <= bckreg;
        else
          bckreg <= cpu_dout;
      16'he892: begin // MP-1710 colour-RAM write enable
        if (cpu_rw)
          io_out <= color_board;
        else begin
          color_board <= cpu_dout;
          mp1710on <= 1'b1;   // any write means the adapter is fitted
        end
      end
      16'hee00: begin
        io_out <= 8'h01;
        tape_stop <= 1'b1;
      end
      16'hee20: begin
        io_out <= 8'h01;
        tape_start <= 1'b1;
      end
      16'hee40: xor_disp <= cpu_dout;
      // Tape in / tape out + speaker. Reads give the demodulated serial line on
      // bit 7. Writes latch IC40 (HD74LS174): bit 0 is the tape output,
      // bits 5:1 drive a 5-bit R-2R ladder into the speaker amp. [SCH, ROM $F535]
      16'hee80:
        if (cpu_rw)
          io_out <= { tape_bit, 7'd0 };
        else begin
          if (cpu_cen) begin
            tape_out   <= cpu_dout[0];
            tape_write <= 1'b1;
            dac        <= cpu_dout[5:1];
          end
        end
      16'heec0: begin // kb
        if (cpu_rw)
          io_out <= { kb_mod, kb_key };
        else begin
          kb_nmi_en <= cpu_dout[7];
          kb_col    <= cpu_dout[3:0];
        end
      end
      // Read-to-clear interrupt acknowledge: the timer handler does
      // LDAA $EF40 immediately before its RTI at $F0B9.
      16'hef40: irq_ack <= 1'b1;
      16'hef00: io_out <= 8'hff; // timer status; bit 7 tested at $F050
      // Interrupt source flag, bit 7 picks which timer the handler services
      // ($F0BD). NOT the BREAK key -- that reaches the CPU as an NMI.
      16'hef80: io_out <= 8'h80;
      // RAM/ROM bank select + timer enable. cpu_rw HIGH is a read on the 6800;
      // this used to be the other way round, so writes were ignored and reads
      // latched bus garbage into the bank register.
      16'hefd0:
        if (cpu_rw)
          io_out <= bank_mode;
        else
          bank_mode <= cpu_dout;
      16'hefe0: screen_mode <= cpu_dout;
      default: io_out <= 8'hff;
    endcase
  end
end

endmodule
