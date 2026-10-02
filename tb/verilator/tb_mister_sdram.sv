//============================================================================
//  tb_mister_sdram -- rtl/sun2_mister_sdram.sv + rtl/sdram.sv against the
//  behavioural SDR SDRAM in sdram_model.sv.
//
//  The Wishbone master here behaves as sun2_cached_fifo_bridge does: CYC held
//  until it samples ACK, dropped on that edge, and a new request started on
//  the very next clock.  That back-to-back restart is the timing at which the
//  first-draft adapter ran a request twice and answered the next one with the
//  previous address's data, so every access below is made at it.  The frame
//  buffer reader behaves as fb_scanout does: c_req held for a line, c_addr
//  advanced on the edge it samples c_done.
//
//  Checked: every halfword and byte lane against a shadow; whole 128-bit
//  lines, since the cache installs them; the in-chip layout (line halfword k
//  is SDRAM word k, A1=0 is the even word), because a consistent swap would
//  round-trip and still be wrong for fb_scanout; scan-out beats while the CPU
//  is busy; beat counts (no repeats, none lost); and the chip model's own
//  protocol checks and refresh spacing.
//
//      make -C tb/verilator tb_mister_sdram
//============================================================================
`timescale 1ps/1ps

module tb_mister_sdram;

localparam integer TH = 5000;                  // 100 MHz
localparam [29:0]  FB_WB_BASE    = 30'h03E00000;
localparam [25:0]  FB_SDRAM_WORD = 26'h0800000;

reg clk = 0;
always #TH clk = ~clk;
reg init = 1;

// ---- DUT --------------------------------------------------------------------
reg         cyc = 0, we = 0;
reg  [29:0] adr = 0;
reg  [31:0] dat = 0;
reg   [3:0] sel = 0;
wire [31:0] rdat;
wire        ack;
wire [127:0] line;

reg  [27:0] fb_addr = 0;
reg         fb_req  = 0;
wire        fb_done;
wire [127:0] fb_rdata;

wire [15:0] SDRAM_DQ;
wire [12:0] SDRAM_A;
wire        SDRAM_DQML, SDRAM_DQMH;
wire  [1:0] SDRAM_BA;
wire        SDRAM_nCS, SDRAM_nWE, SDRAM_nRAS, SDRAM_nCAS, SDRAM_CKE, SDRAM_CLK;

sun2_mister_sdram #(.FB_WB_BASE(FB_WB_BASE), .FB_SDRAM_WORD(FB_SDRAM_WORD)) dut (
    .clk(clk), .init(init),
    .wb_cyc_i(cyc), .wb_stb_i(cyc), .wb_adr_i(adr), .wb_dat_i(dat), .wb_sel_i(sel),
    .wb_we_i(we), .wb_dat_o(rdat), .wb_ack_o(ack), .wb_line_o(line),
    .fb_c_addr(fb_addr), .fb_c_req(fb_req), .fb_c_done(fb_done), .fb_c_rdata(fb_rdata),
    .SDRAM_DQ(SDRAM_DQ), .SDRAM_A(SDRAM_A), .SDRAM_DQML(SDRAM_DQML), .SDRAM_DQMH(SDRAM_DQMH),
    .SDRAM_BA(SDRAM_BA), .SDRAM_nCS(SDRAM_nCS), .SDRAM_nWE(SDRAM_nWE),
    .SDRAM_nRAS(SDRAM_nRAS), .SDRAM_nCAS(SDRAM_nCAS), .SDRAM_CKE(SDRAM_CKE),
    .SDRAM_CLK(SDRAM_CLK)
);

sdram_model chip (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML),
    .dq(SDRAM_DQ)
);

// ---- results -----------------------------------------------------------------
integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) passes = passes + 1;
        else begin
            fails = fails + 1;
            $display("FAIL  %s", what);
        end
    end
endtask

// ---- the bridge-like Wishbone master ---------------------------------------------
reg         req_t = 0, seen_t = 0, done_t = 0;
reg         go_we;
reg  [29:0] go_adr;
reg  [31:0] go_dat;
reg   [3:0] go_sel;
reg  [31:0] res_dat;
reg [127:0] res_line;
integer     wb_acks = 0;

always @(posedge clk) begin
    if (!cyc && req_t != seen_t) begin
        seen_t <= req_t;
        cyc <= 1; we <= go_we; adr <= go_adr; dat <= go_dat; sel <= go_sel;
    end else if (cyc && ack) begin
        cyc      <= 0;
        res_dat  <= rdat;
        res_line <= line;
        done_t   <= ~done_t;
        wb_acks  <= wb_acks + 1;
    end
end

task automatic wb(input bit w, input [29:0] a, input [31:0] d, input [3:0] s);
    reg t0;
    begin
        @(negedge clk);
        t0 = done_t;
        go_we = w; go_adr = a; go_dat = d; go_sel = s;
        req_t = ~req_t;
        do @(negedge clk); while (done_t == t0);
    end
endtask

// ---- shadows: halfword index = Wishbone word * 2 + A1 -------------------------------
bit [15:0] mm [int];            // main memory
bit [15:0] fbm [int];           // frame buffer aperture, relative halfwords
bit  [1:0] mmk [int], fbk [int]; // which bytes of each are known: [1] high, [0] low

function automatic [15:0] mm_get(input int h);
    mm_get = mm.exists(h) ? mm[h] : 16'h0000;
endfunction

task automatic shadow_write(input [29:0] a, input [31:0] d, input [3:0] s);
    int h;
    bit [15:0] v;
    bit is_fb;
    begin
        is_fb = (a >= FB_WB_BASE);
        h = is_fb ? int'((a - FB_WB_BASE) * 2) : int'(a * 2);
        for (int half = 0; half < 2; half++) begin
            if (is_fb) v = fbm.exists(h + half) ? fbm[h + half] : 16'h0;
            else       v = mm_get(h + half);
            if (s[half*2 + 1]) v[15:8] = d[half*16 + 8 +: 8];
            if (s[half*2])     v[7:0]  = d[half*16 +: 8];
            if (s[half*2 +: 2] != 0) begin
                if (is_fb) begin
                    fbm[h + half] = v;
                    fbk[h + half] = (fbk.exists(h + half) ? fbk[h + half] : 2'b00) | s[half*2 +: 2];
                end else begin
                    mm[h + half]  = v;
                    mmk[h + half] = (mmk.exists(h + half) ? mmk[h + half] : 2'b00) | s[half*2 +: 2];
                end
            end
        end
    end
endtask

task automatic wwrite(input [29:0] a, input [31:0] d, input [3:0] s);
    begin
        wb(1, a, d, s);
        shadow_write(a, d, s);
    end
endtask

// Read word a; check the 32-bit answer and the whole line it came with.
// Bytes nothing has written are don't-care: the chip powers up with
// whatever it likes in them (the model says 0xFFFF).
task automatic wread_check(input [29:0] a, input string what);
    bit [127:0] exp_line, care;
    int base, h;
    bit [1:0] known;
    begin
        wb(0, a, 32'h0, 4'hF);
        base = int'({a[29:2], 2'b00}) * 2;
        for (int k = 0; k < 8; k++) begin
            if (a >= FB_WB_BASE) begin
                h = base - int'(FB_WB_BASE * 2) + k;
                known = fbk.exists(h) ? fbk[h] : 2'b00;
                exp_line[16*k +: 16] = known ? fbm[h] : 16'h0;
            end else begin
                known = mmk.exists(base + k) ? mmk[base + k] : 2'b00;
                exp_line[16*k +: 16] = mm_get(base + k);
            end
            care[16*k +: 16] = {{8{known[1]}}, {8{known[0]}}};
        end
        check(((res_dat ^ exp_line[32*a[1:0] +: 32]) & care[32*a[1:0] +: 32]) == 0,
              $sformatf("%s: word 0x%07x read %08x, expected %08x (mask %08x)", what, a, res_dat,
                        exp_line[32*a[1:0] +: 32], care[32*a[1:0] +: 32]));
        check(((res_line ^ exp_line) & care) == 0,
              $sformatf("%s: line of 0x%07x read %032x, expected %032x (mask %032x)", what, a,
                        res_line, exp_line, care));
    end
endtask

// The chip cell holding SDRAM word w, by sdram.sv's own decode.
function automatic [15:0] chip_cell(input [25:0] w);
    int k;
    begin
        k = chip.key(w[23:22], w[21:9], {w[24], w[8:0]});
        chip_cell = chip.mem.exists(k) ? chip.mem[k] : 16'hDEAD;
    end
endfunction

// ---- the fb_scanout-like reader --------------------------------------------------
reg         fb_t = 0, fb_seen = 0;
integer     fb_left = 0, fb_n = 0;
reg  [27:0] fb_start = 0;
reg [127:0] fb_got [0:255];
integer     fb_dones = 0;

always @(posedge clk) begin
    if (!fb_req && fb_t != fb_seen) begin
        fb_seen <= fb_t;
        fb_addr <= fb_start;
        fb_req  <= 1;
        fb_left <= fb_n;
    end else if (fb_req && fb_done) begin
        fb_got[fb_dones] <= fb_rdata;
        fb_dones <= fb_dones + 1;
        fb_addr  <= fb_addr + 28'd8;
        if (fb_left == 1) fb_req <= 0;
        fb_left  <= fb_left - 1;
    end
end

task automatic fb_fetch(input [27:0] start, input integer n);
    begin
        @(negedge clk);
        fb_dones = 0;
        fb_start = start; fb_n = n;
        fb_t = ~fb_t;
    end
endtask

task automatic fb_wait;
    begin
        do @(negedge clk); while (fb_req || fb_t != fb_seen);
    end
endtask

task automatic fb_check(input [27:0] start, input integer n, input string what);
    bit [127:0] e;
    begin
        check(fb_dones == n, $sformatf("%s: %0d beats answered for %0d asked", what, fb_dones, n));
        for (int b = 0; b < n; b++) begin
            for (int k = 0; k < 8; k++) begin
                int q;
                q = int'(start) + b*8 + k;
                e[16*k +: 16] = fbm.exists(q) ? fbm[q] : 16'h0;
            end
            check(fb_got[b] == e, $sformatf("%s: beat %0d read %032x, expected %032x", what, b, fb_got[b], e));
        end
    end
endtask

// ---- the sequence --------------------------------------------------------------
int unsigned seed = 32'h5EED_0001;
function automatic [31:0] rnd;
    seed = seed * 32'd1664525 + 32'd1013904223;
    rnd = seed;
endfunction

initial begin
    $display("tb_mister_sdram: sun2_mister_sdram + sdram.sv against a chip model");
    repeat (4) @(posedge clk);
    init <= 0;
    repeat (13000) @(posedge clk);       // the controller's ~12100-clock power-up

    check(chip.mode_set, "the mode register was loaded");
    check(chip.cl == 3'd2 && chip.bl == 8, "CAS latency 2, burst length 8");

    // 1. halfwords, each half separately, as the 68010 writes them
    for (int i = 0; i < 64; i++) begin
        wwrite(30'h0000100 + i, 32'h0000_0000 | (16'hA000 + i), 4'b0011);
        wwrite(30'h0000100 + i, (32'hB000 + i) << 16,           4'b1100);
    end
    for (int i = 0; i < 64; i++) wread_check(30'h0000100 + i, "halfwords");

    // 2. the in-chip layout: line halfword k is SDRAM word k, A1=0 the even one
    check(chip_cell(26'h0000200) == 16'hA000, "Wishbone word 0x100, A1=0 half, is SDRAM word 0x200");
    check(chip_cell(26'h0000201) == 16'hB000, "Wishbone word 0x100, A1=1 half, is SDRAM word 0x201");
    check(chip_cell(26'h0000207) == 16'hB003, "Wishbone word 0x103, A1=1 half, is SDRAM word 0x207");

    // 3. byte lanes merge
    wwrite(30'h0000100, 32'h0000_00C1, 4'b0001);
    wwrite(30'h0000100, 32'h0000_C200, 4'b0010);
    wwrite(30'h0000101, 32'h00C3_0000, 4'b0100);
    wwrite(30'h0000101, 32'hC400_0000, 4'b1000);
    wread_check(30'h0000100, "byte lanes");
    wread_check(30'h0000101, "byte lanes");
    // a write with no lane selected changes nothing and is still answered
    wwrite(30'h0000100, 32'hFFFF_FFFF, 4'b0000);
    wread_check(30'h0000100, "empty write");

    // 4. row and bank conflicts: the same bank, other rows, alternately
    for (int i = 0; i < 16; i++) begin
        wwrite(30'h0000400 + i * 30'h40000, 32'h1111_0000 + i, 4'b0011);
        wwrite(30'h0000400 + i * 30'h40000, (32'h2222 + i) << 16, 4'b1100);
    end
    for (int i = 15; i >= 0; i--) wread_check(30'h0000400 + i * 30'h40000, "row conflicts");

    // 5. back to back, different lines: the answer must be the new address's
    wwrite(30'h0000800, 32'h0000_1234, 4'b0011);
    wwrite(30'h0000900, 32'h0000_5678, 4'b0011);
    for (int i = 0; i < 8; i++) begin
        wread_check(30'h0000800, "back to back A");
        wread_check(30'h0000900, "back to back B");
    end

    // 6. the frame buffer through Wishbone, read back by the scan-out port
    for (int r = 0; r < 72; r++) begin            // two scan lines' worth of words
        wwrite(FB_WB_BASE + r, 32'h0000_F000 + r * 2, 4'b0011);
        wwrite(FB_WB_BASE + r, (32'hF000 + r * 2 + 1) << 16, 4'b1100);
    end
    fb_fetch(28'd0, 18);
    fb_wait();
    fb_check(28'd0, 18, "scan-out alone");
    wread_check(FB_WB_BASE + 5, "frame buffer via Wishbone");

    // 7. scan-out and CPU traffic at once
    fb_fetch(28'd0, 18);
    for (int i = 0; i < 40; i++) begin
        wwrite(30'h0001000 + i, rnd(), 4'b0011);
        wread_check(30'h0000100 + (i % 64), "CPU during scan-out");
    end
    fb_wait();
    fb_check(28'd0, 18, "scan-out during CPU traffic");

    // 8. random traffic across 8 MiB, long enough for a few hundred refreshes
    for (int i = 0; i < 3000; i++) begin
        bit [29:0] a;
        bit [31:0] r;
        r = rnd();
        a = {9'd0, r[20:0]};                     // anywhere in the 8 MiB
        case (r[23:22])
            2'd0: wwrite(a, rnd(), 4'b0011);
            2'd1: wwrite(a, rnd(), 4'b1100);
            2'd2: wwrite(a, rnd(), {2'b00, r[25:24] == 0 ? 2'b01 : r[25:24]});
            2'd3: wread_check(a, "random");
        endcase
        if (i % 500 == 0) fb_fetch(28'd0, 9);
    end
    fb_wait();
    // read back everything the random phase wrote
    foreach (mm[h]) wread_check(30'(h / 2), "final sweep");

    check(chip.errors == 0, $sformatf("chip protocol: %0d violations", chip.errors));
    check(chip.max_refresh_gap > 0 && chip.max_refresh_gap <= 780,
          $sformatf("refresh: longest gap %0d clocks, limit 780 (7.8 us)", chip.max_refresh_gap));

    $display("");
    $display("tb_mister_sdram: %0d checks, %0d failed, %0d Wishbone answers", passes + fails, fails, wb_acks);
    chip.report_timing();
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #(64'd500_000_000_000);                      // 500 ms of simulated time
    $display("FAIL  timeout");
    $finish;
end

endmodule
