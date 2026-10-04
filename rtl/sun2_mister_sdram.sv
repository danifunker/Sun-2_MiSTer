//
// sun2_mister_sdram.sv
//
// The Sun-2's memory on the MiSTer SDRAM board: a Wishbone slave for the
// cached FIFO bridge and a line port for fb_scanout, both in front of
// rtl/sdram.sv (Sorgelig's controller, BL8, CAS 2, at ~100 MHz).  Everything
// here runs on the controller's clock; the bridge's async FIFOs are where the
// CPU's clock is crossed.
//
// Layout.  One 16-byte line is one aligned BL8 burst, and halfword k of the
// line is SDRAM word k -- which is the order both clients already expect:
//
//   * sun2_cached_fifo_bridge installs wb_line_o as eight halfwords, halfword
//     k at [16k+15:16k], and the halfword at A1=0 is wb_dat[15:0] (its q_sel
//     puts the CPU word with A1=0 in the low half of the Wishbone word).  So
//     longword lane l = wb_adr[1:0] is line bits [32l+31:32l].
//   * fb_scanout reads a beat as 128 consecutive pixels with aperture
//     halfword k at [16k+15:16k].
//
//   main memory    Wishbone word w (w < 2 Mi)   -> SDRAM words 2w, 2w+1
//   frame buffer   Wishbone word FB_WB_BASE + r -> SDRAM words FB_SDRAM_WORD + 2r, +1
//   fb_scanout     c_addr (16-bit words, beat-aligned) -> FB_SDRAM_WORD + c_addr
//   colour board   line L (16 bytes, pixels 16L..16L+15) -> CG_SDRAM_WORD + 8L
//
// so 8 MiB of main memory sits at the bottom of the chip, the 128 KiB mono
// frame buffer 16 MiB up and the colour board's megabyte 24 MiB up, inside the
// smallest (32 MB) MiSTer SDRAM module -- and in three different banks, so the
// rows each keeps open stay open.
//
// Four clients.  The two scan-outs have deadlines and the CPU and the colour
// board's engine do not.  The mono scan-out is small (1/8 of a line of SDRAM
// time) and keeps its absolute priority; it is gated off outside when the
// colour board is what is displayed.  The colour scan-out is half the SDRAM, so
// it takes turns with the CPU and the engine and gets priority only when it
// says it is about to run dry (cs_urgent; see sun2_cgtwo_scanout.sv).
//
// Handshakes.  Both clients hold a request until it is answered and only then
// move on, and both see the answer a clock after it is given: the bridge drops
// CYC on the edge it samples wb_ack_o, fb_scanout advances c_addr on the edge
// it samples c_done.  So after every completion this waits one clock (S_GAP)
// before it looks at either request again.  Without that, the request it just
// answered is still visible and is run a second time -- and the answer to the
// repeat completes whatever the client asks for next, with the wrong data.
//
// The controller (rtl/sdram.sv) takes a request as a held level and reports
// completion as the rising edge of `ready': on a read that edge brings the
// first burst word in `dout' and the other seven follow on consecutive clocks;
// on a write it means the WRITE command has issued.  rd is dropped as soon as
// the first word arrives, wr as soon as ready rises, so the controller cannot
// take either again when it comes back to idle.  It wants a refresh toggle
// every 7.8 us; sdram_beat32, which this controller was tested behind, gives
// it one every 764 clocks, and so does this.
//
`timescale 1ns / 1ps

module sun2_mister_sdram #(
    parameter [29:0] FB_WB_BASE    = 30'h03E00000,  // sun2_config.vh's default
    parameter [25:0] FB_SDRAM_WORD = 26'h0800000,   // 16 MiB, in 16-bit words
    parameter [25:0] CG_SDRAM_WORD = 26'h0C00000    // 24 MiB
) (
    input  wire         clk,            // the controller's clock, ~100 MHz
    input  wire         init,           // hold the controller in its power-up sequence

    // Wishbone slave (from sun2_cached_fifo_bridge)
    input  wire         wb_cyc_i,
    input  wire         wb_stb_i,
    input  wire [29:0]  wb_adr_i,       // 32-bit word address
    input  wire [31:0]  wb_dat_i,
    input  wire [3:0]   wb_sel_i,
    input  wire         wb_we_i,
    output reg  [31:0]  wb_dat_o  = 32'h0,
    output reg          wb_ack_o  = 1'b0,
    output reg  [127:0] wb_line_o = 128'h0,

    // Frame buffer line port (from fb_scanout)
    input  wire [27:0]  fb_c_addr,      // 16-bit word address within the frame buffer
    input  wire         fb_c_req,       // a level, held for the whole line
    output reg          fb_c_done  = 1'b0,
    output reg  [127:0] fb_c_rdata = 128'h0,

    // The colour board's engine (sun2_cgtwo): a line read, or one halfword
    // written with its byte selects.  A level, held until cg_done.
    input  wire [15:0]  cg_line,
    input  wire [2:0]   cg_word,
    input  wire         cg_req,
    input  wire         cg_we,
    input  wire [15:0]  cg_wdata,
    input  wire [1:0]   cg_bs,          // [1] the even byte, D15:8
    output reg          cg_done    = 1'b0,

    // The colour board's scan-out (sun2_cgtwo_scanout): line reads.
    input  wire [15:0]  cs_line,
    input  wire         cs_req,
    input  wire         cs_urgent,
    output reg          cs_done    = 1'b0,

    // A line either of the colour board's clients read, valid with its done.
    output reg  [127:0] cl_rdata   = 128'h0,

    // SDRAM pins
    inout  wire [15:0]  SDRAM_DQ,
    output wire [12:0]  SDRAM_A,
    output wire         SDRAM_DQML,
    output wire         SDRAM_DQMH,
    output wire [1:0]   SDRAM_BA,
    output wire         SDRAM_nCS,
    output wire         SDRAM_nWE,
    output wire         SDRAM_nRAS,
    output wire         SDRAM_nCAS,
    output wire         SDRAM_CKE,
    output wire         SDRAM_CLK
);

    // ---- address translation ------------------------------------------------
    wire        wb_is_fb = (wb_adr_i >= FB_WB_BASE);
    wire [29:0] wb_fb_rel = wb_adr_i - FB_WB_BASE;
    // SDRAM word of the even halfword of this Wishbone word.
    wire [25:0] wb_word  = wb_is_fb ? FB_SDRAM_WORD + {wb_fb_rel[23:0], 1'b0}
                                    : {wb_adr_i[24:0], 1'b0};

    // ---- refresh pacing --------------------------------------------------------
    reg       refresh = 1'b0;
    reg [9:0] refcnt  = 10'd0;
    always @(posedge clk) begin
        refcnt <= refcnt + 10'd1;
        if (refcnt == 10'd763) begin
            refcnt  <= 10'd0;
            refresh <= ~refresh;
        end
    end

    // ---- the controller --------------------------------------------------------
    reg  [25:0] c_word = 26'd0;         // SDRAM word address of the access
    reg  [15:0] c_din  = 16'h0;
    reg  [1:0]  c_bs   = 2'b00;         // [1] high byte, [0] low byte
    reg         c_rd   = 1'b0;
    reg         c_wr   = 1'b0;
    wire [15:0] dout;
    wire        ready;

    sdram sdram (
        .init      (init),
        .clk       (clk),
        .SDRAM_EN  (1'b1),

        .SDRAM_DQ  (SDRAM_DQ),
        .SDRAM_A   (SDRAM_A),
        .SDRAM_DQML(SDRAM_DQML),
        .SDRAM_DQMH(SDRAM_DQMH),
        .SDRAM_BA  (SDRAM_BA),
        .SDRAM_nCS (SDRAM_nCS),
        .SDRAM_nWE (SDRAM_nWE),
        .SDRAM_nRAS(SDRAM_nRAS),
        .SDRAM_nCAS(SDRAM_nCAS),
        .SDRAM_CKE (SDRAM_CKE),
        .SDRAM_CLK (SDRAM_CLK),

        .sel       (1'b1),
        .addr      (c_word),            // addr[26:1]: a word address
        .dout      (dout),
        .din       (c_din),
        .wr        (c_wr),
        .bs        (c_bs),
        .rd        (c_rd),
        .ready     (ready),
        .refresh   (refresh),

        .cpsel     (1'b0),
        .cpaddr    (26'd0),
        .cpdin     (16'd0),
        .cprd      (),
        .cpreq     (1'b0),
        .cpbusy    ()
    );

    reg  ready_d = 1'b0;
    always @(posedge clk) ready_d <= ready;
    wire ready_rise = ready & ~ready_d;

    // ---- one access at a time ---------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0,
                     S_RD   = 3'd1,     // rd held, waiting for the first word
                     S_RDB  = 3'd2,     // collecting words 1..7
                     S_WR   = 3'd3,     // wr held, waiting for the command
                     S_GAP  = 3'd4;     // the client has not yet seen the answer

    reg [2:0]   st      = S_IDLE;
    reg         for_fb  = 1'b0;         // whose read this is
    reg         for_cg  = 1'b0;
    reg         for_cs  = 1'b0;
    // Turns between the colour scan-out, the CPU and the engine: whoever was
    // served last goes to the back.  0 scan-out, 1 CPU, 2 engine.
    reg [1:0]   last_rr = 2'd0;
    wire        wb_want = wb_cyc_i & wb_stb_i;
    wire [1:0]  pick =
        (cs_req & cs_urgent) ? 2'd0 :
        (last_rr == 2'd0)    ? (wb_want ? 2'd1 : cg_req  ? 2'd2 : 2'd0) :
        (last_rr == 2'd1)    ? (cg_req  ? 2'd2 : cs_req  ? 2'd0 : 2'd1) :
                               (cs_req  ? 2'd0 : wb_want ? 2'd1 : 2'd2);
    reg [2:0]   widx    = 3'd0;
    reg [127:0] line    = 128'h0;
    reg [1:0]   lane    = 2'd0;
    reg         hi_left = 1'b0;         // a write's odd halfword is still to go
    reg [15:0]  hi_din  = 16'h0;
    reg [1:0]   hi_bs   = 2'b00;

    always @(posedge clk) begin
        wb_ack_o  <= 1'b0;
        fb_c_done <= 1'b0;
        cg_done   <= 1'b0;
        cs_done   <= 1'b0;

        if (init) begin
            st   <= S_IDLE;
            c_rd <= 1'b0;
            c_wr <= 1'b0;
        end else case (st)
            S_IDLE: begin
                for_fb <= 1'b0;
                for_cg <= 1'b0;
                for_cs <= 1'b0;
                // The mono frame buffer first: it has a deadline and asks for
                // a few lines' worth every scan line, so the others barely
                // notice.
                if (fb_c_req) begin
                    for_fb <= 1'b1;
                    c_word <= FB_SDRAM_WORD + {fb_c_addr[24:3], 3'b000};
                    c_rd   <= 1'b1;
                    st     <= S_RD;
                end else if (pick == 2'd0 && cs_req) begin
                    for_cs  <= 1'b1;
                    last_rr <= 2'd0;
                    c_word  <= CG_SDRAM_WORD + {7'd0, cs_line, 3'b000};
                    c_rd    <= 1'b1;
                    st      <= S_RD;
                end else if (pick == 2'd2 && cg_req) begin
                    for_cg  <= 1'b1;
                    last_rr <= 2'd2;
                    if (cg_we) begin
                        c_word  <= CG_SDRAM_WORD + {7'd0, cg_line, cg_word};
                        c_din   <= cg_wdata;
                        c_bs    <= cg_bs;
                        c_wr    <= 1'b1;
                        hi_left <= 1'b0;
                        st      <= S_WR;
                    end else begin
                        c_word  <= CG_SDRAM_WORD + {7'd0, cg_line, 3'b000};
                        c_rd    <= 1'b1;
                        st      <= S_RD;
                    end
                end else if (pick == 2'd1 && wb_want) begin
                    last_rr <= 2'd1;
                    lane    <= wb_adr_i[1:0];
                    if (!wb_we_i) begin
                        c_word <= {wb_word[25:3], 3'b000};     // the whole line
                        c_rd   <= 1'b1;
                        st     <= S_RD;
                    end else if (wb_sel_i[1:0] != 2'b00) begin
                        // The 68010 writes 16 bits a cycle, so only one half is
                        // ever selected; both are handled all the same.
                        c_word  <= wb_word;
                        c_din   <= wb_dat_i[15:0];
                        c_bs    <= wb_sel_i[1:0];
                        c_wr    <= 1'b1;
                        hi_left <= (wb_sel_i[3:2] != 2'b00);
                        hi_din  <= wb_dat_i[31:16];
                        hi_bs   <= wb_sel_i[3:2];
                        st      <= S_WR;
                    end else if (wb_sel_i[3:2] != 2'b00) begin
                        c_word  <= wb_word + 26'd1;
                        c_din   <= wb_dat_i[31:16];
                        c_bs    <= wb_sel_i[3:2];
                        c_wr    <= 1'b1;
                        hi_left <= 1'b0;
                        st      <= S_WR;
                    end else begin
                        wb_ack_o <= 1'b1;                      // nothing to write
                        st       <= S_GAP;
                    end
                end
            end

            S_RD:
                if (ready_rise) begin
                    c_rd        <= 1'b0;
                    line[15:0]  <= dout;
                    widx        <= 3'd1;
                    st          <= S_RDB;
                end

            S_RDB: begin
                line[widx*16 +: 16] <= dout;
                if (widx == 3'd7) begin
                    if (for_fb) begin
                        fb_c_rdata <= {dout, line[111:0]};
                        fb_c_done  <= 1'b1;
                    end else if (for_cs | for_cg) begin
                        cl_rdata <= {dout, line[111:0]};
                        cs_done  <= for_cs;
                        cg_done  <= for_cg;
                    end else begin
                        wb_line_o <= {dout, line[111:0]};
                        wb_dat_o  <= (lane == 2'd3) ? {dout, line[111:96]}
                                                    : line[lane*32 +: 32];
                        wb_ack_o  <= 1'b1;
                    end
                    st <= S_GAP;
                end else
                    widx <= widx + 3'd1;
            end

            S_WR:
                if (ready_rise) begin
                    if (hi_left) begin
                        // Drop wr for a clock between the two so the controller
                        // sees a new request rather than a held one.
                        c_wr    <= 1'b0;
                        hi_left <= 1'b0;
                        c_word  <= c_word + 26'd1;
                        c_din   <= hi_din;
                        c_bs    <= hi_bs;
                        st      <= S_WR;
                    end else begin
                        c_wr     <= 1'b0;
                        if (for_cg)
                            cg_done  <= 1'b1;
                        else
                            wb_ack_o <= 1'b1;
                        st       <= S_GAP;
                    end
                end else if (!c_wr)
                    c_wr <= 1'b1;               // the second half's request

            S_GAP:
                st <= S_IDLE;

            default:
                st <= S_IDLE;
        endcase
    end

endmodule
