`timescale 1ns/10ps
module pll_0002 (
    input  wire refclk,
    input  wire rst,
    output wire outclk_0,
    output wire outclk_1,
    output wire outclk_2,
    output wire outclk_3,
    output wire locked
);
    altera_pll #(
        .fractional_vco_multiplier("false"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(4),
        .output_clock_frequency0("100.000000 MHz"), .phase_shift0("0 ps"), .duty_cycle0(50),
        .output_clock_frequency1("20.000000 MHz"),  .phase_shift1("0 ps"), .duty_cycle1(52),
        .output_clock_frequency2("83.333333 MHz"),  .phase_shift2("0 ps"), .duty_cycle2(50),
        .output_clock_frequency3("2.500000 MHz"),  .phase_shift3("0 ps"), .duty_cycle3(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst     (rst),
        .outclk  ({outclk_3, outclk_2, outclk_1, outclk_0}),
        .locked  (locked),
        .fboutclk(),
        .fbclk   (1'b0),
        .refclk  (refclk)
    );
endmodule
