//============================================================================
//  tb_mister_kbd_mouse -- rtl/sun2_mister_kbd_mouse.sv, its two serial lines
//  decoded bit by bit and its command line driven the same way.  The UARTs
//  run at 16 clocks a bit (CLK_HZ = 19200) so a run takes seconds.
//
//  Checked against what the Sun reads: the reset answer (0xFF, type 3); make,
//  break | 0x80 and IDLE after the last key; a held Shift; auto-repeat makes
//  dropped; extended keys; the Sun-2 codes the PROM's ktab.s2.c expects; a
//  burst of events faster than the line delivers; Mouse Systems packets with
//  buttons active low, Y up-positive and deltas clamped to -112..127, as
//  sundev/ms.c reads them; a line glitch is not a byte.  The beeper: the bell
//  for as long as it is on, a 5 ms click on each make once 0x0A enables it
//  and none on a break or a dropped repeat, and RESET silencing both.
//
//      make -C tb/verilator tb_mister_kbd_mouse
//============================================================================
`timescale 1ns/1ps

module tb_mister_kbd_mouse;

localparam int BT = 16;                         // clocks per bit
localparam int CLICK = BT * 1200 / 200;         // 5 ms

reg clk = 0;
always #5 clk = ~clk;
reg rst = 1;

reg  [10:0] ps2_key = 0;
reg  [24:0] ps2_mouse = 0;
wire        kbd_tx, mouse_tx;
reg         kbd_rx = 1;
wire        beeper;

sun2_mister_kbd_mouse #(.CLK_HZ(BT * 1200)) dut (
    .clk(clk), .rst(rst), .ps2_key(ps2_key), .ps2_mouse(ps2_mouse),
    .kbd_ser_tx(kbd_tx), .kbd_ser_rx(kbd_rx), .mouse_ser_tx(mouse_tx), .beeper(beeper));

integer passes = 0, fails = 0;

// every time the beeper sounds, how long for
int beep_len = 0;
int beeps [$];
always @(posedge clk) begin
    if (beeper) beep_len <= beep_len + 1;
    else if (beep_len != 0) begin beeps.push_back(beep_len); beep_len <= 0; end
end
task check(input bit ok, input string what);
    begin
        if (ok) passes++;
        else begin fails++; $display("FAIL  %s", what); end
    end
endtask

// ---- receivers: sample mid-bit, LSB first, check the stop bit -------------
bit [7:0] kq [$];
bit [7:0] mq [$];
integer   framing = 0;

task automatic rx_line(input int which);
    forever begin
        bit [7:0] b;
        // wait for a start bit
        if (which == 0) @(negedge kbd_tx); else @(negedge mouse_tx);
        repeat (BT / 2) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            repeat (BT) @(posedge clk);
            b[i] = (which == 0) ? kbd_tx : mouse_tx;
        end
        repeat (BT) @(posedge clk);
        if (((which == 0) ? kbd_tx : mouse_tx) != 1'b1) framing++;
        if (which == 0) kq.push_back(b); else mq.push_back(b);
    end
endtask
initial rx_line(0);
initial rx_line(1);

task automatic send_cmd(input [7:0] b);
    begin
        kbd_rx = 0; repeat (BT) @(posedge clk);
        for (int i = 0; i < 8; i++) begin kbd_rx = b[i]; repeat (BT) @(posedge clk); end
        kbd_rx = 1; repeat (BT * 2) @(posedge clk);
    end
endtask

task automatic key(input bit press, input bit ext, input [7:0] code);
    begin
        @(negedge clk);
        ps2_key = {~ps2_key[10], press, ext, code};
        repeat (BT * 12) @(posedge clk);        // about one byte time apart
    end
endtask

task automatic mouse(input [2:0] btn_lmr, input int dx, input int dy);
    bit [8:0] x, y;
    begin
        x = 9'(dx); y = 9'(dy);
        @(negedge clk);
        // status: [0] left, [1] right, [2] middle, [4] X sign, [5] Y sign
        ps2_mouse = {~ps2_mouse[24], y[7:0], x[7:0], 2'b00, y[8], x[8], 1'b1,
                     btn_lmr[1], btn_lmr[0], btn_lmr[2]};
        repeat (BT * 12 * 6) @(posedge clk);
    end
endtask

// One event and no wait: for streams faster than the line.
task automatic mouse_now(input [2:0] btn_lmr, input int dx, input int dy);
    bit [8:0] x, y;
    begin
        x = 9'(dx); y = 9'(dy);
        @(negedge clk);
        ps2_mouse = {~ps2_mouse[24], y[7:0], x[7:0], 2'b00, y[8], x[8], 1'b1,
                     btn_lmr[1], btn_lmr[0], btn_lmr[2]};
    end
endtask

task automatic drain(input int bytes_time);
    repeat (BT * 11 * bytes_time) @(posedge clk);
endtask

// What ms.c makes of the mouse line so far: packets well formed, the total
// motion (Y as ms.c turns it, down positive), and the button byte of each.
task automatic decode_m(output bit ok, output int sx, output int sy, output string btns);
    begin
        ok = (mq.size() % 5 == 0);
        sx = 0; sy = 0; btns = "";
        for (int i = 0; i + 4 < mq.size(); i += 5) begin
            if ((mq[i] & 8'hF8) != 8'h80) ok = 0;
            sx += $signed(mq[i+1]) + $signed(mq[i+3]);
            sy -= $signed(mq[i+2]) + $signed(mq[i+4]);
            if (i == 0 || mq[i] != mq[i-5]) btns = {btns, $sformatf(" %02x", mq[i])};
        end
    end
endtask

task automatic expect_k(input bit [7:0] e [], input string what);
    begin
        bit ok;
        ok = (kq.size() == e.size());
        if (ok) foreach (e[i]) if (kq[i] != e[i]) ok = 0;
        check(ok, $sformatf("%s: got %p, expected %p", what, kq, e));
        kq.delete();
    end
endtask

task automatic expect_m(input bit [7:0] e [], input string what);
    begin
        bit ok;
        ok = (mq.size() == e.size());
        if (ok) foreach (e[i]) if (mq[i] != e[i]) ok = 0;
        check(ok, $sformatf("%s: got %p, expected %p", what, mq, e));
        mq.delete();
    end
endtask

initial begin
    $display("tb_mister_kbd_mouse: sun2_mister_kbd_mouse on both serial lines");
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (BT * 4) @(posedge clk);

    send_cmd(8'h01); drain(4);
    expect_k('{8'hFF, 8'h03}, "reset answers 0xFF then type 3");

    key(1, 0, 8'h1C); key(0, 0, 8'h1C); drain(4);
    expect_k('{8'h4D, 8'hCD, 8'h7F}, "A: make 0x4D (ktab.s2.c), break, IDLE");

    key(1, 0, 8'h12); key(1, 0, 8'h1C); key(0, 0, 8'h1C); key(0, 0, 8'h12); drain(6);
    expect_k('{8'h63, 8'h4D, 8'hCD, 8'hE3, 8'h7F}, "Shift-A: IDLE only after the last key");

    key(1, 0, 8'h1C); key(1, 0, 8'h1C); key(1, 0, 8'h1C); key(0, 0, 8'h1C); drain(4);
    expect_k('{8'h4D, 8'hCD, 8'h7F}, "auto-repeat makes are dropped");

    key(1, 1, 8'h75); key(0, 1, 8'h75); drain(4);
    expect_k('{8'h45, 8'hC5, 8'h7F}, "Up arrow (E0 75) is R8, 0x45");

    key(1, 0, 8'h5A); key(0, 0, 8'h5A); key(1, 0, 8'h29); key(0, 0, 8'h29);
    key(1, 0, 8'h76); key(0, 0, 8'h76); key(1, 0, 8'h1A); key(0, 0, 8'h1A); drain(8);
    expect_k('{8'h59, 8'hD9, 8'h7F, 8'h79, 8'hF9, 8'h7F, 8'h1D, 8'h9D, 8'h7F, 8'h64, 8'hE4, 8'h7F},
             "Return 0x59, Space 0x79, Esc 0x1D, Z 0x64");

    // the left block: Right Alt (E0 11) held with F1..F10; Right Alt itself sends nothing
    key(1, 1, 8'h11); key(1, 0, 8'h05); key(1, 0, 8'h1C); key(0, 0, 8'h1C); key(0, 0, 8'h05); key(0, 1, 8'h11);
    drain(6);
    expect_k('{8'h01, 8'h4D, 8'hCD, 8'h81, 8'h7F}, "Right Alt+F1 is L1, so L1-A is the abort");

    key(1, 1, 8'h11); key(1, 0, 8'h03); key(0, 1, 8'h11); key(1, 0, 8'h03); key(0, 0, 8'h03); drain(4);
    expect_k('{8'h31, 8'hB1, 8'h7F}, "F5 down as L5 stays L5 through Right Alt's release and a repeat");

    key(1, 1, 8'h11);
    key(1, 0, 8'h06); key(0, 0, 8'h06); key(1, 0, 8'h04); key(0, 0, 8'h04);
    key(1, 0, 8'h0C); key(0, 0, 8'h0C); key(1, 0, 8'h0B); key(0, 0, 8'h0B);
    key(1, 0, 8'h83); key(0, 0, 8'h83); key(1, 0, 8'h0A); key(0, 0, 8'h0A);
    key(1, 0, 8'h01); key(0, 0, 8'h01); key(1, 0, 8'h09); key(0, 0, 8'h09);
    key(0, 1, 8'h11); drain(30);
    expect_k('{8'h03, 8'h83, 8'h7F, 8'h19, 8'h99, 8'h7F, 8'h1A, 8'h9A, 8'h7F, 8'h33, 8'hB3, 8'h7F,
               8'h48, 8'hC8, 8'h7F, 8'h49, 8'hC9, 8'h7F, 8'h5F, 8'hDF, 8'h7F, 8'h61, 8'hE1, 8'h7F},
             "Right Alt+F2..F10 are L2..L10");

    key(1, 0, 8'h03); key(0, 0, 8'h03); key(1, 0, 8'h01); key(0, 0, 8'h01); drain(6);
    expect_k('{8'h0C, 8'h8C, 8'h7F, 8'h12, 8'h92, 8'h7F}, "plain F5, F9 are T5, T9");

    key(1, 0, 8'h09); key(0, 0, 8'h09); key(1, 0, 8'h7E); key(0, 0, 8'h7E); key(1, 0, 8'h07); key(0, 0, 8'h07);
    drain(4);
    expect_k('{}, "plain F10, Scroll Lock and F12 send nothing (MiSTer keeps the last two)");

    key(1, 0, 8'hE5); key(0, 0, 8'hE5); drain(2);
    expect_k('{}, "an unmapped key sends nothing");

    // a burst: twenty events, each sooner than the line can send one byte
    for (int i = 0; i < 10; i++) begin
        @(negedge clk); ps2_key = {~ps2_key[10], 1'b1, 1'b0, 8'h15}; repeat (BT * 3) @(posedge clk);
        @(negedge clk); ps2_key = {~ps2_key[10], 1'b0, 1'b0, 8'h15}; repeat (BT * 3) @(posedge clk);
    end
    drain(40);
    begin
        bit [7:0] e [];
        e = new[30];
        for (int i = 0; i < 10; i++) begin e[3*i] = 8'h36; e[3*i+1] = 8'hB6; e[3*i+2] = 8'h7F; end
        expect_k(e, "a burst of 20 events, faster than the line, all delivered in order");
    end

    // ---- the beeper ----
    check(beeps.size() == 0 && beep_len == 0,
          $sformatf("no click before the host enables it: %0d beeps through every key above", beeps.size()));

    send_cmd(8'h02); repeat (BT * 4) @(posedge clk);
    check(beeper == 1'b1, "0x02 rings the bell");
    repeat (CLICK * 4) @(posedge clk);
    check(beeper == 1'b1, "... for as long as the host likes, not a click's length");
    send_cmd(8'h03); repeat (BT * 4) @(posedge clk);
    check(beeper == 1'b0 && beeps.size() == 1, "0x03 stops it");
    beeps.delete();

    send_cmd(8'h0A);
    key(1, 0, 8'h1C); key(0, 0, 8'h1C); drain(4);
    expect_k('{8'h4D, 8'hCD, 8'h7F}, "with the click on, the key still sends its codes");
    check(beeps.size() == 1 && beeps[0] >= CLICK - 1 && beeps[0] <= CLICK + 1,
          $sformatf("0x0A: one click of 5 ms (%0d clocks) for a press and release: %p", CLICK, beeps));
    beeps.delete();

    key(1, 0, 8'h1C); key(1, 0, 8'h1C); key(1, 0, 8'h1C); key(0, 0, 8'h1C);
    key(1, 0, 8'h12); key(1, 0, 8'h1B); key(0, 0, 8'h1B); key(0, 0, 8'h12);
    key(1, 1, 8'h11); key(0, 1, 8'h11);
    drain(8);
    kq.delete();
    check(beeps.size() == 3,
          $sformatf("a click per make: A with its repeats, Shift, S -- not Right Alt, which sends nothing (%0d)", beeps.size()));
    beeps.delete();

    send_cmd(8'h0B);
    key(1, 0, 8'h1C); key(0, 0, 8'h1C); drain(4);
    kq.delete();
    check(beeps.size() == 0, "0x0B: no more clicks");

    send_cmd(8'h0A); send_cmd(8'h02); repeat (BT * 4) @(posedge clk);
    send_cmd(8'h01); drain(4);
    expect_k('{8'hFF, 8'h03}, "RESET with the bell ringing answers as always");
    check(beeper == 1'b0, "RESET silences the bell");
    beeps.delete();
    key(1, 0, 8'h1C); key(0, 0, 8'h1C); drain(4);
    kq.delete();
    check(beeps.size() == 0, "RESET turns the click off");

    // a glitch on the command line, shorter than half a bit
    @(negedge clk); kbd_rx = 0; repeat (BT / 4) @(posedge clk); kbd_rx = 1;
    drain(4);
    expect_k('{}, "a glitch is not a byte");

    // mouse: {L, M, R}
    mouse(3'b100, 5, 3);
    expect_m('{8'h83, 8'h05, 8'h03, 8'h00, 8'h00}, "left button down, dx 5, dy 3 (up positive)");
    mouse(3'b000, -7, -2);
    expect_m('{8'h87, 8'hF9, 8'hFE, 8'h00, 8'h00}, "no buttons, dx -7, dy -2");
    // More than a packet holds: each delta within -112..127, a packet's two
    // together within -128..127, and the rest in the next packet, not lost.
    mouse(3'b011, -200, 200);
    drain(6);
    expect_m('{8'h84, 8'h90, 8'h7F, 8'hF0, 8'h00, 8'h84, 8'hB8, 8'h49, 8'h00, 8'h00},
             "right and middle, -200 and 200 split over two packets, none lost");
    mouse(3'b001, 1, -1);
    expect_m('{8'h86, 8'h01, 8'hFF, 8'h00, 8'h00}, "right alone is 1, not the middle's 2");

    // A stream of events faster than a packet each -- Main sends up to ~66 a
    // second against the line's 24 packets -- loses no motion.
    begin
        bit ok; int sx, sy; string b;
        for (int i = 0; i < 30; i++) begin
            mouse_now(3'b000, 10, -4);
            repeat (BT * 10) @(posedge clk);            // one byte time apart
        end
        drain(20);
        decode_m(ok, sx, sy, b);
        check(ok && sx == 300 && sy == 120,
              $sformatf("30 events a byte time apart: every count arrives (x %0d of 300, y %0d of 120, %0d bytes)",
                        sx, sy, mq.size()));
        check(mq.size() < 30 * 5, $sformatf("... in fewer packets than events (%0d bytes)", mq.size()));
        mq.delete();
    end

    // A click in the middle of motion: the press and the release both reach
    // the Sun, in order, even when they come closer together than a packet.
    begin
        bit ok; int sx, sy; string b;
        for (int i = 0; i < 8; i++) begin
            mouse_now(3'b000, 6, 0);
            repeat (BT * 10) @(posedge clk);
        end
        mouse_now(3'b100, 0, 0);                        // left down
        repeat (BT * 3) @(posedge clk);
        mouse_now(3'b000, 0, 0);                        // and up again, a third of a byte later
        repeat (BT * 10) @(posedge clk);
        for (int i = 0; i < 8; i++) begin
            mouse_now(3'b000, 6, 0);
            repeat (BT * 10) @(posedge clk);
        end
        drain(20);
        decode_m(ok, sx, sy, b);
        check(ok && b == " 87 83 87" && sx == 96,
              $sformatf("a click while moving: buttons%s, want 87 83 87; x %0d of 96", b, sx));
        mq.delete();
    end

    // A fast flick: the backlog is capped, so the pointer stops soon after
    // the hand does instead of coasting on.
    begin
        int at_stop;
        for (int i = 0; i < 20; i++) begin
            mouse_now(3'b000, 250, 0);
            repeat (BT * 10) @(posedge clk);
        end
        at_stop = mq.size();
        drain(40);
        check(mq.size() - at_stop <= 20,
              $sformatf("a flick: %0d bytes after the last event, at most four packets", mq.size() - at_stop));
        mq.delete();
    end

    check(framing == 0, $sformatf("%0d bytes with a bad stop bit", framing));

    $display("");
    $display("tb_mister_kbd_mouse: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
