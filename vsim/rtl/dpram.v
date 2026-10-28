// Simulation replacement for rtl/dpram.v (the Quartus altsyncram wrapper).
// Same port list, same behaviour: 64K x 8 true dual-port. Read latency matches
// the altsyncram settings: port A (CPU) registers only its address, so data is
// there one clock after the address; port B (video, tape) also registers its
// output, so two clocks. Getting this wrong once hid a hardware-only crash:
// with a two-clock port A, a CPU enable two ticks apart (32x tape turbo) read
// stale data on the FPGA while the sim ran fine. Read-during-write on the same
// port returns OLD data.
//
// This file shadows ../rtl/dpram.v -- the Makefile lists this one and not that
// one. Keep the ports in sync if the Quartus wrapper is ever regenerated.

module dpram (
	input  [15:0] address_a,
	input  [15:0] address_b,
	input         clock,
	input   [7:0] data_a,
	input   [7:0] data_b,
	input         rden_a,
	input         rden_b,
	input         wren_a,
	input         wren_b,
	output  [7:0] q_a,
	output  [7:0] q_b
);

// public_flat_rd lets sim_main.cpp read the machine's RAM for --dump-mem
reg [7:0] mem [0:65535] /*verilator public_flat_rd*/;
reg [7:0] qa_r, qb_r, qb_out;

// Power-on contents. Real DRAM comes up as garbage; zero keeps sim runs
// reproducible (and matches how the FPGA block RAM initialises).
integer i;
initial begin
	for (i = 0; i < 65536; i = i + 1) mem[i] = 8'h00;
	qa_r = 8'h00;
	qb_r = 8'h00;
	qb_out = 8'h00;
end

always @(posedge clock) begin
	if (wren_a) mem[address_a] <= data_a;
	if (rden_a) qa_r <= mem[address_a];
end

always @(posedge clock) begin
	if (wren_b) mem[address_b] <= data_b;
	if (rden_b) qb_r <= mem[address_b];
	qb_out <= qb_r;                    // outdata_reg_b = "CLOCK0"
end

assign q_a = qa_r;
assign q_b = qb_out;

endmodule
