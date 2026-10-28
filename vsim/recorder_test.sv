`timescale 1ns/1ps

module recorder_test;
  reg clk = 0;
  always #5 clk = ~clk;

  reg reset = 1;
  reg clear = 0;
  reg saved = 0;
  reg cpu_tick = 0;
  reg motor = 0;
  reg write_strobe = 0;
  wire buffer_wr;
  wire [15:0] buffer_addr;
  wire [7:0] buffer_data;
  wire [16:0] size;
  wire dirty;
  wire overflow;

  reg [7:0] captured [0:7];
  integer captured_count = 0;

  cassette_recorder dut (
    .clk_sys(clk), .reset(reset), .clear(clear), .saved(saved),
    .cpu_tick(cpu_tick), .motor(motor), .write_strobe(write_strobe),
    .buffer_wr(buffer_wr), .buffer_addr(buffer_addr),
    .buffer_data(buffer_data), .size(size), .dirty(dirty),
    .overflow(overflow)
  );

  always @(negedge clk) begin
    if (buffer_wr) begin
      if (buffer_addr !== captured_count[15:0]) begin
        $display("FAIL address: got %0d expected %0d", buffer_addr, captured_count);
        $fatal;
      end
      captured[captured_count] = buffer_data;
      captured_count = captured_count + 1;
    end
  end

  task cpu_pulse;
    input integer wall_gap;
    integer j;
    begin
      for (j = 1; j < wall_gap; j = j + 1) @(negedge clk);
      cpu_tick = 1;
      @(negedge clk);
      cpu_tick = 0;
    end
  endtask

  task tape_write_after;
    input integer ticks;
    input integer wall_gap;
    integer j;
    begin
      for (j = 0; j < ticks; j = j + 1) cpu_pulse(wall_gap);
      write_strobe = 1;
      @(negedge clk);
      write_strobe = 0;
    end
  endtask

  task send_bit;
    input bit_value;
    input integer wall_gap;
    integer j;
    integer half_cycles;
    integer interval;
    begin
      half_cycles = bit_value ? 16 : 8;
      interval = bit_value ? 153 : 305;
      for (j = 0; j < half_cycles; j = j + 1)
        tape_write_after(interval, wall_gap);
    end
  endtask

  task send_byte;
    input [7:0] value;
    input integer wall_gap;
    integer j;
    begin
      send_bit(0, wall_gap);
      for (j = 0; j < 8; j = j + 1) send_bit(value[j], wall_gap);
      send_bit(1, wall_gap);
      send_bit(1, wall_gap);
    end
  endtask

  initial begin
    repeat (4) @(negedge clk);
    reset = 0;
    motor = 1;

    // Same emulated intervals, very different wall-clock CPU enable spacing.
    send_byte(8'hA5, 1);
    send_byte(8'h3C, 4);
    repeat (4) @(negedge clk);

    if (captured_count != 2 || captured[0] !== 8'hA5 || captured[1] !== 8'h3C) begin
      $display("FAIL bytes: count=%0d first=%02x second=%02x",
               captured_count, captured[0], captured[1]);
      $fatal;
    end
    if (size !== 17'd2 || !dirty || overflow) begin
      $display("FAIL status: size=%0d dirty=%0d overflow=%0d", size, dirty, overflow);
      $fatal;
    end

    saved = 1;
    @(negedge clk);
    saved = 0;
    @(negedge clk);
    if (dirty) begin
      $display("FAIL dirty did not clear after save acknowledgement");
      $fatal;
    end

    $display("PASS cassette recorder: A5 3C at normal/turbo wall-clock spacing");
    $finish;
  end
endmodule
