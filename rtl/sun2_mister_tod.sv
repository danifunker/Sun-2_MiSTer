//
// sun2_mister_tod.sv
//
// The Sun's time of day, from MiSTer's clock.
//
// Main_MiSTer sends hps_io's RTC when it loads the core and every minute
// after: MiSTer's local time as BCD -- second, minute, hour, day, month, the
// year's last two digits, weekday -- with bit 64 toggling on each update.
// The first one after configuration is turned into what SunOS keeps in the
// MM58167 and loaded into it; later ones are ignored, as a battery-backed
// clock would ignore them, so a time set with date(1) stands until the core is
// loaded again.  (TIMESTAMP is no use here: for a core Main does not know to be
// UNIX it is UTC shifted by the standard-time offset only, an hour out
// whenever daylight saving is in force.)
//
// What SunOS keeps in the chip is not a calendar date.  The chip has no year,
// so sundev/tod.c stores the time modulo a 365-day year -- todset() writes
// `tv_sec % SECYR' broken into month, day, hour, minute and second with a
// no-leap month table, and the weekday as (day of that year % 7) + 1 -- and
// todget() takes it back as the instant with that remainder nearest the root
// file system's last-write time, within half a year either way.  4.0.3's
// kernel does exactly this (todget: `base % 31536000', the +-15768000 wrap).
//
// So the chip cannot carry a year, and nothing here chooses one: SunOS takes
// the year from the disk, and a disk stays in the era it was installed in,
// moving on with real time.  What the chip does carry is the day of the year
// and the time of day, and those are MiSTer's local time less 36 years -- a
// whole number of leap cycles (1901..2099 has no other leap rule) -- so on a
// disk whose clock reads 1990 while MiSTer's reads 2026, the month, day and
// time of day stay exactly MiSTer's, every day, as both move on.  1990 is
// after every file date on the 4.0 and 4.0.3 tapes and ten years short of
// 2000, which 4.0.3 was never tested against.  A disk set to another year is
// off by a day on either side of each 29 February until it is set to 1990
// (`date 9010031400', once; README "The clock").
//
// The Sun's own idea of time is UTC with its time zone applied on top, and
// this is local time, so the Sun shows MiSTer's wall clock when its zone is
// GMT.
//
// The day of the 365-day year needs no long division: for the Sun's year y,
// the time since 1970 is 365 * (y - 1970) days -- nothing modulo 365 -- plus
// one day for each leap year since 1970 before y, plus the day of y; so it is
// that leap count plus the day of the year, less 365 if it reaches 365.  The
// counts here hold for 1970..2033, the Sun's years for MiSTer's 2006..2069; a
// clock outside them -- MiSTer with no time set reads 1970 -- loads nothing,
// and the chip keeps its power-on constants.
//
`timescale 1ns / 1ps

module sun2_mister_tod #(
    parameter bit ONCE = 1'b1           // only the first update; 0 for tests
) (
    input  wire        clk,
    input  wire [64:0] rtc,             // hps_io RTC, its clock: [64] toggles
    output reg         ld  = 1'b0,      // one clock: tod is the time to load
    output reg  [47:0] tod = 48'd0      // BCD {month, day, weekday, hour, minute, second}
);

    // the running sum of days before each month, no leap year (tod.c)
    function automatic [8:0] monthdays(input [3:0] m);   // m = 0..11
        case (m)
            4'd0:  monthdays = 9'd0;    4'd1:  monthdays = 9'd31;   4'd2:  monthdays = 9'd59;
            4'd3:  monthdays = 9'd90;   4'd4:  monthdays = 9'd120;  4'd5:  monthdays = 9'd151;
            4'd6:  monthdays = 9'd181;  4'd7:  monthdays = 9'd212;  4'd8:  monthdays = 9'd243;
            4'd9:  monthdays = 9'd273;  4'd10: monthdays = 9'd304;  default: monthdays = 9'd334;
        endcase
    endfunction

    function automatic [6:0] unbcd(input [7:0] b);
        unbcd = {3'b000, b[7:4]} * 7'd10 + {3'b000, b[3:0]};
    endfunction

    function automatic [7:0] bcd(input [6:0] v);           // v < 100
        reg [6:0] tens, ones;
        begin
            tens = v / 7'd10;
            ones = v % 7'd10;
            bcd  = {tens[3:0], ones[3:0]};
        end
    endfunction

    // The toggle is synchronised; the fields beside it have been steady since
    // before it toggled.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] rtc_s = 3'd0;
    reg       rtc_seen = 1'b0;
    reg       loaded = 1'b0;

    localparam [1:0] S_IDLE = 2'd0, S_MON = 2'd1, S_LOAD = 2'd2;
    reg [1:0]  st = S_IDLE;
    reg [9:0]  pdoy = 10'd0;            // the day of SunOS's 365-day year, 0..364
    reg [3:0]  mon = 4'd0;
    reg [23:0] hms = 24'd0;             // BCD hour, minute, second, as MiSTer sent them

    // temporaries, assigned blocking
    reg [6:0]  yy, m, d, ys;
    reg [9:0]  doy, sum, dom, wd;

    always @(posedge clk) begin
        rtc_s <= {rtc_s[1:0], rtc[64]};
        ld    <= 1'b0;

        case (st)
            S_IDLE:
                if (rtc_s[2] != rtc_seen) begin
                    rtc_seen <= rtc_s[2];
                    yy = unbcd(rtc[47:40]);             // 20yy
                    m  = unbcd(rtc[39:32]);
                    d  = unbcd(rtc[31:24]);
                    if (!(ONCE && loaded) && yy >= 7'd6 && yy <= 7'd69 &&
                        m >= 7'd1 && m <= 7'd12 && d >= 7'd1 && d <= 7'd31) begin
                        ys  = yy - 7'd6;                // the Sun's year, less 1970
                        // the day of the Sun's year; its leap years are MiSTer's
                        doy = monthdays(m[3:0] - 4'd1) + {3'b000, d} - 10'd1 +
                              ((ys[1:0] == 2'd2 && m > 7'd2) ? 10'd1 : 10'd0);
                        // plus a day for each leap year from 1970 up to it
                        sum = doy + {5'b00000, ys[6:2]} + ((ys[1:0] == 2'd3) ? 10'd1 : 10'd0);
                        pdoy <= (sum >= 10'd365) ? sum - 10'd365 : sum;
                        hms  <= rtc[23:0];
                        mon  <= 4'd11;
                        st   <= S_MON;
                    end
                end

            // the last month that starts on or before the day
            S_MON:
                if (pdoy < {1'b0, monthdays(mon)}) mon <= mon - 4'd1;
                else st <= S_LOAD;

            S_LOAD: begin
                dom = pdoy - {1'b0, monthdays(mon)};            // 0..30
                wd  = pdoy % 10'd7;
                tod <= {bcd({3'b000, mon} + 7'd1),
                        bcd(dom[6:0] + 7'd1),
                        bcd(wd[6:0] + 7'd1),
                        hms};
                ld     <= 1'b1;
                loaded <= 1'b1;
                st     <= S_IDLE;
            end

            default: st <= S_IDLE;
        endcase
    end

endmodule
