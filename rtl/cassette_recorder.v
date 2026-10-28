// cassette_recorder.v - decode the Jr.'s bit-banged 300-baud KCS output
//
// The monitor writes $EE80 once per FSK half-cycle. Measuring in upstream
// 750 kHz CPU enables makes this independent of Tape speed: turbo
// changes wall-clock time, but not the emulated CPU-state intervals.
// This follows bm2 tape.c: accumulate writes for one 2433-state bit and
// distinguish 2400 Hz mark (16 writes) from 1200 Hz space (8 writes).

module cassette_recorder (
  input             clk_sys,
  input             reset,
  input             clear,
  input             saved,
  input             cpu_tick,
  input             motor,
  input             write_strobe,

  output reg        buffer_wr,
  output reg [15:0] buffer_addr,
  output reg  [7:0] buffer_data,
  output reg [16:0] size,
  output reg        dirty,
  output reg        overflow
);

  localparam [12:0] BIT_STATES = 13'd2433;
  localparam  [9:0] MAX_INTERVAL = 10'd470;

  reg  [9:0] since_write;
  reg [12:0] total_states;
  reg  [4:0] write_count;
  reg  [3:0] frame_pos;
  reg  [7:0] shifter;

  wire [13:0] next_total = {1'b0, total_states} + {4'd0, since_write};
  wire  [5:0] next_count = {1'b0, write_count} + 6'd1;
  wire        decoded_bit = next_count > 6'd12;

  always @(posedge clk_sys) begin
    buffer_wr <= 1'b0;

    if (reset || clear) begin
      since_write <= 10'd0;
      total_states <= 13'd0;
      write_count <= 5'd0;
      frame_pos <= 4'd0;
      shifter <= 8'd0;
      buffer_addr <= 16'd0;
      buffer_data <= 8'd0;
      size <= 17'd0;
      dirty <= 1'b0;
      overflow <= 1'b0;
    end
    else begin
      if (saved)
        dirty <= 1'b0;
      if (!motor) begin
        since_write <= 10'd0;
        total_states <= 13'd0;
        write_count <= 5'd0;
        frame_pos <= 4'd0;
      end
      else begin
        if (cpu_tick && since_write != 10'h3ff)
          since_write <= since_write + 10'd1;

        if (write_strobe) begin
          since_write <= 10'd0;

          // A long gap is not KCS. It also provides clean resynchronisation
          // after speaker-DAC writes or the beginning of a recording.
          if (since_write > MAX_INTERVAL) begin
            total_states <= 13'd0;
            write_count <= 5'd0;
            frame_pos <= 4'd0;
          end
          else if (next_total >= {1'b0, BIT_STATES}) begin
            total_states <= 13'd0;
            write_count <= 5'd0;

            if (frame_pos == 4'd0) begin
              // Ignore mark/leader until a valid start bit arrives.
              if (!decoded_bit) begin
                frame_pos <= 4'd1;
                shifter <= 8'd0;
              end
            end
            else if (frame_pos <= 4'd8) begin
              shifter[frame_pos[2:0] - 3'd1] <= decoded_bit;
              frame_pos <= frame_pos + 4'd1;
            end
            else if (frame_pos == 4'd9) begin
              // bm2 tolerates a bad first stop bit and validates the second.
              frame_pos <= 4'd10;
            end
            else if (decoded_bit) begin
              frame_pos <= 4'd0;
              if (size < 17'd65536) begin
                buffer_addr <= size[15:0];
                buffer_data <= shifter;
                buffer_wr <= 1'b1;
                size <= size + 17'd1;
                dirty <= 1'b1;
              end
              else begin
                overflow <= 1'b1;
              end
            end
          end
          else begin
            total_states <= next_total[12:0];
            write_count <= next_count[4:0];
          end
        end
      end
    end
  end

endmodule
