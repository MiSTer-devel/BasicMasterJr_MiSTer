// tape_speed.v - CPU and tape rates while a tape loads (OSD "Tape speed").
//
// The monitor and BASIC time tape bits with CPU instruction loops (2500 CPU
// cycles per bit), so turbo runs the CPU clock enable and the tape bit rate
// 2^SHIFT times faster together: the loader sees the same bit in its own units.
// Nothing else speeds up (video, the timer IRQ and the keyboard stay real-time).
//
// Turbo is on while the motor runs (loading or saving: the recorder measures
// in CPU enables, so a save is the same at any speed) and for HOLD_MS after it
// stops, as long as the tape has bytes left. BASIC's LOAD stops the motor after every block of
// an ASCII (.S) program while it stores the text, about 45 frames per block at
// 750 kHz -- half of every BASIC load. The hold keeps those stops fast; at 32x
// a stop takes ~25 ms. The cost is that a program may start up to HOLD_MS fast
// after its last block (a stop at the end of the image ends turbo at once).
//
// `active` is the same idea with a longer hold, for the tape overlay, so the
// status bar doesn't blink off at every block of a BASIC load.
//
// The enable must stay at least two clk ticks apart: the CPU reads the
// synchronous RAMs one tick after it drives the address. 32x on 50 MHz is a
// 24 MHz enable (2 or 3 ticks apart); a clock below ~48 MHz needs SHIFT <= 4.

module tape_speed #(
  parameter integer CLK_HZ  = 50_000_000,
  parameter integer SHIFT   = 5,        // turbo factor = 2^SHIFT
  parameter integer HOLD_MS = 250,      // turbo after the motor stops
  parameter integer SHOW_MS = 1500      // overlay after the motor stops
)(
  input             clk,
  input             enable,             // OSD Tape speed: Nx (not Normal)
  input             motor,              // cassette relay ($EE20 on, $EE00 off)
  input             tape_left,          // a tape is mounted and not played out (for the hold)
  input      [31:0] base_period,        // clk ticks per tape bit at 300 baud
  output            turbo,
  output            active,
  output     [31:0] cpu_increment,      // phase step of the CPU enable accumulator
  output     [31:0] bit_period
);

  // round(750 kHz / CLK_HZ * 2^32): 64,424,509 at 50 MHz.
  localparam [63:0] BASE_INC = (64'd750_000 * 64'd4294967296 + CLK_HZ / 2) / CLK_HZ;
  localparam [31:0] HOLD_TICKS = CLK_HZ / 1000 * HOLD_MS;
  localparam [31:0] SHOW_TICKS = CLK_HZ / 1000 * SHOW_MS;

  reg [31:0] hold = 32'd0;
  reg [31:0] show = 32'd0;
  reg        motor_d = 1'b0;
  reg        fast = 1'b0;     // OSD Tape speed, taken when the deck starts

  // A change of Tape speed takes effect the next time the motor starts:
  // switching in the middle of a byte would change the bit timing mid-frame.
  always @(posedge clk) begin
    motor_d <= motor;
    if (motor & ~motor_d) fast <= enable;
    if (motor) begin
      hold <= HOLD_TICKS;
      show <= SHOW_TICKS;
    end
    else begin
      if (hold != 32'd0) hold <= hold - 32'd1;
      if (show != 32'd0) show <= show - 32'd1;
    end
  end

  assign turbo  = fast & (motor | (tape_left & (hold != 32'd0)));
  assign active = tape_left & (motor | (show != 32'd0));

  assign cpu_increment = turbo ? (BASE_INC[31:0] << SHIFT) : BASE_INC[31:0];
  assign bit_period    = turbo ? ((base_period + (32'd1 << (SHIFT - 1))) >> SHIFT)
                               : base_period;

endmodule
