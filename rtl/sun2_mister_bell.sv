//
// sun2_mister_bell.sv
//
// The Sun keyboard's beeper, as sound on MiSTer's audio path.
//
// A Sun keyboard has one small speaker, driven at a 480 us period -- about
// 2083 Hz -- for as long as the host keeps the bell on, or for 5 ms on each
// key when the click is enabled.  Which of those is happening is the
// keyboard's business (rtl/sun2_mister_kbd_mouse.sv); its `beeper' output is
// this module's input, and here it becomes a square wave at that period.
//
// The square wave goes through a one-pole low-pass filter at about 3.8 kHz.
// It takes the edge off the harmonics -- the real thing is a small speaker in
// a plastic case, not an ideal square wave into a hi-fi -- and it turns the
// start and the end of every beep into a ramp, so neither cracks.  The tone
// starts at the same phase every time, so every key click sounds alike.
//
// Everything runs on CLK_AUDIO, the clock audio_out samples AUDIO_L/R with, so
// the samples cross nothing.  What does cross: `beeper', one level from
// cpu_clk, through two flops; and `volume', two bits from hps_io's clock,
// taken only once two samples agree.
//
// volume: 0 normal, 1 loud, 2 quiet, 3 off -- the OSD's order, default first.
//
`timescale 1ns / 1ps

module sun2_mister_bell #(
    parameter int CLK_HZ = 24_576_000,
    parameter int K      = 10           // the filter: fc = CLK_HZ / (2 pi 2^K), 3.8 kHz here
) (
    input  wire               clk,      // CLK_AUDIO
    input  wire               beeper,   // asynchronous
    input  wire [1:0]         volume,   // asynchronous
    output wire signed [15:0] sample    // signed (AUDIO_S = 1)
);

    localparam int HALF = (CLK_HZ / 1000) * 240 / 1000;   // 240 us, half of the 480 us period
    localparam int W    = 16 + 1 + K;                     // the filter's state, K bits of fraction

    // ---- the crossings ----------------------------------------------------------
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] on_s = 2'b00;
    always @(posedge clk) on_s <= {on_s[0], beeper};
    wire on = on_s[1];

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] vol_s1 = 2'd0;
    reg [1:0] vol_s2 = 2'd0, vol = 2'd0;
    always @(posedge clk) begin
        vol_s1 <= volume;
        vol_s2 <= vol_s1;
        if (vol_s2 == vol_s1) vol <= vol_s2;
    end

    wire signed [15:0] amp = (vol == 2'd0) ? 16'sd6000  :
                             (vol == 2'd1) ? 16'sd16000 :
                             (vol == 2'd2) ? 16'sd2000  : 16'sd0;

    // ---- the tone -----------------------------------------------------------------
    reg [$clog2(HALF) - 1:0] cnt  = '0;
    reg                      high = 1'b1;

    always @(posedge clk) begin
        if (!on) begin
            cnt  <= '0;
            high <= 1'b1;                   // every beep starts on the same half
        end else if (cnt == HALF - 1) begin
            cnt  <= '0;
            high <= ~high;
        end else
            cnt  <= cnt + 1'd1;
    end

    wire signed [15:0] x = !on ? 16'sd0 : high ? amp : -amp;

    // ---- the filter: acc += (x - acc) / 2^K, every clock ---------------------------
    reg  signed [W-1:0] acc = '0;
    wire signed [W-1:0] target = {x[15], x, {K{1'b0}}};
    wire signed [W-1:0] step   = (target - acc) >>> K;

    always @(posedge clk) begin
        // The shift floors, so a decay towards zero from below stops a fraction
        // short of it and would leave the output at -1 for ever.  Silence is
        // exactly zero.
        if (!on && &acc[W-1:K])
            acc <= '0;
        else
            acc <= acc + step;
    end

    assign sample = acc[K +: 16];

endmodule
