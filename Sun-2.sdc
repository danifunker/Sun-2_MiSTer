# Timing constraints for Sun-2 MiSTer core
# (Read after sys/sys_top.sdc)

# Base clocks are derived by altera_pll instances and constrained by derive_pll_clocks
derive_pll_clocks
derive_clock_uncertainty

# False paths for asynchronous control signals and resets
set_false_path -from [get_ports {KEY[*]}]
set_false_path -from [get_ports {SW[*]}]
set_false_path -from [get_ports {BTN_* &}]
set_false_path -to   [get_ports {LED[*]}]
set_false_path -to   [get_ports {LED_* &}]

# SDRAM I/O constraints
set_multicycle_path -from [get_clocks {*|pll|*|divclk*}] -to [get_ports {SDRAM_* &}] -setup 1
set_multicycle_path -from [get_clocks {*|pll|*|divclk*}] -to [get_ports {SDRAM_* &}] -hold 0
