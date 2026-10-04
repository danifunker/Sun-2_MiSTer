`timescale 1ns / 1ps
//
// sun2_cgtwo_scanout.sv -- the colour board's picture.
//
// 1152x900 pixels, a byte each, out of SDRAM through the active (ECL) colour
// map, in the same 1160x904 raster as the mono screen.  The pixels are the
// board's megabyte, pixel n at byte n, so a 16-byte line is 16 consecutive
// pixels and a screen line is 72 of them.
//
// Two clocks:
//
//   mclk       the memory's, where lines are fetched and the colour map is
//              written (sun2_cgtwo's copy at retrace)
//   clk_pixel  the raster's
//
// **The fetch runs ahead.**  Lines are kept in a ring of four, and the fetcher
// may be up to three lines ahead of the one on screen.  Scan-out needs 62 MB/s
// of an SDRAM that the CPU shares, and taking it as soon as it is asked for
// would stop the CPU dead for the 10 us a line costs, every line.  So the
// fetcher asks politely -- the SDRAM adapter takes turns -- until it is about to
// run dry (`urgent': the next line to be shown is not complete), and only then
// demands priority.
//
// **Latency.**  rgb is two clocks behind cx/cy: the line buffer's registered
// read, then the colour map's.  The board top delays the syncs and DE to match.
//
// **Retrace** is the vertical blank, cy at or past the picture, as a level
// for sun2_cgtwo (which crosses it into its own clock).
//
module sun2_cgtwo_scanout #(
    parameter int FB_W     = 1152,
    parameter int FB_H     = 900,
    parameter int SCREEN_W = 1160,
    parameter int SCREEN_H = 904
) (
    // ---- mclk: lines in, colour map in ------------------------------------
    input  wire         mclk,
    input  wire         mrst,
    input  wire         enable,         // displayed: fetch nothing otherwise
    output wire [15:0]  c_line,         // line index in the board's megabyte
    output wire         c_req,
    output wire         c_urgent,
    input  wire         c_done,
    input  wire [127:0] c_rdata,
    input  wire         cm_we,
    input  wire [7:0]   cm_addr,
    input  wire [23:0]  cm_data,
    input  wire         video_en,       // the status register's, mclk

    // ---- clk_pixel ---------------------------------------------------------------
    input  wire         clk_pixel,
    input  wire         pix_rst,
    input  wire [11:0]  cx,
    input  wire [10:0]  cy,
    output reg  [23:0]  rgb = 24'd0,
    output wire         retrace
);

    localparam int BEATS = FB_W / 16;                   // 72
    localparam int X0    = (SCREEN_W - FB_W) / 2;       // 4
    localparam int Y0    = (SCREEN_H - FB_H) / 2;       // 2

    // ---- the line ring: four lines of 72 beats, at {line[1:0], beat} -------------
    reg  [127:0] lbuf [0:511];
    // ---- the active colour map ------------------------------------------------------
    reg  [23:0]  cmap [0:255];

    // ==================================================================
    // clk_pixel
    // ==================================================================
    wire        in_y   = (cy >= Y0) && (cy < Y0 + FB_H);
    wire        in_x   = (cx >= X0) && (cx < X0 + FB_W);
    wire [10:0] row    = cy - Y0[10:0];
    wire [10:0] col    = cx[10:0] - X0[10:0];

    assign retrace = (cy >= SCREEN_H);

    // Toggles for the fetcher: the start of vertical blank begins a frame's
    // fetch (the 33 blank lines are plenty for three lines ahead), and the
    // start of each displayed line says the line before it is finished with.
    reg fs_tgl = 1'b0, ls_tgl = 1'b0;
    always @(posedge clk_pixel)
        if (pix_rst) begin
            fs_tgl <= 1'b0;
            ls_tgl <= 1'b0;
        end else begin
            if (cx == 0 && cy == SCREEN_H) fs_tgl <= ~fs_tgl;
            if (cx == 0 && in_y)           ls_tgl <= ~ls_tgl;
        end

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg ven_s1 = 1'b0;
    reg ven_s2 = 1'b0;
    always @(posedge clk_pixel) begin
        ven_s1 <= video_en;
        ven_s2 <= ven_s1;
    end

    // stage 0: the line buffer's address; stage 1: the byte, and the colour
    // map's address; stage 2: the colour
    reg  [127:0] beat_q = 128'd0;
    reg  [3:0]   j1 = 4'd0;
    reg          vis1 = 1'b0, vis2 = 1'b0;
    reg  [23:0]  cm_q = 24'd0;
    wire [7:0]   pix1 = beat_q[{j1[3:1], ~j1[0], 3'b000} +: 8];

    always @(posedge clk_pixel) begin
        beat_q <= lbuf[{row[1:0], col[10:4]}];
        j1     <= col[3:0];
        vis1   <= in_x & in_y;
        cm_q   <= cmap[pix1];
        vis2   <= vis1;
        rgb    <= (vis2 & ven_s2) ? cm_q : 24'd0;
    end

    // ==================================================================
    // mclk
    // ==================================================================
    always @(posedge mclk)
        if (cm_we) cmap[cm_addr] <= cm_data;

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg fs_s1 = 1'b0, ls_s1 = 1'b0;
    reg fs_s2 = 1'b0, ls_s2 = 1'b0, fs_s3 = 1'b0, ls_s3 = 1'b0;
    always @(posedge mclk) begin
        fs_s1 <= fs_tgl; fs_s2 <= fs_s1; fs_s3 <= fs_s2;
        ls_s1 <= ls_tgl; ls_s2 <= ls_s1; ls_s3 <= ls_s2;
    end
    wire fs_pulse = fs_s2 ^ fs_s3;
    wire ls_pulse = ls_s2 ^ ls_s3;

    reg  [10:0] fetch_row = 11'd0;      // next line to fetch
    reg  [10:0] shown     = 11'd0;      // lines whose display has begun
    reg  [6:0]  beat      = 7'd0;

    wire        active = enable && (fetch_row < FB_H[10:0]) && (fetch_row < shown + 11'd3);
    assign c_req    = active;
    assign c_urgent = active && (fetch_row <= shown);
    assign c_line   = 16'(fetch_row) * 16'(BEATS) + 16'(beat);

    always @(posedge mclk) begin
        if (mrst || fs_pulse) begin
            fetch_row <= 11'd0;
            shown     <= 11'd0;
            beat      <= 7'd0;
        end else begin
            if (ls_pulse)
                shown <= shown + 11'd1;
            if (active && c_done) begin
                if (beat == 7'(BEATS - 1)) begin
                    beat      <= 7'd0;
                    fetch_row <= fetch_row + 11'd1;
                end else
                    beat <= beat + 7'd1;
            end
        end
    end

    always @(posedge mclk)
        if (active && c_done)
            lbuf[{fetch_row[1:0], beat}] <= c_rdata;

endmodule
