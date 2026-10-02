// Simulation stand-ins for rtl/pll.v and rtl/pll_serial.v (altera_pll is not
// simulable here): the same ports and the same frequencies, including the CPU
// clock's 52/48 split, from the same reset-free start.  The clocks are not
// phase-related the way the PLL's are -- the design treats every crossing as
// asynchronous, so the simulation should too.
`timescale 1ps/1ps

module pll (
    input  wire refclk,
    input  wire rst,
    output reg  outclk_0 = 1'b0,    // 100.000 MHz
    output reg  outclk_1 = 1'b0,    //  20.000 MHz, 52% high
    output reg  outclk_2 = 1'b0,    //  83.333 MHz
    output reg  outclk_3 = 1'b0,    //  25.000 MHz
    output reg  locked   = 1'b0
);
    always #5000 outclk_0 = ~outclk_0;
    always begin outclk_1 = 1'b1; #26000; outclk_1 = 1'b0; #24000; end
    always #6000 outclk_2 = ~outclk_2;
    always #20000 outclk_3 = ~outclk_3;
    initial #1_000_000 locked = 1'b1;   // 1 us
endmodule

module pll_serial (
    input  wire refclk,
    input  wire rst,
    output reg  outclk_0 = 1'b0,    // 4.9152 MHz
    output reg  locked   = 1'b0
);
    always #101725 outclk_0 = ~outclk_0;
    initial #1_000_000 locked = 1'b1;
endmodule
