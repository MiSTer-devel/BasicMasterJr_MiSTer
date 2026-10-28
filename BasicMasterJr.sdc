# Core-specific CDC constraints. The master MiSTer SDC creates the clocks and
# clock groups; these paths end only at the first flip-flop of explicit
# two-stage synchronizers.
set clk_system [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0].gpll~PLL_OUTPUT_COUNTER|divclk}]
set clk_video  [get_clocks {emu|pll|pll_inst|altera_pll_i|general[1].gpll~PLL_OUTPUT_COUNTER|divclk}]
set_clock_groups -asynchronous -group $clk_system -group $clk_video

set_false_path -to {*|core:core|vs_meta}
set_false_path -to {*|core:core|video:video|mix_phase_meta}
set_false_path -to {*|core:core|video:video|blink_meta}
set_false_path -to {*|core:core|video:video|border_color_meta[*]}
