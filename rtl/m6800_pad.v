// m6800_pad.v - make rtl/m6801.sv keep 6800 time.
//
// The MB-6885 has an HD46800 (a 6800). rtl/m6801.sv is a 6801 core, and a 6801
// completes many opcodes in fewer clocks than a 6800 does. That is not cosmetic
// here: the monitor ROM times cassette bits with software delay loops, so a
// fast CPU makes tapes load at the wrong rate, and anything else that
// busy-waits runs fast too.
//
// Rather than restructure a 4000-line state machine, this wrapper stalls the
// core's clock enable for however many extra clocks each opcode needs. The core
// honours `cen` on every one of its registers, so a stall is transparent.
//
// The per-opcode deficits in m6800_pad_table.vh are MEASURED, by running each
// opcode through the core in vsim/cputest and diffing against MAME's
// cycles_6800[] table. Regenerate both with:
//     cd vsim/cputest && make && ./obj_dir/Vcputb --table
//     cp m6800_pad_table.vh ../../rtl/
//
// The underlying core's formerly slow paths have been corrected in its state
// machine. Padding here now only needs to add clocks to faster 6801 opcodes.

module m6800_pad (
  input             clk,
  input             rst,
  input             cen_in,      // upstream clock enable
  input             in_decode,   // core is in decode_state
  input      [7:0]  opcode,      // opcode being decoded
  output            cen_out      // gated enable for the core
);

reg [3:0] pad_rom [0:255];
initial begin
`include "m6800_pad_table.vh"
end

reg [3:0] stall;
reg       decode_d;

wire [3:0] pad_val = pad_rom[opcode];

// `start` must gate cen_out combinationally, in the same cycle decode_state is
// seen. Registering the stall first lets the core take one more step before it
// freezes, which pushes the padding past the next opcode fetch -- the total
// time comes out right but each instruction is charged for its predecessor's
// padding, which is wrong per instruction and awkward to verify.
wire start = in_decode & ~decode_d & (pad_val != 4'd0);

assign cen_out = cen_in & (stall == 4'd0) & ~start;

always @(posedge clk) begin
  if (rst) begin
    stall    <= 4'd0;
    decode_d <= 1'b0;
  end
  else if (cen_in) begin
    if (start) begin
      stall    <= pad_val - 4'd1;   // this cycle is the first of pad_val
      decode_d <= 1'b1;             // one shot per decoded instruction
    end
    else begin
      if (stall != 4'd0) stall <= stall - 4'd1;
      decode_d <= in_decode;
    end
  end
end

endmodule
