//============================================================================
//  tb_emu -- the whole MiSTer core as sys_top sees it: Sun-2.sv's emu module
//  with its real SDRAM controller, disk and keyboard bridges and boot PROM
//  loader.  Only the framework is stood in for: tb/verilator/pll_stub.sv for
//  the PLLs, tb/verilator/hps_io_model.sv for hps_io, and sdram_model.sv for
//  the SDRAM chip on the board.
//
//  What it records:
//    screen_<frame>.pgm   each time the picture changes, the 1160x904 raster
//                         as an 8-bit greyscale image (tools/pgm2png turns it
//                         into a PNG)
//    console.log          anything on the serial port, 9600 8N1
//    the log              the PROM's diagnostic LEDs as they change, every bus
//                         error with its time, the LEDs, a heartbeat
//
//  Plusargs (and hps_io_model.sv's): +timeout_ms=<ms> (default 3000),
//  +heartbeat_ms=<ms> (default 100).
//
//      make -C tb/verilator tb_emu
//============================================================================
`timescale 1ps/1ps

module tb_emu;

`include "emu_wires.vh"

// ---- what the board and the framework supply -------------------------------
reg clk50 = 1'b0;
always #10000 clk50 = ~clk50;
assign CLK_50M = clk50;

reg rst = 1'b1;
assign RESET = rst;
initial #500_000 rst = 1'b0;

assign HDMI_WIDTH       = 12'd1920;
assign HDMI_HEIGHT      = 12'd1080;
assign CLK_AUDIO        = 1'b0;
assign SD_MISO          = 1'b1;
assign SD_CD            = 1'b1;
assign DDRAM_BUSY       = 1'b0;
assign DDRAM_DOUT       = 64'd0;
assign DDRAM_DOUT_READY = 1'b0;
assign UART_CTS         = 1'b0;
assign UART_RXD         = 1'b1;
assign UART_DSR         = 1'b0;
assign USER_IN          = 7'h7F;
assign OSD_STATUS       = 1'b0;

emu dut (.*);

sdram_model chip (
    .clk(SDRAM_CLK), .cke(SDRAM_CKE), .nCS(SDRAM_nCS),
    .nRAS(SDRAM_nRAS), .nCAS(SDRAM_nCAS), .nWE(SDRAM_nWE),
    .ba(SDRAM_BA), .a(SDRAM_A), .dqmh(SDRAM_DQMH), .dqml(SDRAM_DQML),
    .dq(SDRAM_DQ)
);

// ---- the screen ----------------------------------------------------------------
localparam int W = 1160, H = 904;
reg  [7:0]  frame [0:W*H-1];
integer     fx = 0, fy = 0, frames = 0, shots = 0;
reg         de_d = 1'b0, vs_d = 1'b1;
reg  [31:0] sum = 32'd0, last_sum = 32'hFFFFFFFF;

task automatic dump_frame(input integer n);
    integer fd;
    string  name;
    begin
        name = $sformatf("screen_%05d.pgm", n);
        fd = $fopen(name, "wb");
        $fwrite(fd, "P5\n%0d %0d\n255\n", W, H);
        for (int i = 0; i < W*H; i++) $fwrite(fd, "%c", frame[i]);
        $fclose(fd);
        $display("[%0t] frame %0d changed: %s", $time, n, name);
    end
endtask

always @(posedge CLK_VIDEO) if (CE_PIXEL) begin
    de_d <= VGA_DE;
    vs_d <= VGA_VS;
    if (VGA_DE) begin
        if (fx < W && fy < H) frame[fy*W + fx] <= VGA_R;
        sum <= {sum[30:0], sum[31]} ^ {24'd0, VGA_R} ^ 32'(fx);
        fx  <= fx + 1;
    end else if (de_d) begin
        fx <= 0;
        fy <= fy + 1;
    end
    if (vs_d && !VGA_VS) begin                  // the start of vertical sync
        frames <= frames + 1;
        if (fy == H && sum != last_sum) begin   // a whole frame, and a new picture
            dump_frame(frames);
            last_sum <= sum;
            shots    <= shots + 1;
        end
        fy  <= 0;
        fx  <= 0;
        sum <= 32'd0;
    end
end

// ---- the serial port: 9600 8N1 ----------------------------------------------------
integer con_fd;
initial con_fd = $fopen("console.log", "w");
initial begin : uart
    localparam longint BIT = 104_166_667;       // ps
    bit [7:0] b;
    forever begin
        @(negedge UART_TXD);
        #(BIT / 2);
        if (UART_TXD == 1'b0) begin
            for (int i = 0; i < 8; i++) begin #BIT; b[i] = UART_TXD; end
            #BIT;
            $fwrite(con_fd, "%c", b); $fflush(con_fd);
            if (b == 8'h0A) $display("[%0t] console: line", $time);
        end
    end
end

// ---- what the machine is doing ------------------------------------------------------
always @(dut.machine.diag_leds)
    $display("[%0t] diag_leds = %02x", $time, dut.machine.diag_leds);

integer berrs = 0;
always @(negedge dut.machine.P_BERR_n) begin
    berrs = berrs + 1;
    $display("[%0t] bus error %0d", $time, berrs);
end

always @(LED_USER) $display("[%0t] LED_USER = %0d (machine %s)", $time, LED_USER, LED_USER ? "in reset" : "running");

initial begin : heartbeat
    real hb;
    if (!$value$plusargs("heartbeat_ms=%f", hb)) hb = 100.0;
    forever begin
        #(longint'(hb * 1.0e9));
        $display("[%0t] %0.0f ms: frames %0d, screens %0d, bus errors %0d, LED_DISK %b",
                 $time, $realtime / 1.0e9, frames, shots, berrs, LED_DISK);
    end
end

initial begin : finish
    real t;
    if (!$value$plusargs("timeout_ms=%f", t)) t = 3000.0;
    #(longint'(t * 1.0e9));
    if (fy > 0) dump_frame(frames);              // whatever is on screen now
    $display("tb_emu: stopped at %0.0f ms: %0d frames, %0d screens, %0d bus errors",
             $realtime / 1.0e9, frames, shots, berrs);
    $fclose(con_fd);
    $finish;
end

endmodule
