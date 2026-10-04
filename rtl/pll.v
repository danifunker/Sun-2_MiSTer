// The core's main PLL, in the layout sys/pll_q17.qip expects (rtl/pll.qip).
// Every output divides one 1000 MHz VCO (50 MHz x 20, no fractional part), so
// every frequency is exact:
//
//   outclk_0  100.000 MHz  /10  SDRAM, the memory side of the Wishbone bridge, hps_io
//   outclk_1   20.000 MHz  /50  cpu_clk, 52% high: the CPU core's critical path is
//                               rising edge to falling edge, so it gets the longer
//                               half (the DECA ran 53/47 for the same reason)
//   outclk_2   83.333 MHz  /12  pixel clock: 1152x900 in a 1472x937 raster, 60.4 Hz
//   outclk_3    2.500 MHz /400 MII clocks for the 82586: 10 Mb/s, its own speed, and
//                              the speed its receive FIFO and DVMA keep up with
//
// The 4.9152 MHz serial clock is not a divisor of anything here and has its own
// fractional PLL, rtl/pll_serial.v, as it did on the Wukong and the DECA.
module pll (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);
    pll_0002 pll_inst (
        .refclk   (refclk),
        .rst      (rst),
        .outclk_0 (outclk_0),
        .outclk_1 (outclk_1),
        .outclk_2 (outclk_2),
        .outclk_3 (outclk_3),
        .locked   (locked)
    );
endmodule
