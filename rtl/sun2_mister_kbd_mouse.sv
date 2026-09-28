//
// sun2_mister_kbd_mouse.sv
//
// Converts MiSTer PS/2 keyboard and mouse inputs into Sun serial Type 4 keyboard
// and Mouse Systems protocols at 1200 baud (8N1).
// Keycode translation tables derived from TEMLIB ts_ps2sun.vhd.
//
`timescale 1ns / 1ps

module sun2_mister_kbd_mouse #(
    parameter int CLK_HZ = 40_000_000
) (
    input  wire        clk,
    input  wire        rst,

    // MiSTer PS/2 inputs
    input  wire [10:0] ps2_key,
    input  wire [24:0] ps2_mouse,

    // Sun SCC serial interface
    output reg         kbd_ser_tx,   // to SCC Ch A rxda
    input  wire        kbd_ser_rx,   // from SCC Ch A txda
    output reg         mouse_ser_tx, // to SCC Ch B rxdb

    // Peripherals
    output reg         bell,
    output reg  [3:0]  leds          // Caps, Scroll, Compose, Num
);

    localparam int BIT_TICKS = CLK_HZ / 1200;

    // =========================================================================
    // UART Transmitter (Generates 1200 baud 8N1 serial from byte FIFO)
    // =========================================================================
    reg [7:0]  kbd_fifo [0:15];
    reg [3:0]  kbd_wptr = 0, kbd_rptr = 0;
    reg [15:0] kbd_baud_cnt = 0;
    reg [3:0]  kbd_bit_idx = 0;
    reg [9:0]  kbd_tx_shift = 10'h3FF;
    reg        kbd_transmitting = 0;

    wire kbd_fifo_empty = (kbd_wptr == kbd_rptr);

    task kbd_send_byte(input [7:0] b);
        begin
            kbd_fifo[kbd_wptr] <= b;
            kbd_wptr <= kbd_wptr + 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            kbd_rptr         <= 0;
            kbd_baud_cnt     <= 0;
            kbd_bit_idx      <= 0;
            kbd_tx_shift     <= 10'h3FF;
            kbd_ser_tx       <= 1'b1;
            kbd_transmitting <= 0;
        end else begin
            if (!kbd_transmitting) begin
                kbd_ser_tx <= 1'b1;
                if (!kbd_fifo_empty) begin
                    kbd_tx_shift     <= {1'b1, kbd_fifo[kbd_rptr], 1'b0}; // 1 stop, 8 data, 1 start
                    kbd_rptr         <= kbd_rptr + 1'b1;
                    kbd_baud_cnt     <= 0;
                    kbd_bit_idx      <= 0;
                    kbd_transmitting <= 1;
                end
            end else begin
                if (kbd_baud_cnt < BIT_TICKS - 1) begin
                    kbd_baud_cnt <= kbd_baud_cnt + 1'b1;
                end else begin
                    kbd_baud_cnt <= 0;
                    kbd_ser_tx   <= kbd_tx_shift[0];
                    kbd_tx_shift <= {1'b1, kbd_tx_shift[9:1]};
                    kbd_bit_idx  <= kbd_bit_idx + 1'b1;
                    if (kbd_bit_idx == 9) begin
                        kbd_transmitting <= 0;
                    end
                end
            end
        end
    end

    // =========================================================================
    // UART Receiver on Keyboard Line (Commands from Sun host to keyboard)
    // =========================================================================
    reg [15:0] rx_baud_cnt = 0;
    reg [3:0]  rx_bit_idx = 0;
    reg [7:0]  rx_shift = 0;
    reg        rx_busy = 0;
    reg        kbd_rx_sync0 = 1, kbd_rx_sync1 = 1;
    reg        rx_byte_ready = 0;
    reg [7:0]  rx_byte = 0;

    always @(posedge clk) begin
        kbd_rx_sync0 <= kbd_ser_rx;
        kbd_rx_sync1 <= kbd_rx_sync0;
        rx_byte_ready <= 0;

        if (rst) begin
            rx_busy <= 0;
            bell    <= 0;
            leds    <= 0;
        end else begin
            if (!rx_busy) begin
                if (!kbd_rx_sync1) begin // Start bit detected
                    rx_busy     <= 1;
                    rx_baud_cnt <= BIT_TICKS / 2; // sample at middle of bit
                    rx_bit_idx  <= 0;
                end
            end else begin
                if (rx_baud_cnt < BIT_TICKS - 1) begin
                    rx_baud_cnt <= rx_baud_cnt + 1'b1;
                end else begin
                    rx_baud_cnt <= 0;
                    rx_bit_idx  <= rx_bit_idx + 1'b1;
                    if (rx_bit_idx < 8) begin
                        rx_shift <= {kbd_rx_sync1, rx_shift[7:1]};
                    end else if (rx_bit_idx == 8) begin
                        rx_busy       <= 0;
                        rx_byte       <= rx_shift;
                        rx_byte_ready <= 1;
                    end
                end
            end

            // Process command byte
            if (rx_byte_ready) begin
                case (rx_byte)
                    8'h01: begin // Reset command
                        kbd_send_byte(8'hFF); // Self-test OK
                        kbd_send_byte(8'h04); // Type 4
                        kbd_send_byte(8'h7F); // All keys up
                    end
                    8'h02: bell <= 1'b1; // Bell ON
                    8'h03: bell <= 1'b0; // Bell OFF
                    8'h0A: ;             // Click ON
                    8'h0B: ;             // Click OFF
                    8'h0F: begin         // Layout query
                        kbd_send_byte(8'hFE);
                        kbd_send_byte(8'h21); // US layout
                    end
                    default: ;
                endcase
            end
        end
    end

    // =========================================================================
    // PS/2 to Sun Keyboard Translation LUT (Set 2 Scancodes)
    // =========================================================================
    function [7:0] ps2_to_sun(input [7:0] sc, input is_ext);
        begin
            if (!is_ext) begin
                case (sc)
                    8'h01: ps2_to_sun = 8'h12; // F9
                    8'h03: ps2_to_sun = 8'h0C; // F5
                    8'h04: ps2_to_sun = 8'h08; // F3
                    8'h05: ps2_to_sun = 8'h05; // F1
                    8'h06: ps2_to_sun = 8'h06; // F2
                    8'h07: ps2_to_sun = 8'h0B; // F12
                    8'h09: ps2_to_sun = 8'h07; // F10
                    8'h0A: ps2_to_sun = 8'h11; // F8
                    8'h0B: ps2_to_sun = 8'h0E; // F6
                    8'h0C: ps2_to_sun = 8'h0A; // F4
                    8'h0D: ps2_to_sun = 8'h35; // Tab
                    8'h0E: ps2_to_sun = 8'h2A; // ` ~
                    8'h11: ps2_to_sun = 8'h13; // Left Alt
                    8'h12: ps2_to_sun = 8'h63; // Left Shift
                    8'h14: ps2_to_sun = 8'h4C; // Left Ctrl
                    8'h15: ps2_to_sun = 8'h4D; // Q
                    8'h16: ps2_to_sun = 8'h1E; // 1
                    8'h1A: ps2_to_sun = 8'h37; // Z
                    8'h1B: ps2_to_sun = 8'h4E; // S
                    8'h1C: ps2_to_sun = 8'h36; // A
                    8'h1D: ps2_to_sun = 8'h64; // W
                    8'h1E: ps2_to_sun = 8'h1F; // 2
                    8'h21: ps2_to_sun = 8'h66; // C
                    8'h22: ps2_to_sun = 8'h65; // X
                    8'h23: ps2_to_sun = 8'h4F; // D
                    8'h24: ps2_to_sun = 8'h38; // E
                    8'h25: ps2_to_sun = 8'h21; // 4
                    8'h26: ps2_to_sun = 8'h20; // 3
                    8'h29: ps2_to_sun = 8'h79; // Space
                    8'h2A: ps2_to_sun = 8'h67; // V
                    8'h2B: ps2_to_sun = 8'h50; // F
                    8'h2C: ps2_to_sun = 8'h3A; // T
                    8'h2D: ps2_to_sun = 8'h39; // R
                    8'h2E: ps2_to_sun = 8'h22; // 5
                    8'h31: ps2_to_sun = 8'h69; // N
                    8'h32: ps2_to_sun = 8'h68; // B
                    8'h33: ps2_to_sun = 8'h52; // H
                    8'h34: ps2_to_sun = 8'h51; // G
                    8'h35: ps2_to_sun = 8'h3B; // Y
                    8'h36: ps2_to_sun = 8'h23; // 6
                    8'h3A: ps2_to_sun = 8'h6A; // M
                    8'h3B: ps2_to_sun = 8'h53; // J
                    8'h3C: ps2_to_sun = 8'h3C; // U
                    8'h3D: ps2_to_sun = 8'h24; // 7
                    8'h3E: ps2_to_sun = 8'h25; // 8
                    8'h41: ps2_to_sun = 8'h6B; // , <
                    8'h42: ps2_to_sun = 8'h54; // K
                    8'h43: ps2_to_sun = 8'h3D; // I
                    8'h44: ps2_to_sun = 8'h3E; // O
                    8'h45: ps2_to_sun = 8'h27; // 0
                    8'h46: ps2_to_sun = 8'h26; // 9
                    8'h49: ps2_to_sun = 8'h6C; // . >
                    8'h4A: ps2_to_sun = 8'h6D; // / ?
                    8'h4B: ps2_to_sun = 8'h55; // L
                    8'h4C: ps2_to_sun = 8'h56; // ; :
                    8'h4D: ps2_to_sun = 8'h3F; // P
                    8'h4E: ps2_to_sun = 8'h28; // - _
                    8'h52: ps2_to_sun = 8'h57; // ' "
                    8'h54: ps2_to_sun = 8'h40; // [ {
                    8'h55: ps2_to_sun = 8'h29; // = +
                    8'h58: ps2_to_sun = 8'h77; // Caps Lock
                    8'h59: ps2_to_sun = 8'h6E; // Right Shift
                    8'h5A: ps2_to_sun = 8'h59; // Enter
                    8'h5B: ps2_to_sun = 8'h41; // ] }
                    8'h5D: ps2_to_sun = 8'h58; // \ |
                    8'h66: ps2_to_sun = 8'h2B; // Backspace
                    8'h69: ps2_to_sun = 8'h70; // Keypad 1
                    8'h6B: ps2_to_sun = 8'h5B; // Keypad 4
                    8'h6C: ps2_to_sun = 8'h44; // Keypad 7
                    8'h70: ps2_to_sun = 8'h5E; // Keypad 0
                    8'h71: ps2_to_sun = 8'h32; // Keypad .
                    8'h72: ps2_to_sun = 8'h71; // Keypad 2
                    8'h73: ps2_to_sun = 8'h5C; // Keypad 5
                    8'h74: ps2_to_sun = 8'h5D; // Keypad 6
                    8'h75: ps2_to_sun = 8'h45; // Keypad 8
                    8'h76: ps2_to_sun = 8'h1D; // Escape
                    8'h77: ps2_to_sun = 8'h62; // NumLock
                    8'h78: ps2_to_sun = 8'h09; // F11
                    8'h79: ps2_to_sun = 8'h7D; // Keypad +
                    8'h7A: ps2_to_sun = 8'h72; // Keypad 3
                    8'h7B: ps2_to_sun = 8'h47; // Keypad -
                    8'h7C: ps2_to_sun = 8'h2F; // Keypad *
                    8'h7D: ps2_to_sun = 8'h46; // Keypad 9
                    8'h7E: ps2_to_sun = 8'h17; // Scroll Lock
                    8'h83: ps2_to_sun = 8'h10; // F7
                    default: ps2_to_sun = 8'h00;
                endcase
            end else begin
                // Extended keys (E0 prefix)
                case (sc)
                    8'h11: ps2_to_sun = 8'h0D; // Right Alt
                    8'h14: ps2_to_sun = 8'h4C; // Right Ctrl
                    8'h1F: ps2_to_sun = 8'h78; // Left GUI
                    8'h27: ps2_to_sun = 8'h7A; // Right GUI
                    8'h2F: ps2_to_sun = 8'h43; // Menu / Compose
                    8'h4A: ps2_to_sun = 8'h2E; // Keypad /
                    8'h5A: ps2_to_sun = 8'h5A; // Keypad Enter
                    8'h69: ps2_to_sun = 8'h4A; // End
                    8'h6B: ps2_to_sun = 8'h18; // Left Arrow
                    8'h6C: ps2_to_sun = 8'h34; // Home
                    8'h70: ps2_to_sun = 8'h2C; // Insert
                    8'h71: ps2_to_sun = 8'h42; // Delete
                    8'h72: ps2_to_sun = 8'h1B; // Down Arrow
                    8'h74: ps2_to_sun = 8'h1C; // Right Arrow
                    8'h75: ps2_to_sun = 8'h14; // Up Arrow
                    8'h7A: ps2_to_sun = 8'h7B; // Page Down
                    8'h7D: ps2_to_sun = 8'h60; // Page Up
                    default: ps2_to_sun = 8'h00;
                endcase
            end
        end
    endfunction

    // Process MiSTer keyboard events
    reg old_key_strobe = 0;
    always @(posedge clk) begin
        if (rst) begin
            old_key_strobe <= 0;
            kbd_wptr       <= 0;
        end else begin
            if (ps2_key[10] != old_key_strobe) begin
                reg [7:0] sun_sc;
                old_key_strobe <= ps2_key[10];
                sun_sc = ps2_to_sun(ps2_key[7:0], ps2_key[8]);
                if (sun_sc != 8'h00) begin
                    if (!ps2_key[9]) begin
                        // Make (key press)
                        kbd_send_byte(sun_sc);
                    end else begin
                        // Break (key release)
                        kbd_send_byte(sun_sc | 8'h80);
                    end
                end
            end
        end
    end

    // =========================================================================
    // Mouse Transmitter (Mouse Systems 5-byte protocol at 1200 baud 8N1)
    // =========================================================================
    reg [7:0]  mouse_fifo [0:15];
    reg [3:0]  mouse_wptr = 0, mouse_rptr = 0;
    reg [15:0] mouse_baud_cnt = 0;
    reg [3:0]  mouse_bit_idx = 0;
    reg [9:0]  mouse_tx_shift = 10'h3FF;
    reg        mouse_transmitting = 0;

    wire mouse_fifo_empty = (mouse_wptr == mouse_rptr);

    task mouse_send_byte(input [7:0] b);
        begin
            mouse_fifo[mouse_wptr] <= b;
            mouse_wptr <= mouse_wptr + 1'b1;
        end
    endtask

    always @(posedge clk) begin
        if (rst) begin
            mouse_rptr         <= 0;
            mouse_baud_cnt     <= 0;
            mouse_bit_idx      <= 0;
            mouse_tx_shift     <= 10'h3FF;
            mouse_ser_tx       <= 1'b1;
            mouse_transmitting <= 0;
        end else begin
            if (!mouse_transmitting) begin
                mouse_ser_tx <= 1'b1;
                if (!mouse_fifo_empty) begin
                    mouse_tx_shift     <= {1'b1, mouse_fifo[mouse_rptr], 1'b0};
                    mouse_rptr         <= mouse_rptr + 1'b1;
                    mouse_baud_cnt     <= 0;
                    mouse_bit_idx      <= 0;
                    mouse_transmitting <= 1;
                end
            end else begin
                if (mouse_baud_cnt < BIT_TICKS - 1) begin
                    mouse_baud_cnt <= mouse_baud_cnt + 1'b1;
                end else begin
                    mouse_baud_cnt <= 0;
                    mouse_ser_tx   <= mouse_tx_shift[0];
                    mouse_tx_shift <= {1'b1, mouse_tx_shift[9:1]};
                    mouse_bit_idx  <= mouse_bit_idx + 1'b1;
                    if (mouse_bit_idx == 9) begin
                        mouse_transmitting <= 0;
                    end
                end
            end
        end
    end

    // Process MiSTer mouse events
    reg old_mouse_strobe = 0;
    always @(posedge clk) begin
        if (rst) begin
            old_mouse_strobe <= 0;
            mouse_wptr       <= 0;
        end else begin
            if (ps2_mouse[24] != old_mouse_strobe) begin
                reg [7:0] header;
                reg signed [7:0] dx;
                reg signed [7:0] dy;

                old_mouse_strobe <= ps2_mouse[24];
                // Mouse Systems header: 1 0 0 0 0 ~L ~M ~R
                header = {5'b10000, ~ps2_mouse[0], ~ps2_mouse[2], ~ps2_mouse[1]};
                dx = ps2_mouse[15:8];
                dy = -ps2_mouse[23:16]; // Invert Y delta for Sun

                mouse_send_byte(header);
                mouse_send_byte(dx);
                mouse_send_byte(dy);
                mouse_send_byte(8'h00);
                mouse_send_byte(8'h00);
            end
        end
    end

endmodule
