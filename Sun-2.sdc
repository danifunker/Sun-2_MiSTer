derive_pll_clocks
derive_clock_uncertainty

# core specific constraints
#
# TODO, with the PLL rework: the core's clocks (cpu_clk, the memory clock, the
# pixel clock and the 4.9152 MHz serial clock) cross only through synchronisers
# and the FIFO bridge's async FIFOs, and need set_clock_groups once the PLLs
# are IP-generated and their clock names are known.  The constraints the first
# draft carried here matched no clock (`*|pll|*|divclk*`) or duplicated
# sys/sys_top.sdc, and are gone.
