// cassette.v - Basic Master Jr. tape playback
//
// The MB-6885 demodulates the tape in hardware: the audio goes through an
// LM565N PLL FSK demodulator, a 3-pole filter and an HD75108AP comparator
// before reaching $EE80 bit 7 (schematic sheet 2/2). The monitor ROM's bit
// sampler at $F794 reads that line seven times and majority-votes, which only
// makes sense against a clean logic level.
//
// So this module does NOT stream audio samples. It stores the demodulated byte
// stream in SDRAM and shifts it out as a serial line, exactly like the real
// demodulator's output. Same model bm2 uses (tape.c), same format bmtape2
// writes -- 300 baud, 11 bit-times per byte:
//
//     bit 0      start bit, low
//     bits 1..8  data, LSB first
//     bits 9,10  stop bits, high
//
// Idle (motor stopped, or past the end of the image) sits at mark = 1.
//
// The motor is a latch, not a strobe: $EE20 energises the relay (RL1) and
// $EE00 releases it, and the tape holds its position in between -- the ROM
// stops and restarts the motor between blocks and expects to carry on where it
// left off. The byte pointer only advances on a completed frame, so a frame
// interrupted by a motor stop is re-sent from its start bit on restart.

module cassette (
  input             clk_sys,
  // clk_sys ticks per tape bit. 50 MHz / 300 baud = 166667.
  input      [31:0] bit_period,
  input             reset,

  input             tape_start,   // $EE20 accessed: motor on
  input             tape_stop,    // $EE00 accessed: motor off
  input             tape_rewind,  // seek back to the start of the image
  input      [24:0] image_size,   // bytes loaded; 0 = no tape mounted

  // SDRAM interface
  output reg [24:0] sdram_addr,
  input      [15:0] sdram_data,
  output reg        sdram_rd,
  output reg        sdram_we,
  output reg  [1:0] sdram_wtbt,
  input             sdram_ready,

  output            tape_bit,     // -> $EE80 bit 7
  output reg        motor,
  output            tape_end,     // no tape, or every byte has been played
  output      [2:0] status
);

  localparam
    S_IDLE  = 3'd0,   // motor off, or tape finished
    S_FETCH = 3'd1,   // request the next byte from SDRAM
    S_WAIT  = 3'd2,   // let the controller drop `ready`
    S_RECV  = 3'd3,   // wait for data and latch it
    S_SHIFT = 3'd4;   // clock the 11-bit frame out

  reg  [2:0] state;
  reg [31:0] bit_timer;
  reg  [3:0] bit_index;
  reg  [7:0] shifter;
  reg  [1:0] recv_delay;
  reg        tape_start_d, tape_stop_d, tape_rewind_d;
  reg        serial;

  assign tape_bit = serial;
  assign status   = state;

  wire at_end = (image_size == 25'd0) || (sdram_addr >= image_size);
  assign tape_end = at_end;

  // The frame bit currently on the wire: start low, 8 data LSB first, stops high.
  wire frame_bit = (bit_index == 4'd0) ? 1'b0
                 : (bit_index <= 4'd8) ? shifter[bit_index[2:0] - 3'd1]
                                       : 1'b1;

  always @(posedge clk_sys) begin
    // $EE20 / $EE00 are held for a whole CPU cycle, so edge-detect them.
    tape_start_d  <= tape_start;
    tape_stop_d   <= tape_stop;
    tape_rewind_d <= tape_rewind;

    sdram_we   <= 1'b0;
    sdram_wtbt <= 2'b00;
    sdram_rd   <= 1'b0;

    if (reset) begin
      state      <= S_IDLE;
      sdram_addr <= 25'd0;
      motor      <= 1'b0;
      serial     <= 1'b1;
      bit_timer  <= 32'd0;
      bit_index  <= 4'd0;
      shifter    <= 8'hFF;
    end
    else begin
      if (tape_rewind & ~tape_rewind_d) begin
        sdram_addr <= 25'd0;
        state      <= S_IDLE;
        serial     <= 1'b1;
      end

      if (tape_start & ~tape_start_d) motor <= 1'b1;
      if (tape_stop  & ~tape_stop_d)  motor <= 1'b0;

      if (!motor || at_end) begin
        // Motor off or past the end: park at mark and abandon any part-sent
        // frame. sdram_addr is left alone so the next start resumes here.
        state  <= S_IDLE;
        serial <= 1'b1;
      end
      else begin
        case (state)
          S_IDLE: begin
            bit_timer <= 32'd0;
            bit_index <= 4'd0;
            state     <= S_FETCH;
          end

          S_FETCH: begin
            sdram_rd   <= 1'b1;      // one-cycle request pulse
            recv_delay <= 2'd3;
            state      <= S_WAIT;
          end

          // Give the controller time to lower `ready` before believing it.
          // Sampling it in the same cycle as `rd` returns the previous word --
          // that was a real bug in the old code.
          S_WAIT: begin
            if (recv_delay == 2'd0) state <= S_RECV;
            else recv_delay <= recv_delay - 2'd1;
          end

          S_RECV: begin
            if (sdram_ready) begin
              shifter   <= sdram_data[7:0];   // dout[7:0] is the byte at addr
              bit_index <= 4'd0;
              bit_timer <= 32'd0;
              state     <= S_SHIFT;
            end
          end

          S_SHIFT: begin
            serial <= frame_bit;
            if (bit_timer >= bit_period - 32'd1) begin
              bit_timer <= 32'd0;
              if (bit_index == 4'd10) begin
                // Frame complete: this byte has been delivered.
                sdram_addr <= sdram_addr + 25'd1;
                state      <= S_FETCH;
              end
              else bit_index <= bit_index + 4'd1;
            end
            else bit_timer <= bit_timer + 32'd1;
          end

          default: state <= S_IDLE;
        endcase
      end
    end
  end

endmodule
