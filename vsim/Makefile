V = verilator

TOP   = --top-module emu
RTL   = ../rtl
V_INC =

# NOTE: no -I/-y search path on purpose. Every source is listed explicitly in
# V_SRC below, and vsim/rtl/dpram.v must shadow the Quartus megafunction
# version in ../rtl. Adding ../rtl to the search path can also
# make Verilator auto-load modules outside this explicit source list.
#
# PINMISSING is expected: core.v deliberately leaves video.v's hcount/vcount/
# frame outputs unconnected. UNSIGNED is expected when VIDEO_BORDER=0 makes
# lower-bound comparisons against constant zero tautological.
# +incdir+ only (NOT -I): m6800_pad.v needs to find m6800_pad_table.vh, but
# -I would also put ../rtl on the module search path and bypass that override.
V_DEFINE = +define+SIMULATION=1 +incdir+$(RTL) \
	-CFLAGS "-I../sim/imgui -I../sim/vinc -I../sim/ -g" \
	--timescale-override 1ps/1ps \
	-Wno-TIMESCALEMOD -Wno-PINMISSING -Wno-UNSIGNED -Wno-fatal

# System timebase. 25 MHz (default) is fastest; 50 MHz is the hardware's and the
# only one that can run its 32x tape turbo (see sim.v). Switching rebuilds.
SIM_HZ ?= 25000000
V_DEFINE += +define+SIM_CLK_HZ=$(SIM_HZ)
CXX_DEFINE += -DSIM_CLK_HZ=$(SIM_HZ)u
SIM_HZ_STAMP = obj_dir/sim_hz_$(SIM_HZ)

# VCD tracing costs runtime even when idle; opt in with `make TRACE=1`.
ifeq ($(TRACE),1)
V_DEFINE += --trace
CXX_DEFINE += -DVM_TRACE_VCD=1
else
CXX_DEFINE += -DVM_TRACE_VCD=0
endif

UNAME_S := $(shell uname -s)

ifeq ($(UNAME_S), Darwin)
	LIBS += -framework OpenGL -framework Cocoa -framework IOKit -framework CoreVideo `sdl2-config --libs`
	LIBS += -L/usr/local/lib -L/opt/local/lib -L/opt/homebrew/lib
	CXXFLAGS += `sdl2-config --cflags`
	CXXFLAGS += `sdl2-config --cflags | sed 's|include/SDL2|include/|'`
	CXXFLAGS += -I/usr/local/include -I/opt/local/include -I/opt/homebrew/include
endif

ifeq ($(UNAME_S), Linux)
	LIBS += -lGL -ldl `sdl2-config --libs`
	CXXFLAGS += `sdl2-config --cflags`
endif

ifeq ($(findstring MINGW,$(UNAME_S)),MINGW)
	LIBS += -lgdi32 -lopengl32 -limm32 `pkg-config --static --libs sdl2`
	CXXFLAGS += `pkg-config --cflags sdl2`
endif

CC_OPT    = -O2
V_OPT     = -O3 --x-assign fast --x-initial fast --noassert
CXXFLAGS += $(CC_OPT) $(CXX_DEFINE) -Isim/imgui
LDFLAGS   = $(LIBS)
EXE       = ./obj_dir/Vemu

# rtl/dpram.v is the vsim override, NOT ../rtl/dpram.v
V_SRC = \
	sim.v \
	rtl/dpram.v \
	$(RTL)/core.v \
	$(RTL)/keyboard.v \
	$(RTL)/m6801.sv \
	$(RTL)/m6800_pad.v \
	$(RTL)/ram.v \
	$(RTL)/rom.v \
	$(RTL)/video.v \
	$(RTL)/x74138.v \
	$(RTL)/cassette_recorder.v \
	$(RTL)/cassette.v \
	$(RTL)/tape_speed.v \
	$(RTL)/tape_overlay.sv

C_SRC = \
	sim_main.cpp \
	sim/sim_bus.cpp sim/sim_clock.cpp sim/sim_console.cpp sim/sim_video.cpp \
	sim/sim_input.cpp sim/sim_audio.cpp sim/sim_blkdevice.cpp \
	sim/imgui/imgui_impl_sdl.cpp sim/imgui/imgui_impl_opengl2.cpp \
	sim/imgui/imgui_draw.cpp sim/imgui/imgui_widgets.cpp sim/imgui/imgui_tables.cpp \
	sim/imgui/imgui.cpp sim/imgui/ImGuiFileDialog.cpp \
	sim/imgui/implot.cpp sim/imgui/implot_items.cpp

VOUT = obj_dir/Vemu.cpp

# rom*.mem are opened by $readmemh relative to the working directory, so the
# sim has to be run from here. Symlink them in rather than duplicating.
MEMS = rom0.mem romb.mem romdf.mem rome.mem

all: $(MEMS) $(EXE)

$(MEMS):
	ln -sf $(RTL)/$@ $@

# A different SIM_HZ than the last build: regenerate everything (make doesn't
# notice changed flags by itself).
$(SIM_HZ_STAMP):
	rm -rf obj_dir
	mkdir -p obj_dir
	touch $@

$(VOUT): $(V_SRC) Makefile $(SIM_HZ_STAMP)
	$V -cc $(V_OPT) -LDFLAGS "$(LDFLAGS)" -exe --Mdir ./obj_dir \
		$(V_DEFINE) $(V_INC) $(TOP) -CFLAGS "$(CXXFLAGS)" $(V_SRC) $(C_SRC)

$(EXE): $(VOUT) $(C_SRC)
	(cd obj_dir; make -f Vemu.mk OBJCACHE= OPT_FAST="-O2" OPT_SLOW="-O0" OPT_GLOBAL="-O2")

recorder-test:
	iverilog -g2012 -Wall -s recorder_test -o /tmp/basicmaster_recorder_test $(RTL)/cassette_recorder.v recorder_test.sv
	vvp /tmp/basicmaster_recorder_test

clean:
	rm -rf obj_dir
	rm -f $(MEMS)

.PHONY: all clean recorder-test
