// The serial clock: 4.9152 MHz for both Z8530s, the Am9513 and the MM58167,
// on a PLL of its own because it divides nothing the main PLL makes.  A
// fractional VCO gets within a part per million of it; the SCCs' baud rate
// generators need it to within a few percent, and the Am9513 is the machine's
// clock, so closer is better.
module pll_serial (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire locked
);
    pll_serial_0002 pll_inst (
        .refclk   (refclk),
        .rst      (rst),
        .outclk_0 (outclk_0),
        .locked   (locked)
    );
endmodule
