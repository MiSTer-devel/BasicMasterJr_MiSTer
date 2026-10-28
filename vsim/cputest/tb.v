`timescale 1ns / 1ps
//============================================================================
//  Cycle-measurement harness for rtl/m6801.sv.
//
//  The CPU plus 64K of flat, combinationally-read memory that main.cpp fills.
//  Everything interesting is exposed so the C++ side can count clocks between
//  instruction fetches and compare against MAME's 6800 cycle table.
//
//  Build and run from vsim/cputest:  make && ./obj_dir/Vcputb
//============================================================================

module cputb (
	input             clk,
	input             rst,
	input             cen,
	input             pad_enable,   // 0 = raw core, 1 = through m6800_pad

	input             irq,
	input             nmi,

	output     [15:0] address,
	output      [7:0] data_out,
	output            rw,
	output            vma,

	// internals, read hierarchically -- no changes to m6801.sv needed
	output      [5:0] dbg_state,
	output      [7:0] dbg_opcode
);

// public_flat_rw so main.cpp can load a program and inspect the result
reg [7:0] mem [0:65535] /*verilator public_flat_rw*/;

// Async read: the CPU samples data_in in the same cycle it presents an address.
wire [7:0] data_in = mem[address];

always @(posedge clk) begin
	if (cpu_cen && !rw && vma) mem[address] <= data_out;
end

wire cen_padded;
wire cpu_in_decode;
wire [7:0] cpu_opcode;

m6800_pad pad (
	.clk       (clk),
	.rst       (rst),
	.cen_in    (cen),
	.in_decode (cpu_in_decode),
	.opcode    (cpu_opcode),
	.cen_out   (cen_padded)
);

wire cpu_cen = pad_enable ? cen_padded : cen;

m6801 cpu (
	.clk      (clk),
	.rst      (rst),
	.cen      (cpu_cen),
	.rw       (rw),
	.vma      (vma),
	.address  (address),
	.data_in  (data_in),
	.data_out (data_out),
	.halt     (1'b0),
	.halted   (),
	.irq      (irq),
	.nmi      (nmi),
	.irq_icf  (1'b0),
	.irq_ocf  (1'b0),
	.irq_tof  (1'b0),
	.irq_sci  (1'b0),
	.in_decode (cpu_in_decode),
	.cur_opcode (cpu_opcode)
);

assign dbg_state  = cpu.state;
assign dbg_opcode = cpu.op_code;

endmodule
