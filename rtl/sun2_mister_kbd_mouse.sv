//
// sun2_mister_kbd_mouse.sv
//
// MiSTer's PS/2 keyboard and mouse events as a Sun keyboard and a Mouse
// Systems mouse, on the two serial lines of the keyboard/mouse Z8530, at 1200
// baud 8N1 as the real ones run.
//
// Keyboard.  Up/down codes: the make code on a press, the same | 0x80 on a
// release, and IDLE (0x7F) once the last key is up.  On a RESET command
// (0x01) it answers 0xFF and its type, 3.  The codes are the Sun-2 keyboard's
// wherever it has the key -- sun/prom_monitor/msun/mon/keyboard/ktab.s2.c, the
// table the boot PROM translates with (built with -DKEYBS2) -- and the Type 3
// keyboard's for the keys it lacks (Caps Lock, Alt, the function and keypad
// keys).  The two agree on every key they share, so one map serves the PROM
// and SunOS.  The PROM accepts any type byte after 0xFF and only stores it
// (keyboard/keypress.c, STARTUP2); SunOS uses it to pick its table, and 3
// gets the table with every key mapped here.
//
// The keys a PC keyboard lacks.  The right keypad R1..R15 is the numeric
// keypad and the navigation cluster (the arrows are R8, R10, R12, R14); Meta,
// the Sun-2's "Left" and "Right" keys, is the two Windows keys; Line Feed is
// keypad Enter; the top row T1..T9 is F1..F9.  The left block L1..L10 --
// Stop, Again, Props, Undo, Front, Copy, Open, Paste, Find, Cut, which SunView
// is driven from -- is Right Alt held with F1..F10.  Right Alt itself sends
// nothing (Left Alt is the Sun's Alt), and an F-key remembers how it went down,
// so letting go of Right Alt first cannot leave an L-key held.  L1-A, the
// abort to the monitor, is Right Alt+F1 then A.
//
// Not used, because MiSTer keeps them: Scroll Lock (keyboard-as-joystick
// emulation), F12 (the OSD), F17..F20; and F13..F24 never reach a core.
//
// Mouse.  Mouse Systems five-byte packets, as sun/sys/sundev/ms.c reads them:
// 0x80 | the three buttons active low (left 4, middle 2, right 1), then dx,
// dy, and a second dx, dy.  Up is positive, as on PS/2 -- ms.c does
// `mi_y -= c' -- so Y is passed through, not inverted.  Each delta is kept to
// -112..127, because ms.c takes any byte 0x80..0x8F for a button byte, and the
// two of a packet together to -128..127, because ms.c adds them into one
// clipped byte.
//
// The mouse is sent the way a Mouse Systems mouse sends, not event by event.
// Main_MiSTer sends up to ~66 events a second and 1200 baud carries 24
// packets, so a packet per event cannot keep up: queued, it lags; dropped, it
// loses distance and clicks.  Motion is accumulated instead and drained into a
// packet whenever the line is free, the second dx, dy carrying what built up
// while the first three bytes went out.  Each change of the buttons is kept and
// sent in order, so a click made while moving is never merged away.  The
// backlog is capped at about two packets of motion: past that a fast flick is
// cut short, as a real mouse's counters would cut it, rather than the pointer
// coasting on after the hand has stopped.
//
// Everything runs on one clock.  ps2_key and ps2_mouse come from hps_io's
// clock; their toggle bits are synchronised here and the rest of each word is
// steady by the time the toggle is seen.
//
`timescale 1ns / 1ps

module sun2_mister_kbd_mouse #(
    parameter int CLK_HZ = 20_000_000
) (
    input  wire        clk,
    input  wire        rst,

    input  wire [10:0] ps2_key,         // hps_io: [10] toggle, [9] pressed, [8] E0, [7:0] code
    input  wire [24:0] ps2_mouse,       // hps_io: [24] toggle, [23:16] dy, [15:8] dx, [7:0] status

    output wire        kbd_ser_tx,      // to the SCC's channel A receive
    input  wire        kbd_ser_rx,      // from the SCC's channel A transmit
    output wire        mouse_ser_tx,    // to the SCC's channel B receive

    output reg         bell = 1'b0
);

    localparam int BIT_TICKS = CLK_HZ / 1200;     // 16666 at 20 MHz; 16 bits hold up to 78 MHz

    // ---- 1200-baud transmitters behind 64-byte FIFOs, one writer each -------
    // hps_io keeps only the latest key event, so a burst -- several keys let go
    // at once -- has to fit here or be overwritten before it is read.  64 bytes
    // is over half a second of line time.
    // push/pdata are the FIFO's only write port; `room' is free slots.
    wire       k_push;
    wire [7:0] k_pdata;
    wire [6:0] k_room;
    sun2_kbm_uart_tx #(.BIT_TICKS(BIT_TICKS)) kbd_tx (
        .clk(clk), .rst(rst), .push(k_push), .pdata(k_pdata), .room(k_room), .txd(kbd_ser_tx));

    wire       m_push;
    wire [7:0] m_pdata;
    wire [6:0] m_room;
    sun2_kbm_uart_tx #(.BIT_TICKS(BIT_TICKS)) mouse_tx (
        .clk(clk), .rst(rst), .push(m_push), .pdata(m_pdata), .room(m_room), .txd(mouse_ser_tx));

    // ---- commands from the Sun ------------------------------------------------
    reg [1:0]    rx_s = 2'b11;
    reg          rx_busy = 1'b0;
    reg [15:0]   rx_cnt = 16'd0;
    reg [3:0]    rx_bit = 4'd0;
    reg [7:0]    rx_sh = 8'h0;
    reg          rx_valid = 1'b0;
    reg [7:0]    rx_byte = 8'h0;

    always @(posedge clk) begin
        rx_s     <= {rx_s[0], kbd_ser_rx};
        rx_valid <= 1'b0;
        if (rst) begin
            rx_busy <= 1'b0;
        end else if (!rx_busy) begin
            if (!rx_s[1]) begin                     // a falling edge: a start bit?
                rx_busy <= 1'b1;
                rx_cnt  <= BIT_TICKS / 2;
                rx_bit  <= 4'd0;
            end
        end else if (rx_cnt != 16'd0) begin
            rx_cnt <= rx_cnt - 16'd1;
        end else begin
            // the middle of bit rx_bit: 0 the start bit, 1..8 data, 9 stop
            rx_cnt <= BIT_TICKS - 1;
            rx_bit <= rx_bit + 4'd1;
            if (rx_bit == 4'd0) begin
                if (rx_s[1]) rx_busy <= 1'b0;       // a glitch, not a start bit
            end else if (rx_bit <= 4'd8) begin
                rx_sh <= {rx_s[1], rx_sh[7:1]};     // LSB first
            end else begin
                rx_busy <= 1'b0;
                if (rx_s[1]) begin                  // a good stop bit
                    rx_valid <= 1'b1;
                    rx_byte  <= rx_sh;
                end
            end
        end
    end

    // ---- PS/2 set 2 -> Sun ------------------------------------------------------
    function automatic [7:0] sun_code(input [7:0] sc, input ext);
        if (!ext) case (sc)
            8'h76: sun_code = 8'h1D;    // Esc
            8'h16: sun_code = 8'h1E;    // 1
            8'h1E: sun_code = 8'h1F;    // 2
            8'h26: sun_code = 8'h20;    // 3
            8'h25: sun_code = 8'h21;    // 4
            8'h2E: sun_code = 8'h22;    // 5
            8'h36: sun_code = 8'h23;    // 6
            8'h3D: sun_code = 8'h24;    // 7
            8'h3E: sun_code = 8'h25;    // 8
            8'h46: sun_code = 8'h26;    // 9
            8'h45: sun_code = 8'h27;    // 0
            8'h4E: sun_code = 8'h28;    // -
            8'h55: sun_code = 8'h29;    // =
            8'h0E: sun_code = 8'h2A;    // `
            8'h66: sun_code = 8'h2B;    // Backspace
            8'h0D: sun_code = 8'h35;    // Tab
            8'h15: sun_code = 8'h36;    // Q
            8'h1D: sun_code = 8'h37;    // W
            8'h24: sun_code = 8'h38;    // E
            8'h2D: sun_code = 8'h39;    // R
            8'h2C: sun_code = 8'h3A;    // T
            8'h35: sun_code = 8'h3B;    // Y
            8'h3C: sun_code = 8'h3C;    // U
            8'h43: sun_code = 8'h3D;    // I
            8'h44: sun_code = 8'h3E;    // O
            8'h4D: sun_code = 8'h3F;    // P
            8'h54: sun_code = 8'h40;    // [
            8'h5B: sun_code = 8'h41;    // ]
            8'h14: sun_code = 8'h4C;    // Left Ctrl
            8'h1C: sun_code = 8'h4D;    // A
            8'h1B: sun_code = 8'h4E;    // S
            8'h23: sun_code = 8'h4F;    // D
            8'h2B: sun_code = 8'h50;    // F
            8'h34: sun_code = 8'h51;    // G
            8'h33: sun_code = 8'h52;    // H
            8'h3B: sun_code = 8'h53;    // J
            8'h42: sun_code = 8'h54;    // K
            8'h4B: sun_code = 8'h55;    // L
            8'h4C: sun_code = 8'h56;    // ;
            8'h52: sun_code = 8'h57;    // '
            8'h5D: sun_code = 8'h58;    // backslash
            8'h5A: sun_code = 8'h59;    // Return
            8'h12: sun_code = 8'h63;    // Left Shift
            8'h1A: sun_code = 8'h64;    // Z
            8'h22: sun_code = 8'h65;    // X
            8'h21: sun_code = 8'h66;    // C
            8'h2A: sun_code = 8'h67;    // V
            8'h32: sun_code = 8'h68;    // B
            8'h31: sun_code = 8'h69;    // N
            8'h3A: sun_code = 8'h6A;    // M
            8'h41: sun_code = 8'h6B;    // ,
            8'h49: sun_code = 8'h6C;    // .
            8'h4A: sun_code = 8'h6D;    // /
            8'h59: sun_code = 8'h6E;    // Right Shift
            8'h29: sun_code = 8'h79;    // Space
            8'h11: sun_code = 8'h13;    // Left Alt -> Alt (Type 3)
            8'h58: sun_code = 8'h77;    // Caps Lock (Type 3)
            8'h77: sun_code = 8'h15;    // Num Lock -> R1
            8'h7C: sun_code = 8'h17;    // keypad *  -> R3
            8'h7B: sun_code = 8'h2D;    // keypad -  -> R4
            8'h79: sun_code = 8'h2E;    // keypad +  -> R5
            8'h6C: sun_code = 8'h44;    // keypad 7  -> R7
            8'h75: sun_code = 8'h45;    // keypad 8  -> R8, up
            8'h7D: sun_code = 8'h46;    // keypad 9  -> R9
            8'h6B: sun_code = 8'h5B;    // keypad 4  -> R10, left
            8'h73: sun_code = 8'h5C;    // keypad 5  -> R11
            8'h74: sun_code = 8'h5D;    // keypad 6  -> R12, right
            8'h69: sun_code = 8'h70;    // keypad 1  -> R13
            8'h72: sun_code = 8'h71;    // keypad 2  -> R14, down
            8'h7A: sun_code = 8'h72;    // keypad 3  -> R15
            8'h70: sun_code = 8'h5E;    // keypad 0  -> Insert (Type 3)
            8'h71: sun_code = 8'h32;    // keypad .  -> Delete (Type 3)
            default: sun_code = 8'h00;
        endcase else case (sc)
            8'h14: sun_code = 8'h4C;    // Right Ctrl
            8'h1F: sun_code = 8'h78;    // Left GUI  -> left Meta
            8'h27: sun_code = 8'h7A;    // Right GUI -> right Meta
            8'h75: sun_code = 8'h45;    // Up    -> R8
            8'h6B: sun_code = 8'h5B;    // Left  -> R10
            8'h74: sun_code = 8'h5D;    // Right -> R12
            8'h72: sun_code = 8'h71;    // Down  -> R14
            8'h6C: sun_code = 8'h44;    // Home  -> R7
            8'h7D: sun_code = 8'h46;    // PgUp  -> R9
            8'h69: sun_code = 8'h70;    // End   -> R13
            8'h7A: sun_code = 8'h72;    // PgDn  -> R15
            8'h71: sun_code = 8'h42;    // Delete -> the Sun-2's Delete, beside ]
            8'h70: sun_code = 8'h5E;    // Insert (Type 3)
            8'h5A: sun_code = 8'h6F;    // keypad Enter -> Line Feed
            8'h4A: sun_code = 8'h16;    // keypad /  -> R2
            default: sun_code = 8'h00;
        endcase
    endfunction

    // F1..F10 by position, 4'hF for anything else.
    function automatic [3:0] fkey(input [7:0] sc, input ext);
        if (ext) fkey = 4'hF;
        else case (sc)
            8'h05: fkey = 4'd0;   8'h06: fkey = 4'd1;   8'h04: fkey = 4'd2;
            8'h0C: fkey = 4'd3;   8'h03: fkey = 4'd4;   8'h0B: fkey = 4'd5;
            8'h83: fkey = 4'd6;   8'h0A: fkey = 4'd7;   8'h01: fkey = 4'd8;
            8'h09: fkey = 4'd9;
            default: fkey = 4'hF;
        endcase
    endfunction

    // The top row T1..T9 (F10 has none) and the left block L1..L10.
    function automatic [7:0] t_code(input [3:0] i);
        case (i)
            4'd0: t_code = 8'h05;  4'd1: t_code = 8'h06;  4'd2: t_code = 8'h08;
            4'd3: t_code = 8'h0A;  4'd4: t_code = 8'h0C;  4'd5: t_code = 8'h0E;
            4'd6: t_code = 8'h10;  4'd7: t_code = 8'h11;  4'd8: t_code = 8'h12;
            default: t_code = 8'h00;
        endcase
    endfunction
    function automatic [7:0] l_code(input [3:0] i);
        case (i)
            4'd0: l_code = 8'h01;  4'd1: l_code = 8'h03;  4'd2: l_code = 8'h19;
            4'd3: l_code = 8'h1A;  4'd4: l_code = 8'h31;  4'd5: l_code = 8'h33;
            4'd6: l_code = 8'h48;  4'd7: l_code = 8'h49;  4'd8: l_code = 8'h5F;
            4'd9: l_code = 8'h61;
            default: l_code = 8'h00;
        endcase
    endfunction

    // ---- keyboard: the one writer of its FIFO ------------------------------------
    reg [2:0]   key_s = 3'd0;
    reg         key_seen = 1'b0;
    reg [7:0]   kc;                 // temporaries, assigned blocking
    reg [3:0]   kf;
    reg         ralt   = 1'b0;          // Right Alt held: F1..F10 are L1..L10
    reg [9:0]   f_as_l = 10'd0;         // each F-key: did it go down as an L-key?
    reg [9:0]   f_down = 10'd0;         // each F-key: physically held
    reg [127:0] kafter;
    reg [127:0] down  = 128'd0;         // which Sun keys are held
    reg [1:0]   resp  = 2'd0;           // reset answer still to send: 2 = 0xFF, 1 = type
    reg         ev_v  = 1'b0;           // a key event waiting for the FIFO
    reg [7:0]   ev_b  = 8'h0;
    reg         idle_v = 1'b0;          // an IDLE to follow it
    reg         kpush = 1'b0;
    reg [7:0]   kdata = 8'h0;
    assign k_push  = kpush;
    assign k_pdata = kdata;

    always @(posedge clk) begin
        key_s <= {key_s[1:0], ps2_key[10]};
        kpush <= 1'b0;

        if (rst) begin
            down   <= 128'd0;
            key_seen <= key_s[2];
            ralt   <= 1'b0;
            f_as_l <= 10'd0;
            f_down <= 10'd0;
            resp   <= 2'd0;
            ev_v   <= 1'b0;
            idle_v <= 1'b0;
            bell   <= 1'b0;
        end else begin
            // commands
            if (rx_valid) case (rx_byte)
                8'h01: begin resp <= 2'd2; ev_v <= 1'b0; idle_v <= 1'b0; down <= 128'd0; end
                8'h02: bell <= 1'b1;
                8'h03: bell <= 1'b0;
                default: ;                  // click on/off and the rest: nothing to do
            endcase

            // a key from the OSD's keyboard
            // (waits while the previous event is still queued, so none is lost)
            if (key_s[2] != key_seen && !ev_v) begin
                key_seen <= key_s[2];
                kf = fkey(ps2_key[7:0], ps2_key[8]);
                if (ps2_key[8] && ps2_key[7:0] == 8'h11) begin
                    ralt <= ps2_key[9];             // Right Alt: the chord, not a key
                    kc = 8'h00;
                end else if (kf != 4'hF) begin
                    // The mapping is chosen on the first press and kept for its
                    // auto-repeats and its release, whatever Right Alt does since.
                    if (ps2_key[9] && !f_down[kf]) begin
                        f_down[kf] <= 1'b1;
                        f_as_l[kf] <= ralt;
                        kc = ralt ? l_code(kf) : t_code(kf);
                    end else begin
                        if (!ps2_key[9]) f_down[kf] <= 1'b0;
                        kc = f_as_l[kf] ? l_code(kf) : t_code(kf);
                    end
                end else
                    kc = sun_code(ps2_key[7:0], ps2_key[8]);
                if (kc != 8'h00) begin
                    if (ps2_key[9]) begin
                        if (!down[kc[6:0]]) begin  // auto-repeat makes are dropped
                            down[kc[6:0]] <= 1'b1;
                            ev_v <= 1'b1; ev_b <= kc;
                        end
                    end else if (down[kc[6:0]]) begin
                        kafter = down;
                        kafter[kc[6:0]] = 1'b0;
                        down   <= kafter;
                        ev_v   <= 1'b1; ev_b <= kc | 8'h80;
                        idle_v <= (kafter == 128'd0);
                    end
                end
            end

            // one byte a clock into the FIFO, the reset answer first
            if (k_room != 0 && !kpush) begin
                if (resp == 2'd2)      begin kpush <= 1'b1; kdata <= 8'hFF; resp <= 2'd1; end
                else if (resp == 2'd1) begin kpush <= 1'b1; kdata <= 8'h03; resp <= 2'd0; end
                else if (ev_v)         begin kpush <= 1'b1; kdata <= ev_b;  ev_v <= 1'b0; end
                else if (idle_v)       begin kpush <= 1'b1; kdata <= 8'h7F; idle_v <= 1'b0; end
            end
        end
    end

    // ---- mouse: the one writer of its FIFO ----------------------------------------
    // Motion builds up in acc_x/acc_y, capped at +-ACC_MAX; button states wait
    // in bq, oldest in bq[2:0], up to four of them.  A packet starts only when
    // the FIFO is empty -- the line is about to fall idle -- and takes the
    // first three bytes; its dx2, dy2 are taken when those have gone too.
    localparam logic signed [12:0] ACC_MAX = 13'sd255;   // about two packets of motion

    function automatic signed [12:0] lim(input signed [12:0] v,
                                         input signed [12:0] lo, input signed [12:0] hi);
        lim = (v > hi) ? hi : (v < lo) ? lo : v;
    endfunction

    reg [2:0]         ms_s  = 3'd0;
    reg               ms_seen = 1'b0;
    reg signed [12:0] acc_x = 13'sd0, acc_y = 13'sd0;
    reg signed [12:0] dx1 = 13'sd0, dy1 = 13'sd0;   // the first half, for the second's limits
    reg [2:0]         btn_new = 3'b000;              // {L, M, R}, 1 = down, as last seen
    reg [11:0]        bq = 12'd0;
    reg [2:0]         bq_n = 3'd0;
    reg               second = 1'b0;                 // dx2, dy2 still to be taken
    reg [1:0]         npend = 2'd0;                  // bytes in pend0.. still for the FIFO
    reg [7:0]         pend0 = 8'h0, pend1 = 8'h0, pend2 = 8'h0;
    reg               mpush = 1'b0;
    reg [7:0]         mdata = 8'h0;
    assign m_push  = mpush;
    assign m_pdata = mdata;

    reg signed [12:0] ax, ay, ex, ey, hx, hy;        // temporaries, assigned blocking
    reg [11:0]        q;
    reg [2:0]         qn, eb, pb;

    always @(posedge clk) begin
        ms_s  <= {ms_s[1:0], ps2_mouse[24]};
        mpush <= 1'b0;
        if (rst) begin
            ms_seen <= ms_s[2];
            acc_x   <= 13'sd0;
            acc_y   <= 13'sd0;
            btn_new <= 3'b000;
            bq_n    <= 3'd0;
            second  <= 1'b0;
            npend   <= 2'd0;
        end else begin
            ax = acc_x;  ay = acc_y;  q = bq;  qn = bq_n;

            // an event from MiSTer: add its motion, keep its buttons if new
            if (ms_s[2] != ms_seen) begin
                ms_seen <= ms_s[2];
                ex = {{4{ps2_mouse[4]}}, ps2_mouse[4], ps2_mouse[15:8]};
                ey = {{4{ps2_mouse[5]}}, ps2_mouse[5], ps2_mouse[23:16]};
                ax = lim(ax + ex, -ACC_MAX, ACC_MAX);
                ay = lim(ay + ey, -ACC_MAX, ACC_MAX);
                eb = {ps2_mouse[0], ps2_mouse[2], ps2_mouse[1]};
                if (eb != btn_new) begin
                    btn_new <= eb;
                    if (qn != 3'd4) begin
                        q[qn*3 +: 3] = eb;
                        qn = qn + 3'd1;
                    end else
                        q[9 +: 3] = eb;             // four changes in one packet: keep the newest
                end
            end

            if (npend != 2'd0) begin
                // one byte a clock into the FIFO
                mpush <= 1'b1;
                mdata <= pend0;
                pend0 <= pend1;
                pend1 <= pend2;
                npend <= npend - 2'd1;
            end else if (!mpush && m_room == 7'd64) begin
                if (second) begin
                    // dx2, dy2: whatever built up meanwhile, keeping the
                    // packet's total within the byte ms.c adds it into
                    hx = lim(ax, (dx1 < 0) ? (-13'sd128 - dx1) : -13'sd112, 13'sd127 - dx1);
                    hy = lim(ay, (dy1 < 0) ? (-13'sd128 - dy1) : -13'sd112, 13'sd127 - dy1);
                    hx = lim(hx, -13'sd112, 13'sd127);
                    hy = lim(hy, -13'sd112, 13'sd127);
                    ax = ax - hx;  ay = ay - hy;
                    pend0  <= hx[7:0];
                    pend1  <= hy[7:0];
                    npend  <= 2'd2;
                    second <= 1'b0;
                end else if (qn != 3'd0 || ax != 13'sd0 || ay != 13'sd0) begin
                    if (qn != 3'd0) begin
                        pb = q[2:0];
                        q  = q >> 3;
                        qn = qn - 3'd1;
                    end else
                        pb = btn_new;
                    hx = lim(ax, -13'sd112, 13'sd127);
                    hy = lim(ay, -13'sd112, 13'sd127);
                    ax = ax - hx;  ay = ay - hy;
                    dx1    <= hx;
                    dy1    <= hy;
                    pend0  <= {5'b10000, ~pb};
                    pend1  <= hx[7:0];
                    pend2  <= hy[7:0];
                    npend  <= 2'd3;
                    second <= 1'b1;
                end
            end

            acc_x <= ax;  acc_y <= ay;  bq <= q;  bq_n <= qn;
        end
    end

endmodule

// A 1200-baud 8N1 transmitter behind a 64-byte FIFO with a single write port.
module sun2_kbm_uart_tx #(
    parameter int BIT_TICKS = 16666
) (
    input  wire       clk,
    input  wire       rst,
    input  wire       push,
    input  wire [7:0] pdata,
    output wire [6:0] room,             // free slots, 0..64
    output reg        txd = 1'b1
);
    reg [7:0]    fifo [0:63];
    reg [6:0]    wp = 7'd0, rp = 7'd0;  // one extra bit: full and empty differ
    reg [9:0]    sh = 10'h3FF;
    reg [3:0]    nbits = 4'd0;
    reg [15:0]   cnt = 16'd0;

    assign room = 7'd64 - (wp - rp);

    always @(posedge clk) begin
        if (rst) begin
            wp <= 7'd0; rp <= 7'd0; nbits <= 4'd0; txd <= 1'b1;
        end else begin
            if (push && room != 0) begin
                fifo[wp[5:0]] <= pdata;
                wp <= wp + 7'd1;
            end
            if (nbits == 0) begin
                if (wp != rp) begin
                    sh    <= {1'b1, fifo[rp[5:0]], 1'b0};   // stop, data LSB first, start
                    rp    <= rp + 7'd1;
                    nbits <= 4'd10;
                    cnt   <= 16'd0;
                end
            end else if (cnt != BIT_TICKS - 1) begin
                cnt <= cnt + 16'd1;
            end else begin
                cnt <= 16'd0;
                sh  <= {1'b1, sh[9:1]};
                nbits <= nbits - 4'd1;
            end
            txd <= (nbits == 0) ? 1'b1 : sh[0];
        end
    end
endmodule
