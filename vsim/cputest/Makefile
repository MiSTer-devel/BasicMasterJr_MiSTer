V = verilator
TOP = --top-module cputb
RTL = ../../rtl

V_OPT = -O3 --x-assign fast --x-initial fast --noassert
V_DEFINE = --timescale-override 1ps/1ps -Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-fatal

EXE = ./obj_dir/Vcputb

all: cycles_6800.h $(EXE)

cycles_6800.h: extract_cycles.py
	./extract_cycles.py

$(EXE): tb.v $(RTL)/m6801.sv $(RTL)/m6800_pad.v $(RTL)/m6800_pad_table.vh main.cpp cycles_6800.h Makefile
	$V -cc $(V_OPT) -exe --Mdir ./obj_dir $(V_DEFINE) $(TOP) -I$(RTL) \
		-CFLAGS "-O2 -I.." tb.v $(RTL)/m6801.sv $(RTL)/m6800_pad.v main.cpp
	(cd obj_dir; make -f Vcputb.mk OBJCACHE= OPT_FAST="-O2" OPT_SLOW="-O0")

run: $(EXE)
	$(EXE)

table: $(EXE)
	$(EXE) --table

clean:
	rm -rf obj_dir cycles_6800.h m6800_pad_table.vh

.PHONY: all run table clean
