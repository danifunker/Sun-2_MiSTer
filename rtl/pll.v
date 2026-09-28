`timescale 1ns / 10ps

module pll (
    input  wire refclk,   // 50.0 MHz input
    input  wire rst,
    output wire outclk_0, // 108.000000 MHz (pixel)
    output wire outclk_1, // 64.000000 MHz (SDRAM memory)
    output wire outclk_2, // 40.000000 MHz (system / timer)
    output wire outclk_3, // 16.666667 MHz (CPU clock)
    output wire outclk_4, // 4.915200 MHz (SCC serial baud clock)
    output wire locked
);

`ifdef SIMULATION
    reg c0 = 0, c1 = 0, c2 = 0, c3 = 0, c4 = 0;
    always #4.62963   c0 = ~c0; // 108 MHz
    always #7.81250   c1 = ~c1; // 64 MHz
    always #12.5000   c2 = ~c2; // 40 MHz
    always #30.0000   c3 = ~c3; // 16.667 MHz
    always #101.725   c4 = ~c4; // 4.9152 MHz

    assign outclk_0 = c0;
    assign outclk_1 = c1;
    assign outclk_2 = c2;
    assign outclk_3 = c3;
    assign outclk_4 = c4;
    assign locked   = ~rst;
`else
    altera_pll #(
        .fractional_vco_multiplier("true"),
        .reference_clock_frequency("50.0 MHz"),
        .operation_mode("direct"),
        .number_of_clocks(5),
        .output_clock_frequency0("108.000000 MHz"),
        .phase_shift0("0 ps"),
        .duty_cycle0(50),
        .output_clock_frequency1("64.000000 MHz"),
        .phase_shift1("0 ps"),
        .duty_cycle1(50),
        .output_clock_frequency2("40.000000 MHz"),
        .phase_shift2("0 ps"),
        .duty_cycle2(50),
        .output_clock_frequency3("16.666667 MHz"),
        .phase_shift3("0 ps"),
        .duty_cycle3(50),
        .output_clock_frequency4("4.915200 MHz"),
        .phase_shift4("0 ps"),
        .duty_cycle4(50),
        .output_clock_frequency5("0 MHz"),
        .phase_shift5("0 ps"),
        .duty_cycle5(50),
        .output_clock_frequency6("0 MHz"),
        .phase_shift6("0 ps"),
        .duty_cycle6(50),
        .output_clock_frequency7("0 MHz"),
        .phase_shift7("0 ps"),
        .duty_cycle7(50),
        .output_clock_frequency8("0 MHz"),
        .phase_shift8("0 ps"),
        .duty_cycle8(50),
        .output_clock_frequency9("0 MHz"),
        .phase_shift9("0 ps"),
        .duty_cycle9(50),
        .output_clock_frequency10("0 MHz"),
        .phase_shift10("0 ps"),
        .duty_cycle10(50),
        .output_clock_frequency11("0 MHz"),
        .phase_shift11("0 ps"),
        .duty_cycle11(50),
        .output_clock_frequency12("0 MHz"),
        .phase_shift12("0 ps"),
        .duty_cycle12(50),
        .output_clock_frequency13("0 MHz"),
        .phase_shift13("0 ps"),
        .duty_cycle13(50),
        .output_clock_frequency14("0 MHz"),
        .phase_shift14("0 ps"),
        .duty_cycle14(50),
        .output_clock_frequency15("0 MHz"),
        .phase_shift15("0 ps"),
        .duty_cycle15(50),
        .output_clock_frequency16("0 MHz"),
        .phase_shift16("0 ps"),
        .duty_cycle16(50),
        .output_clock_frequency17("0 MHz"),
        .phase_shift17("0 ps"),
        .duty_cycle17(50),
        .pll_type("General"),
        .pll_subtype("General")
    ) altera_pll_i (
        .rst        (rst),
        .outclk     ({outclk_4, outclk_3, outclk_2, outclk_1, outclk_0}),
        .locked     (locked),
        .fboutclk   (),
        .fbclk      (1'b0),
        .refclk     (refclk)
    );
`endif

endmodule
