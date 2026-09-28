//
// sun2_mister_sdram.sv
//
// Bridges Wishbone memory cycles and Frame Buffer scan-out requests
// to the MiSTer SDR SDRAM controller (rtl/sdram.v).
//
`timescale 1ns / 1ps

module sun2_mister_sdram #(
    parameter [29:0] FB_WB_BASE = 30'h03E00000,
    parameter [25:0] FB_SDRAM_WORD_OFFSET = 26'h0800000 // 16 MB offset in 16-bit words
) (
    input  wire        clk_mem,       // 64 MHz SDRAM clock
    input  wire        clk_sys,       // System clock
    input  wire        rst,
    input  wire        sdram_init,

    // Wishbone slave (from sun2_cached_fifo_bridge or sun2_fifo_bridge)
    input  wire        wb_cyc_i,
    input  wire        wb_stb_i,
    input  wire [29:0] wb_adr_i,      // 32-bit word address
    input  wire [31:0] wb_dat_i,
    input  wire [3:0]  wb_sel_i,
    input  wire        wb_we_i,
    output reg  [31:0] wb_dat_o,
    output reg         wb_ack_o,
    output reg [127:0] wb_line_o,

    // Framebuffer scan-out port (from fb_scanout.sv)
    input  wire [27:0] fb_c_addr,     // 16-bit word address inside FB
    input  wire        fb_c_req,
    output reg         fb_c_done,
    output reg [127:0] fb_c_rdata,

    // Physical SDRAM interface (MT48LC16M16)
    output wire        SDRAM_CLK,
    output wire        SDRAM_CKE,
    output wire        SDRAM_nCS,
    output wire        SDRAM_nRAS,
    output wire        SDRAM_nCAS,
    output wire        SDRAM_nWE,
    output wire [1:0]  SDRAM_BA,
    output wire [12:0] SDRAM_A,
    inout  wire [15:0] SDRAM_DQ,
    output wire        SDRAM_DQML,
    output wire        SDRAM_DQMH
);

    // =========================================================================
    // Address Translation
    // =========================================================================
    // 32-bit Wishbone word address -> 16-bit SDRAM word address
    wire is_fb = (wb_adr_i >= FB_WB_BASE);
    wire [29:0] rel_adr = is_fb ? (wb_adr_i - FB_WB_BASE) : wb_adr_i;
    wire [25:0] wb_sdram_addr = is_fb ? (FB_SDRAM_WORD_OFFSET + {rel_adr[24:0], 1'b0})
                                      : {rel_adr[24:0], 1'b0};

    // =========================================================================
    // SDRAM Controller Signals
    // =========================================================================
    reg  [25:0] sdr_addr;
    reg  [15:0] sdr_din;
    reg  [1:0]  sdr_ds;
    reg         sdr_oe;
    reg         sdr_we;
    wire [15:0] sdr_dout;
    wire        sdr_ram_ready;
    wire        sdr_rd_ready;
    wire        sdr_wr_ready;

    // Generate 8 MHz sync clock from 64 MHz clk_mem
    reg [2:0] clk8_cnt = 0;
    always @(posedge clk_mem) clk8_cnt <= clk8_cnt + 3'd1;
    wire clk_8_sync = clk8_cnt[2];

    sdram sdram_inst (
        .init           (sdram_init),
        .clk_64         (clk_mem),
        .clk_capture    (1'b0),
        .clk_8          (clk_8_sync),

        .sd_clk         (SDRAM_CLK),
        .sd_data        (SDRAM_DQ),
        .sd_addr        (SDRAM_A),
        .sd_dqm         ({SDRAM_DQMH, SDRAM_DQML}),
        .sd_cs          (SDRAM_nCS),
        .sd_ba          (SDRAM_BA),
        .sd_we          (SDRAM_nWE),
        .sd_ras         (SDRAM_nRAS),
        .sd_cas         (SDRAM_nCAS),

        .din            (sdr_din),
        .addr           (sdr_addr),
        .ds             (sdr_ds),
        .we             (sdr_we),
        .oe             (sdr_oe),
        .dout           (sdr_dout),
        .ram_ready      (sdr_ram_ready),
        .rd_ready       (sdr_rd_ready),
        .wr_ready       (sdr_wr_ready),
        .burst_dout     (),
        .burst_addr     (),
        .burst_valid    ()
    );

    assign SDRAM_CKE = 1'b1;

    // =========================================================================
    // Arbiter & State Machine
    // =========================================================================
    typedef enum logic [3:0] {
        ST_IDLE,
        ST_WB_RD0_WAIT,
        ST_WB_RD1_WAIT,
        ST_WB_WR0_WAIT,
        ST_WB_WR1_WAIT,
        ST_FB_WAIT
    } sdr_state_t;

    sdr_state_t state = ST_IDLE;
    reg [2:0]  fb_word_idx = 0;
    reg [15:0] wb_w0 = 0;

    always @(posedge clk_mem) begin
        wb_ack_o  <= 1'b0;
        fb_c_done <= 1'b0;

        if (rst) begin
            state   <= ST_IDLE;
            sdr_oe  <= 1'b0;
            sdr_we  <= 1'b0;
        end else begin
            case (state)
                ST_IDLE: begin
                    // Priority to video scanout if requested
                    if (fb_c_req) begin
                        sdr_addr    <= FB_SDRAM_WORD_OFFSET + {fb_c_addr[24:3], 3'b000};
                        sdr_ds      <= 2'b11;
                        sdr_oe      <= 1'b1;
                        sdr_we      <= 1'b0;
                        fb_word_idx <= 0;
                        state       <= ST_FB_WAIT;
                    end else if (wb_cyc_i && wb_stb_i) begin
                        if (!wb_we_i) begin
                            // 32-bit Read: start with word 0 (bits 31:16)
                            sdr_addr <= wb_sdram_addr;
                            sdr_ds   <= 2'b11;
                            sdr_oe   <= 1'b1;
                            sdr_we   <= 1'b0;
                            state    <= ST_WB_RD0_WAIT;
                        end else begin
                            // 32-bit Write: word 0
                            if (|wb_sel_i[3:2]) begin
                                sdr_addr <= wb_sdram_addr;
                                sdr_din  <= wb_dat_i[31:16];
                                sdr_ds   <= wb_sel_i[3:2];
                                sdr_we   <= 1'b1;
                                sdr_oe   <= 1'b0;
                                state    <= ST_WB_WR0_WAIT;
                            end else if (|wb_sel_i[1:0]) begin
                                sdr_addr <= wb_sdram_addr + 1'b1;
                                sdr_din  <= wb_dat_i[15:0];
                                sdr_ds   <= wb_sel_i[1:0];
                                sdr_we   <= 1'b1;
                                sdr_oe   <= 1'b0;
                                state    <= ST_WB_WR1_WAIT;
                            end else begin
                                // No bytes selected, ack immediately
                                wb_ack_o <= 1'b1;
                                state    <= ST_IDLE;
                            end
                        end
                    end
                end

                // --- Wishbone Read ---
                ST_WB_RD0_WAIT: begin
                    if (sdr_rd_ready) begin
                        wb_w0    <= sdr_dout;
                        // Trigger second word read (bits 15:0)
                        sdr_addr <= wb_sdram_addr + 1'b1;
                        sdr_ds   <= 2'b11;
                        sdr_oe   <= 1'b1;
                        state    <= ST_WB_RD1_WAIT;
                    end
                end

                ST_WB_RD1_WAIT: begin
                    if (sdr_rd_ready) begin
                        wb_dat_o  <= {wb_w0, sdr_dout};
                        wb_line_o <= {4{wb_w0, sdr_dout}}; // replicate line for cache
                        wb_ack_o  <= 1'b1;
                        sdr_oe    <= 1'b0;
                        state     <= ST_IDLE;
                    end
                end

                // --- Wishbone Write ---
                ST_WB_WR0_WAIT: begin
                    if (sdr_wr_ready) begin
                        sdr_we <= 1'b0;
                        if (|wb_sel_i[1:0]) begin
                            // Word 1 (bits 15:0)
                            sdr_addr <= wb_sdram_addr + 1'b1;
                            sdr_din  <= wb_dat_i[15:0];
                            sdr_ds   <= wb_sel_i[1:0];
                            sdr_we   <= 1'b1;
                            state    <= ST_WB_WR1_WAIT;
                        end else begin
                            wb_ack_o <= 1'b1;
                            state    <= ST_IDLE;
                        end
                    end
                end

                ST_WB_WR1_WAIT: begin
                    if (sdr_wr_ready) begin
                        sdr_we   <= 1'b0;
                        wb_ack_o <= 1'b1;
                        state    <= ST_IDLE;
                    end
                end

                // --- Frame Buffer 128-bit Burst Read ---
                ST_FB_WAIT: begin
                    if (sdr_rd_ready) begin
                        fb_c_rdata[fb_word_idx * 16 +: 16] <= sdr_dout;
                        if (fb_word_idx == 3'd7) begin
                            sdr_oe    <= 1'b0;
                            fb_c_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            fb_word_idx <= fb_word_idx + 1'b1;
                            sdr_addr    <= FB_SDRAM_WORD_OFFSET + {fb_c_addr[24:3], fb_word_idx + 1'b1};
                            sdr_ds      <= 2'b11;
                            sdr_oe      <= 1'b1;
                        end
                    end
                end

                default: state <= ST_IDLE;
            endcase
        end
    end

endmodule
