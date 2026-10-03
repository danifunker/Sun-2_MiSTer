//============================================================================
//  tb_kbm_scc -- the MiSTer keyboard/mouse bridge into the keyboard/mouse
//  Z8530, driven the way SunOS 4 drives it.
//
//  tb_mister_kbd_mouse checks the bytes on the two serial lines; this checks
//  that they arrive.  The mouse is on channel B of the SCC, and nothing in
//  this project has ever *received* on a channel B: the keyboard is channel
//  A, and the console SCC's channel B (ttyb) is tied to mark.
//
//  Everything here is the machine's or SunOS's own:
//
//    * the bridge, rtl/sun2_mister_kbd_mouse.sv, at the real 20 MHz and 1200
//      baud, its lines wired as Sun-2.sv wires them;
//    * the SCC with the parameters and tie-offs of the `keybmouse' instance
//      in rtl/sun2-common/sun2_fpga.v, on cpu_clk and the 4.9152 MHz clock,
//      over the Sun-2's bus protocol (cs_n low, rd_n/wr_n the strobes,
//      a_b = A2, d_c = A1);
//    * the register writes of zsattach() and zsnull_attach() (zs_common.c),
//      units 2 and 3 being the keyboard and mouse, and of zsa_program()
//      (zs_async.c) for the keyboard at 1200 baud and for the mouse with the
//      termios ms.c's msopen() sends down: CREAD|CS8|B1200;
//    * the interrupt dispatch of zslevel6 (m68k/zs_asm.s): RR2 read through
//      channel B of the chip, bit 3 the channel, bits 2:1 the source, then
//      ZSWR0_CLR_INTR -- and zslevel6intr()'s RR3 walk for the 011 code;
//    * ms.c's msinput() decoding what channel B delivers into the deltas and
//      buttons the window system sees.
//
//      make -C tb/verilator tb_kbm_scc
//============================================================================
`timescale 1ns/1ps

module tb_kbm_scc;

// ---- clocks: cpu_clk 20 MHz, the SCC's 4.9152 MHz ---------------------------
reg clk = 0, sclk = 0;
always #25       clk  = ~clk;
always #101.7253 sclk = ~sclk;

reg rst = 1;            // the bridge's reset (reset_cpu)
reg reset_n = 0;        // the SCC's power-on reset (~por_reset)

// ---- the bridge -------------------------------------------------------------
reg  [10:0] ps2_key   = 0;
reg  [24:0] ps2_mouse = 0;
wire        kbm_rxda, kbm_txda, kbm_rxdb, kbm_txdb;

sun2_mister_kbd_mouse #(.CLK_HZ(20_000_000)) bridge (
    .clk(clk), .rst(rst), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
    .kbd_ser_tx(kbm_rxda), .kbd_ser_rx(kbm_txda), .mouse_ser_tx(kbm_rxdb), .bell());

// ---- the SCC, as sun2_fpga.v builds `keybmouse' -----------------------------
reg        rd_n = 1, wr_n = 1, a_b = 1, d_c = 0;
reg  [7:0] data_in = 0;
wire [7:0] data_out;
wire       int_n;

z8530_scc #(.SOFT_RESET_EN(1), .RR8_CTRL_POP(1), .BRG_SRC_A(1), .BRG_SRC_B(1),
            .UNIPLUS_BAUD_PATCH_B(0), .AUTO_ENABLES_EN(0),
            .RTXC_XTAL_FULLRATE_A(0), .RTXC_XTAL_FULLRATE_B(0), .RDWR_RESET_EN(1)
) scc (
    .clk(clk), .pclk(sclk), .sclk(sclk), .reset_n(reset_n),
    .cs_n(1'b0), .rd_n(rd_n), .wr_n(wr_n), .a_b(a_b), .d_c(d_c),
    .data_in(data_in), .data_out(data_out), .data_oe(),
    .int_n(int_n), .intack_n(1'b1),
    .rxca(1'b0), .txca(1'b0), .rxda(kbm_rxda), .txda(kbm_txda),
    .ctsa_n(1'b1), .dcda_n(1'b1), .synca_n(1'b1), .rtsa_n(), .dtra_n(),
    .rxcb(1'b0), .txcb(1'b0), .rxdb(kbm_rxdb), .txdb(kbm_txdb),
    .ctsb_n(1'b1), .dcdb_n(1'b1), .syncb_n(1'b1), .rtsb_n(), .dtrb_n());

// ---- checks -------------------------------------------------------------------
integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) begin passes++; $display("  ok  %s", what); end
    else    begin fails++;  $display("FAIL  %s", what); end
endtask

// ---- the bus, as sun2_fpga.v presents it ------------------------------------
// RD/WR are the 68010's data-strobe window qualified by MATCH_KBM: several
// clocks wide, address and data already valid.  zszread/zszwrite leave a
// recovery gap of a microsecond or two between cycles.
localparam int STROBE_CLK = 4, RECOVERY_CLK = 36;
localparam bit CHAN_A = 1'b1, CHAN_B = 1'b0;

task automatic bus_write(input bit chan_a, input bit is_data, input [7:0] v);
    @(posedge clk);
    a_b <= chan_a; d_c <= is_data; data_in <= v;
    @(posedge clk);
    wr_n <= 1'b0;
    repeat (STROBE_CLK) @(posedge clk);
    wr_n <= 1'b1;
    repeat (RECOVERY_CLK) @(posedge clk);
endtask

task automatic bus_read(input bit chan_a, input bit is_data, output [7:0] v);
    @(posedge clk);
    a_b <= chan_a; d_c <= is_data;
    @(posedge clk);
    rd_n <= 1'b0;
    repeat (STROBE_CLK) @(posedge clk);
    v = data_out;
    rd_n <= 1'b1;
    repeat (RECOVERY_CLK) @(posedge clk);
endtask

// ZWRITE / ZREAD (zscom.h): point, then the cycle.  zs_wreg is the driver's
// shadow of what it wrote, which zsa_program() compares against.
reg [7:0] wreg [2][16];
task automatic zwrite(input bit chan_a, input [3:0] n, input [7:0] v);
    if (n != 0) bus_write(chan_a, 1'b0, {4'h0, n});
    bus_write(chan_a, 1'b0, v);
    wreg[chan_a][n] = v;
endtask
task automatic zread(input bit chan_a, input [3:0] n, output [7:0] v);
    if (n != 0) bus_write(chan_a, 1'b0, {4'h0, n});
    bus_read(chan_a, 1'b0, v);
endtask

// ---- SunOS's register values (sundev/zsreg.h, zs_async.c) --------------------
localparam [7:0] ZSWR0_RESET_STATUS = 8'h10, ZSWR0_RESET_TXINT = 8'h28,
                 ZSWR0_RESET_ERRORS = 8'h30, ZSWR0_CLR_INTR    = 8'h38;
localparam [7:0] ZSWR1_INIT = 8'h13;                    // SIE|TIE|RIE
localparam [7:0] ZSWR3_RX_8 = 8'hC0, ZSWR3_RX_ENABLE = 8'h01;
localparam [7:0] ZSWR4_X16_CLK = 8'h40, ZSWR4_1_STOP = 8'h04, ZSWR4_PARITY_EVEN = 8'h02;
localparam [7:0] ZSWR5_TX_ENABLE = 8'h08, ZSWR5_TX_8 = 8'h60, ZSWR5_RTS = 8'h02, ZSWR5_DTR = 8'h80;
localparam [7:0] ZSWR9_RESET_WORLD = 8'hC0, ZSWR9_MASTER_IE = 8'h08, ZSWR9_VECTOR_INCL_STAT = 8'h01;
localparam [7:0] ZSWR11_INIT = 8'h50;                   // TXCLK_BAUD|RXCLK_BAUD
localparam [7:0] ZSWR14_BAUD_FROM_PCLK = 8'h02, ZSWR14_BAUD_ENA = 8'h01;
localparam [7:0] ZSWR15_KBMS = 8'hE8;                   // BREAK|TX_UNDER|CTS|CD
localparam [7:0] ZSRR0_RX_READY = 8'h01;
localparam [7:0] ZSRR1_ALL_SENT = 8'h01;
// ZSTimeConst(19660800/4, 1200) = 4915200 / (2 * 16 * 1200) - 2
localparam [15:0] SPEED_1200 = 16'd126;

// zsnull_attach(), zs_common.c: the monitor-compatible defaults, plus the
// kb/ms hack that turns the Sync/Hunt status interrupt off on units 2 and 3.
task automatic zsnull_attach(input bit chan_a, input [15:0] speed);
    zwrite(chan_a, 4,  ZSWR4_PARITY_EVEN | ZSWR4_1_STOP | ZSWR4_X16_CLK);
    zwrite(chan_a, 3,  ZSWR3_RX_8);
    zwrite(chan_a, 11, ZSWR11_INIT);
    zwrite(chan_a, 12, speed[7:0]);
    zwrite(chan_a, 13, speed[15:8]);
    zwrite(chan_a, 14, ZSWR14_BAUD_FROM_PCLK);
    zwrite(chan_a, 3,  ZSWR3_RX_8 | ZSWR3_RX_ENABLE);
    zwrite(chan_a, 5,  ZSWR5_TX_ENABLE | ZSWR5_TX_8 | ZSWR5_RTS | ZSWR5_DTR);
    zwrite(chan_a, 14, ZSWR14_BAUD_ENA | ZSWR14_BAUD_FROM_PCLK);
    zwrite(chan_a, 15, ZSWR15_KBMS);
    bus_write(chan_a, 1'b0, ZSWR0_RESET_ERRORS | ZSWR0_RESET_STATUS);
endtask

// zsa_program(), zs_async.c, for CREAD|CS8|1 stop|no parity at `speed'.
task automatic zsa_program(input bit chan_a, input [15:0] speed);
    reg [7:0] v;
    int loops;
    loops = 1000;
    do begin
        zread(chan_a, 1, v);
        loops = loops - 1;
    end while (!(v & ZSRR1_ALL_SENT) && loops > 0);
    zwrite(chan_a, 3, 8'h00);           // receiver off while setting parameters
    bus_write(chan_a, 1'b0, ZSWR0_RESET_STATUS);
    bus_write(chan_a, 1'b0, ZSWR0_RESET_ERRORS);
    bus_read(chan_a, 1'b1, v);          // swallow junk, three times
    bus_read(chan_a, 1'b1, v);
    bus_read(chan_a, 1'b1, v);
    zwrite(chan_a, 1, ZSWR1_INIT);
    zwrite(chan_a, 4, ZSWR4_X16_CLK | ZSWR4_1_STOP);
    zwrite(chan_a, 3, ZSWR3_RX_ENABLE | ZSWR3_RX_8);
    zwrite(chan_a, 5, (wreg[chan_a][5] & (ZSWR5_RTS | ZSWR5_DTR)) | ZSWR5_TX_ENABLE | ZSWR5_TX_8);
    zwrite(chan_a, 11, ZSWR11_INIT);
    zwrite(chan_a, 14, ZSWR14_BAUD_FROM_PCLK);
    zwrite(chan_a, 12, speed[7:0]);
    zwrite(chan_a, 13, speed[15:8]);
    zwrite(chan_a, 14, ZSWR14_BAUD_ENA | ZSWR14_BAUD_FROM_PCLK);
endtask

// ---- what the drivers receive ------------------------------------------------
bit [7:0] rxq [2][$];            // per channel, in arrival order
int       n_int [2][4];          // interrupts taken, per channel and source
int       n_spurious = 0;

// One level-6 interrupt, as zslevel6 takes it.  zscurr is channel B of this,
// the only chip here.
task automatic level6();
    reg [7:0] iinf, v;
    bit       ch;
    bus_write(CHAN_B, 1'b0, 8'h02);     // movb #2,a1@
    bus_read (CHAN_B, 1'b0, iinf);      // movb a1@,d0
    ch = iinf[3];                       // btst #3: channel A
    case (iinf[2:1])
        2'd0: begin                     // zsa_txint, nothing more to send
            n_int[ch][0]++;
            bus_write(ch, 1'b0, ZSWR0_RESET_TXINT);
        end
        2'd1: begin                     // zsa_xsint
            n_int[ch][1]++;
            bus_read (ch, 1'b0, v);
            bus_write(ch, 1'b0, ZSWR0_RESET_STATUS);
        end
        2'd2: begin                     // zsa_rxint: the data port, nothing else
            n_int[ch][2]++;
            bus_read(ch, 1'b1, v);
            rxq[ch].push_back(v);
        end
        2'd3: begin
            // zs_vec[3] is zslevel6intr() on a Sun-2: the RR3 walk.  With an
            // IP really pending this takes it again through the vector; with
            // none it is the "no interrupt" code and returns.
            zread(CHAN_A, 3, v);
            if (v == 8'h00) n_spurious++;
            else begin
                n_int[ch][3]++;
                zread(CHAN_A, 1, v);            // a special condition: zsa_srint
                bus_read(ch, 1'b1, v);
                bus_write(ch, 1'b0, ZSWR0_RESET_ERRORS);
            end
        end
    endcase
    bus_write(ch, 1'b0, ZSWR0_CLR_INTR);   // movb #ZSWR0_CLR_INTR,a1@
endtask

// Take interrupts until `limit' cpu_clk cycles have passed.
task automatic serve(input int limit);
    int t;
    t = 0;
    while (t < limit) begin
        if (int_n === 1'b0) level6();
        else begin @(posedge clk); t++; end
    end
endtask

// ---- the MiSTer side -----------------------------------------------------------
task automatic key(input bit press, input [7:0] code);
    @(negedge clk);
    ps2_key = {~ps2_key[10], press, 1'b0, code};
endtask

// status: [0] left, [1] right, [2] middle, [4] X sign, [5] Y sign; Y up-positive
task automatic mouse(input bit l, input bit m, input bit r, input int dx, input int dy);
    bit [8:0] x, y;
    x = 9'(dx); y = 9'(dy);
    @(negedge clk);
    ps2_mouse = {~ps2_mouse[24], y[7:0], x[7:0], 2'b00, y[8], x[8], 1'b1, m, r, l};
endtask

// ---- ms.c's msinput(), on what channel B delivered ---------------------------
typedef struct { int x; int y; int buttons; } msev_t;
msev_t msev [$];

function automatic int byteclip(int v);
    return v > 127 ? 127 : (v < -128 ? -128 : v);
endfunction

task automatic ms_decode();
    int state, x, y, b;
    state = 0; x = 0; y = 0; b = 0;
    foreach (rxq[CHAN_B][i]) begin
        bit signed [7:0] c;
        c = rxq[CHAN_B][i];
        case (state)
            0: if ((c & 8'hF0) != 8'h80) continue;
               else begin b = c & 7; x = 0; y = 0; end
            1, 3: x = byteclip(x + c);
            2, 4: y = byteclip(y - c);
        endcase
        if (state == 4) begin
            msev_t e;
            e.x = x; e.y = y; e.buttons = b;
            msev.push_back(e);
            state = 0;
        end else
            state++;
    end
endtask

// ---- the run ------------------------------------------------------------------------
localparam int BYTE_CLK = 20_000_000 / 1200 * 10;      // one 8N1 byte at 1200 baud

initial begin
    reg [7:0] v;
    $display("tb_kbm_scc: the keyboard/mouse SCC as SunOS 4 drives it, fed by the MiSTer bridge");

    repeat (20) @(posedge clk);
    reset_n = 1;
    repeat (20) @(posedge clk);
    rst = 0;
    repeat (20) @(posedge clk);

    // zsattach(): wait for both transmitters, keep the PROM's speeds, then a
    // hardware reset -- written through channel B, which is where zs_addr
    // points (md_addr; channel A is md_addr | ZSOFF).
    zread(CHAN_A, 12, v);
    zread(CHAN_B, 12, v);
    zwrite(CHAN_B, 9, ZSWR9_RESET_WORLD);
    repeat (400) @(posedge clk);
    zsnull_attach(CHAN_A, SPEED_1200);      // unit 2, the keyboard
    zsnull_attach(CHAN_B, SPEED_1200);      // unit 3, the mouse
    zwrite(CHAN_B, 9, ZSWR9_MASTER_IE | ZSWR9_VECTOR_INCL_STAT);
    // (Sun-2 interrupts are autovectored: no WR2.)

    // consconfig() opens the keyboard (minor 2) and then the mouse (minor 3),
    // and msopen() sends TCSETSF with CREAD|CS8|B1200 down the mouse's stream.
    zsa_program(CHAN_A, SPEED_1200);
    zsa_program(CHAN_B, SPEED_1200);
    serve(BYTE_CLK);
    check(int_n === 1'b1, "the chip is quiet once both lines are programmed");

    // ---- control: a key on channel A, the path known to work on the board
    key(1, 8'h1C);                          // A down
    serve(BYTE_CLK * 2);
    key(0, 8'h1C);                          // A up: break, then IDLE
    serve(BYTE_CLK * 4);
    check(rxq[CHAN_A].size() == 3 && rxq[CHAN_A][0] == 8'h4D && rxq[CHAN_A][1] == 8'hCD &&
          rxq[CHAN_A][2] == 8'h7F,
          $sformatf("keyboard, channel A: A down, up, IDLE = 4D CD 7F (got %p)", rxq[CHAN_A]));

    // ---- the mouse, channel B
    mouse(1, 0, 0, 5, 3);                   // left down, right 5, up 3
    serve(BYTE_CLK * 7);
    check(rxq[CHAN_B].size() == 5,
          $sformatf("mouse, channel B: a five-byte packet arrives (got %0d bytes: %p)",
                    rxq[CHAN_B].size(), rxq[CHAN_B]));
    mouse(0, 0, 0, -7, -2);                 // all up, left 7, down 2
    serve(BYTE_CLK * 7);
    mouse(0, 0, 1, -200, 200);              // right alone: more than one packet holds
    serve(BYTE_CLK * 12);
    mouse(0, 1, 0, 127, -127);              // middle alone
    serve(BYTE_CLK * 7);
    check(rxq[CHAN_B].size() == 25, $sformatf("five packets, 25 bytes (got %0d)", rxq[CHAN_B].size()));

    ms_decode();
    check(msev.size() == 5, $sformatf("msinput: five events (got %0d)", msev.size()));
    if (msev.size() == 5) begin
        // ms.c: buttons active low, 4 left 2 middle 1 right; mi_y -= dy; the
        // two deltas of a packet added into one byte, so -200 takes two.
        check(msev[0].x == 5    && msev[0].y == -3   && msev[0].buttons == 3,
              $sformatf("event 1: x %0d y %0d buttons %0d, want 5 -3 3", msev[0].x, msev[0].y, msev[0].buttons));
        check(msev[1].x == -7   && msev[1].y == 2    && msev[1].buttons == 7,
              $sformatf("event 2: x %0d y %0d buttons %0d, want -7 2 7", msev[1].x, msev[1].y, msev[1].buttons));
        check(msev[2].x == -128 && msev[2].y == -127 && msev[2].buttons == 6,
              $sformatf("event 3a: x %0d y %0d buttons %0d, want -128 -127 6", msev[2].x, msev[2].y, msev[2].buttons));
        check(msev[3].x == -72  && msev[3].y == -73  && msev[3].buttons == 6,
              $sformatf("event 3b: x %0d y %0d buttons %0d, want -72 -73 6", msev[3].x, msev[3].y, msev[3].buttons));
        check(msev[4].x == 127  && msev[4].y == 127  && msev[4].buttons == 5,
              $sformatf("event 4: x %0d y %0d buttons %0d, want 127 127 5", msev[4].x, msev[4].y, msev[4].buttons));
    end

    check(n_int[CHAN_B][2] == 25, $sformatf("one receive interrupt per mouse byte (%0d)", n_int[CHAN_B][2]));
    check(n_int[CHAN_A][3] == 0 && n_int[CHAN_B][3] == 0, "no special receive conditions");
    $display("  interrupts: A tx %0d ext %0d rx %0d spc %0d; B tx %0d ext %0d rx %0d spc %0d; spurious %0d",
             n_int[1][0], n_int[1][1], n_int[1][2], n_int[1][3],
             n_int[0][0], n_int[0][1], n_int[0][2], n_int[0][3], n_spurious);

    $display("");
    $display("tb_kbm_scc: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

// A hung bench is a failure, not a wait.
initial begin
    #1_000_000_000;
    $display("FAIL  timeout");
    $finish;
end

endmodule
