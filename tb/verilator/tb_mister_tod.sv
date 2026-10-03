//============================================================================
//  tb_mister_tod -- rtl/sun2_mister_tod.sv into rtl/sun2-common/mm58167.v,
//  checked the way SunOS 4 will read it.
//
//  For each local time Main might send in hps_io's RTC: the converter's
//  output against a model of sundev/tod.c's todset() at that time less 36
//  years; the chip read back over its own bus and turned into a time by
//  todget() with a root file system written recently -- which must give that
//  time back; and the calendar date SunOS will print against MiSTer's, which
//  must agree in month, day and time of day.  Also: a load that arrives while
//  the chip is still in its power-on reset is applied when the reset ends;
//  only the first update loads; and a clock outside 2006..2069 (MiSTer with no
//  time set reads 1970) loads nothing.
//
//      make -C tb/verilator tb_mister_tod
//============================================================================
`timescale 1ns/1ps

module tb_mister_tod;

reg clk = 0, x2 = 0;
always #25       clk = ~clk;                // cpu_clk, 20 MHz
always #101.7253 x2  = ~x2;                 // 4.9152 MHz

reg  [64:0] rtc = 65'd0;
wire        ld, ld1;
wire [47:0] tod, tod1;
reg         reset_n = 0;

// ONCE off, so one instance can be loaded case after case; the chip follows it
sun2_mister_tod #(.ONCE(1'b0)) dut (.clk(clk), .rtc(rtc), .ld(ld), .tod(tod));
// as built: only the first update
sun2_mister_tod once (.clk(clk), .rtc(rtc), .ld(ld1), .tod(tod1));

reg        rd_n = 1;
reg  [4:0] addr = 0;
wire [7:0] dout;
mm58167 chip (.CLK(clk), .reset_n(reset_n), .DIN(8'h00), .DOUT(dout), .addr(addr),
              .CS_n(1'b0), .RD_n(rd_n), .WR_n(1'b1), .X2(x2), .LD(ld), .LD_TIME(tod));

integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++; else begin fails++; $display("FAIL  %s", what); end
endtask

localparam longint SHIFT  = 64'd1136073600;  // 36 years: 1990-01-01 .. 2026-01-01
localparam longint SECYR  = 64'd31536000;
int monthdays [12] = '{0, 31, 59, 90, 120, 151, 181, 212, 243, 273, 304, 334};

function automatic [7:0] bcd(int v); return {4'(v / 10), 4'(v % 10)}; endfunction
function automatic int  unbcd(bit [7:0] b); return 10 * b[7:4] + b[3:0]; endfunction

// todset(), sundev/tod.c: what SunOS itself would write for time t
function automatic [47:0] todset(longint t);
    int s, sec, mn, hr, day, wd, mon;
    s   = int'(t % SECYR);
    sec = s % 60;  s /= 60;
    mn  = s % 60;  s /= 60;
    hr  = s % 24;
    day = s / 24;
    wd  = day % 7 + 1;
    for (mon = 11; mon >= 0; mon--) if (day >= monthdays[mon]) break;
    day = day - monthdays[mon] + 1;
    return {bcd(mon + 1), bcd(day), bcd(wd), bcd(hr), bcd(mn), bcd(sec)};
endfunction

// todget(), the same file: the time with this remainder nearest base
function automatic longint todget(bit [7:0] c [8], longint base);
    longint toy, basetoy;
    toy = monthdays[unbcd(c[7]) - 1] + unbcd(c[6]) - 1;
    toy = 24 * toy + unbcd(c[4]);
    toy = 60 * toy + unbcd(c[3]);
    toy = 60 * toy + unbcd(c[2]);
    basetoy = base % SECYR;
    toy -= basetoy;
    if (toy > SECYR / 2)       toy -= SECYR;
    else if (toy < -SECYR / 2) toy += SECYR;
    return base + toy;
endfunction

// seconds since 1970 -> the civil date (H. Hinnant's algorithm)
task automatic civil(input longint t, output int y, output int m, output int d, output int sod);
    longint z, era, doe, yoe, doy, mp;
    z   = t / 86400 + 719468;
    sod = int'(t % 86400);
    era = z / 146097;
    doe = z - era * 146097;
    yoe = (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365;
    doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    mp  = (5 * doy + 2) / 153;
    d   = int'(doy - (153 * mp + 2) / 5 + 1);
    m   = int'(mp < 10 ? mp + 3 : mp - 9);
    y   = int'(yoe + era * 400 + (m <= 2 ? 1 : 0));
endtask

// What Main sends for local time t: send_rtc() in user_io.cpp
task automatic send(input longint t);
    int y, m, d, s;
    civil(t, y, m, d, s);
    @(negedge clk);
    rtc = {~rtc[64], 8'h40, 8'(int'((t / 86400 + 4) % 7)), bcd(y % 100), bcd(m), bcd(d),
           bcd(s / 3600), bcd(s / 60 % 60), bcd(s % 60)};
endtask

task automatic wait_ld(output bit seen);
    seen = 0;
    repeat (200) begin
        @(posedge clk);
        if (ld) begin seen = 1; break; end
    end
endtask

task automatic read_chip(output bit [7:0] c [8]);
    for (int r = 0; r < 8; r++) begin
        @(posedge clk); addr <= 5'(r);
        @(posedge clk); rd_n <= 0;
        repeat (4) @(posedge clk);
        c[r] = dout;
        rd_n <= 1;
        repeat (4) @(posedge clk);
    end
endtask

// local times, as seconds since 1970 read as if UTC
longint cases [] = '{
    64'd1791032250,     // Sat 3 Oct 2026, 12:57:30
    64'd1767225600,     // 1 Jan 2026 00:00:00
    64'd1772236799,     // 27 Feb 2026 23:59:59
    64'd1772323200,     // 1 Mar 2026 00:00:00
    64'd1798761599,     // 31 Dec 2026 23:59:59
    64'd1835395199,     // 28 Feb 2028 23:59:59, a leap year
    64'd1835395200,     // 29 Feb 2028 00:00:00
    64'd1835481600,     // 1 Mar 2028
    64'd2082758399,     // 31 Dec 2035 23:59:59: the Sun's 31 Dec 1999
    64'd1136073600,     // 1 Jan 2006: the Sun's 1 Jan 1970, the first it can show
    64'd3155759999      // 31 Dec 2069 23:59:59: the Sun's 31 Dec 2033, the last
};

int nld1 = 0;
always @(posedge clk) if (ld1) nld1++;

initial begin
    bit seen;
    bit [7:0] c [8];
    $display("tb_mister_tod: MiSTer's RTC into the MM58167, read back as SunOS reads it");

    // A load that arrives during the power-on reset: remembered, then applied.
    repeat (20) @(posedge clk);
    send(cases[0]);
    wait_ld(seen);
    check(seen, "an RTC update produces a load");
    repeat (50) @(posedge clk);
    reset_n = 1;                              // the machine leaves reset later
    repeat (20) @(posedge clk);

    foreach (cases[i]) begin
        longint t_real, t_sun, back;
        int ry, rm, rd, rs, sy, sm, sd, ss;
        t_real = cases[i];
        t_sun  = t_real - SHIFT;
        if (i > 0) begin
            send(t_real);
            wait_ld(seen);
            check(seen, $sformatf("case %0d: a load", i));
            repeat (20) @(posedge clk);
        end
        check(tod == todset(t_sun),
              $sformatf("case %0d: converter %012h, todset() %012h", i, tod, todset(t_sun)));
        read_chip(c);
        // the fractions start from zero (a millisecond tick may land meanwhile)
        check(c[0][7:4] <= 4'd1 && c[1] == 8'h00,
              $sformatf("case %0d: fractions after the load %02h %02h", i, c[0], c[1]));
        // a root file system written an hour before, and one five months before
        back = todget(c, t_sun - 3600);
        check(back == t_sun, $sformatf("case %0d: todget(base an hour before) = %0d, want %0d", i, back, t_sun));
        back = todget(c, t_sun - 150 * 86400);
        check(back == t_sun, $sformatf("case %0d: todget(base five months before) = %0d, want %0d", i, back, t_sun));
        civil(t_real, ry, rm, rd, rs);
        civil(t_sun,  sy, sm, sd, ss);
        check(ry - sy == 36 && rm == sm && rd == sd && rs == ss,
              $sformatf("case %0d: MiSTer %04d-%02d-%02d %05d s, the Sun %04d-%02d-%02d %05d s",
                        i, ry, rm, rd, rs, sy, sm, sd, ss));
    end

    // the clock outside what the counts hold: nothing loads
    send(64'd86400);                          // 2 Jan 1970: MiSTer with no time set
    wait_ld(seen);
    check(!seen, "1970 loads nothing");
    send(64'd1104537600);                     // 1 Jan 2005: the Sun's 1969
    wait_ld(seen);
    check(!seen, "2005 loads nothing");
    send(64'd3155760000);                     // 1 Jan 2070: the Sun's 2034
    wait_ld(seen);
    check(!seen, "2070 loads nothing");

    // as built, only the first update loads, however many follow
    check(nld1 == 1, $sformatf("as built, %0d loads from %0d updates", nld1, cases.size() + 3));

    $display("");
    $display("tb_mister_tod: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #100_000_000;
    $display("FAIL  timeout");
    $finish;
end

endmodule
