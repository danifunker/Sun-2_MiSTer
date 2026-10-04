//============================================================================
//  tb_mister_bell -- rtl/sun2_mister_bell.sv on a 24.576 MHz CLK_AUDIO, its
//  `beeper' driven from an unrelated 20 MHz clock as cpu_clk drives it.
//
//  Checked: silence is exactly zero, before, between and after beeps, at
//  every volume and whichever half of the wave a beep ends in; the tone is the
//  keyboard's 480 us period; each volume's level, and Off is silent with the
//  beeper on; the wave is softened (no edge faster than the filter allows, at
//  the framework's 48 kHz as well as per clock); every beep starts on the same
//  half; a 5 ms key click is about ten cycles of it.
//
//      make -C tb/verilator tb_mister_bell
//============================================================================
`timescale 1ps/1ps

module tb_mister_bell;

localparam int CLK_HZ = 24_576_000;
localparam int MS     = CLK_HZ / 1000;          // audio clocks in a millisecond

reg clk = 0;
always #20345 clk = ~clk;                       // 24.576 MHz
reg cpu_clk = 0;
always #25000 cpu_clk = ~cpu_clk;               // 20 MHz

reg        beeper = 0;
reg  [1:0] volume = 2'd0;
wire signed [15:0] sample;

sun2_mister_bell #(.CLK_HZ(CLK_HZ)) dut (.clk(clk), .beeper(beeper), .volume(volume), .sample(sample));

integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) passes++;
        else begin fails++; $display("FAIL  %s", what); end
        if (ok) $display("  ok  %s", what);
    end
endtask

task automatic set_beeper(input bit v);
    begin @(posedge cpu_clk); beeper <= v; end
endtask

function automatic int iabs(input int v);
    iabs = (v < 0) ? -v : v;
endfunction

// What the output does over `clocks' audio clocks.
int lo, hi, changes, first_change, last_change, max_step, max_step48, first;
task automatic watch(input int clocks);
    int prev, prev48, s, sgn;
    begin
        lo = 0; hi = 0; changes = 0; first_change = -1; last_change = -1;
        max_step = 0; max_step48 = 0; first = 0;
        prev = sample; prev48 = sample; sgn = 0;
        for (int i = 0; i < clocks; i++) begin
            @(posedge clk); #1;
            s = sample;
            if (s < lo) lo = s;
            if (s > hi) hi = s;
            if (first == 0 && s != 0) first = s;
            if (iabs(s - prev) > max_step) max_step = iabs(s - prev);
            if (i % 512 == 0) begin                 // audio_out's 48 kHz
                if (iabs(s - prev48) > max_step48) max_step48 = iabs(s - prev48);
                prev48 = s;
            end
            if ((s > 0 && sgn < 0) || (s < 0 && sgn > 0)) begin
                changes++;
                if (first_change < 0) first_change = i;
                last_change = i;
            end
            if (s != 0) sgn = (s > 0) ? 1 : -1;
            prev = s;
        end
    end
endtask

// Silent for `clocks': every sample exactly zero.
task automatic silent(input int clocks, input string what);
    begin
        watch(clocks);
        check(lo == 0 && hi == 0, $sformatf("%s (range %0d..%0d)", what, lo, hi));
    end
endtask

initial begin
    int amp [4];
    string name [4];
    amp  = '{6000, 16000, 2000, 0};
    name = '{"Normal", "Loud", "Quiet", "Off"};

    $display("tb_mister_bell: sun2_mister_bell on a 24.576 MHz audio clock");
    silent(2 * MS, "silent from power-up");

    for (int v = 0; v < 3; v++) begin
        volume = v[1:0];
        repeat (8) @(posedge clk);
        set_beeper(1);
        watch(1 * MS);
        check(first > 0, $sformatf("%s: the beep starts on its positive half (first sample %0d)", name[v], first));
        watch(25 * MS);
        begin
            real period_us;
            period_us = 2.0 * (last_change - first_change) / (changes - 1) * 1.0e6 / CLK_HZ;
            check(period_us > 478.0 && period_us < 482.0,
                  $sformatf("%s: the period is the keyboard's 480 us (%.2f us, %0d zero crossings)",
                            name[v], period_us, changes));
        end
        check(hi >= amp[v] * 95 / 100 && hi <= amp[v] && lo <= -amp[v] * 95 / 100 && lo >= -amp[v],
              $sformatf("%s: peaks at +-%0d (%0d..%0d)", name[v], amp[v], lo, hi));
        check(max_step <= 2 * amp[v] / 1024 + 1,
              $sformatf("%s: softened -- no step over %0d a clock (worst %0d)", name[v], 2 * amp[v] / 1024 + 1, max_step));
        check(max_step48 < amp[v],
              $sformatf("%s: ... nor over %0d between 48 kHz samples, where a square wave steps %0d (worst %0d)",
                        name[v], amp[v], 2 * amp[v], max_step48));
        set_beeper(0);
        repeat (MS) @(posedge clk);
        silent(2 * MS, $sformatf("%s: exactly silent within 1 ms of the beeper stopping", name[v]));
    end

    // Ending on the negative half: the decay comes up from below, where the
    // filter's floor would leave it one short of zero.
    volume = 2'd0;
    set_beeper(1);
    repeat (360 * MS / 1000) @(posedge clk);       // 360 us: a quarter into the second half
    check(sample < -1000, $sformatf("a beep stopped 360 us in is on its negative half (%0d)", sample));
    set_beeper(0);
    repeat (MS) @(posedge clk);
    silent(2 * MS, "... and decays to exactly zero from below");

    // The next beep still starts positive.
    set_beeper(1);
    watch(MS / 2);
    check(first > 0, $sformatf("the beep after it starts on the positive half again (first sample %0d)", first));
    set_beeper(0);
    repeat (2 * MS) @(posedge clk);

    // A key click: 5 ms of the tone.
    fork
        begin set_beeper(1); repeat (100_000) @(posedge cpu_clk); set_beeper(0); end
        watch(7 * MS);
    join
    check(changes >= 19 && changes <= 21,
          $sformatf("a 5 ms click is about ten cycles of the tone (%0d zero crossings)", changes));
    silent(MS, "... and is over after it");

    // Off: the beeper on, and nothing.
    volume = 2'd3;
    repeat (8) @(posedge clk);
    set_beeper(1);
    silent(5 * MS, "Off: silent with the beeper sounding");
    set_beeper(0);

    $display("");
    $display("tb_mister_bell: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
