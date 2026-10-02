derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# Every clock this core makes comes from CLK_50M, so TimeQuest would time
# paths between them as related.  None is: each crossing is designed as an
# asynchronous one and goes through synchronisers or a dual-clock RAM --
#
#   cpu_clk <-> clk_mem   sun2_cached_fifo_bridge's two async FIFOs; the disk
#                         bridge's toggles and staging RAMs; ps2_key/ps2_mouse
#                         toggles; the boot PROM's write port (the machine is
#                         held in reset while it is written)
#   clk_mem <-> clk_pix   fb_scanout's toggles and line buffer
#   clk_mii               the 82586's MII side, asynchronous by design
#   clk_ser               the SCCs, Am9513 and MM58167, sampled into cpu_clk
#                         through two flops (ttl_am9513.v, mm58167.v)
#
# so they are cut here.  rtl/pll/pll_0002.v's outputs are general[0..3] in
# outclk order: clk_mem, cpu_clk, clk_pix, clk_mii.
set pll_main   {*|pll|pll_inst|altera_pll_i|general}
set pll_serial {*|pll_serial|pll_inst|altera_pll_i|general}

set_clock_groups -asynchronous \
    -group [get_clocks "${pll_main}\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    -group [get_clocks "${pll_main}\[1\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    -group [get_clocks "${pll_main}\[2\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    -group [get_clocks "${pll_main}\[3\].gpll~PLL_OUTPUT_COUNTER|divclk"] \
    -group [get_clocks "${pll_serial}\[0\].gpll~PLL_OUTPUT_COUNTER|divclk"]
