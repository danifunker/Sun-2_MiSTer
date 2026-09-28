//============================================================================
//  Sun-2 Workstation Replica for MiSTer
//
//  Top-level emu module adapting the Sun-2 FPGA architecture to the MiSTer
//  hardware platform.
//
//  Features:
//  - Motorola 68010 CPU via RD68011 core
//  - Sun-2 custom MMU with Contexts, Segment Map, and Page Map
//  - SDR SDRAM controller with 128-bit cache line support & Framebuffer scanout
//  - 1152x900 1-bit Monochrome Framebuffer centered in 1280x1024 VESA DMT @ 60Hz
//  - Xylogics 450 SMD Hard Disk Controller bridged to MiSTer VHD / SD card
//  - Dual Z8530 SCC: Port A = Console / Keyboard, Port B = Mouse
//  - PS/2 Keyboard & Mouse translation to Sun Type 4 serial (TEMLIB mapping)
//  - Am9513 System Timing Controller & MM58167 Real-Time Clock
//  - Native MiSTer OSD, UART console redirection, and reset sequencing
//============================================================================

`timescale 1ns / 1ps

module emu
(
    `include "sys/emu_ports.vh"
);

    // =========================================================================
    // Default values for ports not used in this core
    // =========================================================================
    assign ADC_BUS     = 'Z;
    assign USER_OUT    = '1;
    assign UART_DTR    = UART_DSR;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
    assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

    assign VGA_SL      = 2'b00;
    assign VGA_F1      = 1'b0;
    assign VGA_SCALER  = 1'b0;
    assign VGA_DISABLE = 1'b0;

    assign HDMI_FREEZE   = 1'b0;
    assign HDMI_BLACKOUT = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;

    assign AUDIO_S   = 1'b0;
    assign AUDIO_MIX = 2'b00;
    assign AUDIO_L   = 16'd0;
    assign AUDIO_R   = 16'd0;

    assign BUTTONS   = 2'b00;

    // =========================================================================
    // MiSTer OSD Configuration String
    // =========================================================================
    `include "build_id.v"

    localparam CONF_STR = {
        "Sun-2;UART9600:19200:38400:1200;",
        "-;",
        "S0,IMGVHD,Disk (xy0);",
        "-;",
        "O[1:0],Aspect ratio,5:4 (1280x1024),4:3,Original 1152x900;",
        "O[2],Boot PROM,Fastboot,Normal;",
        "-;",
        "R0,Reset;",
        "V,v1.0.", `BUILD_DATE
    };

    wire [127:0] status;
    wire [1:0]   buttons;

    // Aspect ratio configuration
    // 0: 5:4 (1280x1024 VESA DMT)
    // 1: 4:3
    // 2: Original 1152x900
    wire [1:0] ar = status[1:0];
    assign VIDEO_ARX = (ar == 2'd0) ? 13'd5 : (ar == 2'd1) ? 13'd4 : 13'd1152;
    assign VIDEO_ARY = (ar == 2'd0) ? 13'd4 : (ar == 2'd1) ? 13'd3 : 13'd900;

    // =========================================================================
    // Clocks
    // =========================================================================
    wire clk_pixel;   // 108.0 MHz (VESA DMT 1280x1024 @ 60Hz)
    wire clk_mem;     // 64.0 MHz (SDRAM and Wishbone FIFO)
    wire clk40;       // 40.0 MHz (Keyboard/Mouse UART reference)
    wire cpu_clk;     // 16.67 MHz (Sun-2 CPU clock)
    wire clk4m9152;   // 4.9152 MHz (SCC and RTC clock)
    wire pll_locked;

    pll pll_inst (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (clk_pixel),
        .outclk_1 (clk_mem),
        .outclk_2 (clk40),
        .outclk_3 (cpu_clk),
        .outclk_4 (clk4m9152),
        .locked   (pll_locked)
    );

    // =========================================================================
    // Reset Sequencing
    // =========================================================================
    wire user_reset = status[0] | buttons[1] | RESET;
    reg  [7:0] rst_hold = 8'hFF;
    reg        sdram_init_done = 1'b0;

    always @(posedge clk_mem) begin
        if (!pll_locked) begin
            rst_hold        <= 8'hFF;
            sdram_init_done <= 1'b0;
        end else if (rst_hold != 8'h00) begin
            rst_hold <= rst_hold - 8'd1;
        end else begin
            sdram_init_done <= 1'b1;
        end
    end

    wire sys_reset_raw = user_reset | !pll_locked | (rst_hold != 8'h00);

    // Synchronize resets to their respective clock domains
    wire sys_reset_cpu;
    reset_sync rst_sync_cpu (
        .clk          (cpu_clk),
        .rst_async_in (sys_reset_raw),
        .rst_sync_out (sys_reset_cpu)
    );

    wire sys_reset_mem;
    reset_sync rst_sync_mem (
        .clk          (clk_mem),
        .rst_async_in (sys_reset_raw),
        .rst_sync_out (sys_reset_mem)
    );

    wire sys_reset_pix;
    reset_sync rst_sync_pix (
        .clk          (clk_pixel),
        .rst_async_in (sys_reset_raw),
        .rst_sync_out (sys_reset_pix)
    );

    // =========================================================================
    // HPS IO (MiSTer Framework)
    // =========================================================================
    wire forced_scandoubler;
    wire [10:0] ps2_key;
    wire [24:0] ps2_mouse;

    // SD Card / VHD Block interface
    wire [31:0] sd_lba[1];
    wire [0:0]  sd_rd;
    wire [0:0]  sd_wr;
    wire [0:0]  sd_ack;
    wire [13:0] sd_buff_addr;
    wire [7:0]  sd_buff_dout;
    wire [7:0]  sd_buff_din[1];
    wire        sd_buff_wr;
    wire [0:0]  img_mounted;
    wire [63:0] img_size;

    hps_io #(
        .CONF_STR (CONF_STR),
        .VDNUM    (1)
    ) hps_io_inst (
        .clk_sys         (clk_mem),
        .HPS_BUS         (HPS_BUS),
        .EXT_BUS         (),
        .gamma_bus       (),

        .forced_scandoubler (forced_scandoubler),

        .sd_lba          (sd_lba),
        .sd_blk_cnt      (),
        .sd_rd           (sd_rd),
        .sd_wr           (sd_wr),
        .sd_ack          (sd_ack),
        .sd_buff_addr    (sd_buff_addr),
        .sd_buff_dout    (sd_buff_dout),
        .sd_buff_din     (sd_buff_din),
        .sd_buff_wr      (sd_buff_wr),
        .img_mounted     (img_mounted),
        .img_readonly    (),
        .img_size        (img_size),

        .TIMESTAMP       (),
        .buttons         (buttons),
        .status          (status),
        .status_menumask (16'd0),
        .status_in       (128'd0),
        .status_set      (1'b0),

        .ps2_key         (ps2_key),
        .ps2_mouse       (ps2_mouse),

        .ps2_kbd_led_status (3'b000),
        .ps2_kbd_led_use    (3'b000)
    );

    // =========================================================================
    // Keyboard & Mouse Translation (TEMLIB mapping -> Sun Type 4 Serial)
    // =========================================================================
    wire kbd_ser_tx;
    wire kbd_ser_rx;
    wire mouse_ser_tx;

    sun2_mister_kbd_mouse #(
        .CLK_HZ (40_000_000)
    ) kbd_mouse_inst (
        .clk          (clk40),
        .rst          (sys_reset_cpu),
        .ps2_key      (ps2_key),
        .ps2_mouse    (ps2_mouse),
        .kbd_ser_tx   (kbd_ser_tx),
        .kbd_ser_rx   (kbd_ser_rx),
        .mouse_ser_tx (mouse_ser_tx),
        .bell         (),
        .leds         ()
    );

    // =========================================================================
    // Block Interface Bridge (MiSTer VHD <-> Sun-2 Xylogics 450)
    // =========================================================================
    wire        blk_start;
    wire        blk_we;
    wire [31:0] blk_lba;
    wire [7:0]  blk_buf_rdata;
    wire        blk_done;
    wire        blk_err;
    wire        blk_ready;
    wire [31:0] blk_count;
    wire        blk_buf_we;
    wire [8:0]  blk_buf_addr;
    wire [7:0]  blk_buf_wdata;

    wire [31:0] blk_bridge_sd_lba;
    wire        blk_bridge_sd_rd;
    wire        blk_bridge_sd_wr;
    wire [7:0]  blk_bridge_sd_buff_din;

    assign sd_lba[0]       = blk_bridge_sd_lba;
    assign sd_rd[0]        = blk_bridge_sd_rd;
    assign sd_wr[0]        = blk_bridge_sd_wr;
    assign sd_buff_din[0]  = blk_bridge_sd_buff_din;

    sun2_mister_block blk_bridge_inst (
        .clk           (cpu_clk),
        .rst           (sys_reset_cpu),

        .blk_start     (blk_start),
        .blk_we        (blk_we),
        .blk_lba       (blk_lba),
        .blk_buf_rdata (blk_buf_rdata),
        .blk_done      (blk_done),
        .blk_err       (blk_err),
        .blk_ready     (blk_ready),
        .blk_count     (blk_count),
        .blk_buf_we    (blk_buf_we),
        .blk_buf_addr  (blk_buf_addr),
        .blk_buf_wdata (blk_buf_wdata),

        .sd_lba        (blk_bridge_sd_lba),
        .sd_rd         (blk_bridge_sd_rd),
        .sd_wr         (blk_bridge_sd_wr),
        .sd_ack        (sd_ack[0]),
        .sd_buff_addr  (sd_buff_addr[8:0]),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   (blk_bridge_sd_buff_din),
        .sd_buff_wr    (sd_buff_wr),
        .img_mounted   (img_mounted[0]),
        .img_size      (img_size)
    );

    // =========================================================================
    // Wishbone Memory & Frame Buffer Scanout via SDRAM
    // =========================================================================
    wire        wb_cyc;
    wire        wb_stb;
    wire [29:0] wb_adr;
    wire [31:0] wb_dat_m2s;
    wire [3:0]  wb_sel;
    wire        wb_we;
    wire [31:0] wb_dat_s2m;
    wire        wb_ack;
    wire [127:0] wb_line_s2m;

    wire [27:0]  fb_c_addr;
    wire         fb_c_req;
    wire         fb_c_done;
    wire [127:0] fb_c_rdata;

    sun2_mister_sdram #(
        .FB_WB_BASE            (30'h03E00000),
        .FB_SDRAM_WORD_OFFSET  (26'h0800000)
    ) sdram_controller (
        .clk_mem        (clk_mem),
        .clk_sys        (cpu_clk),
        .rst            (sys_reset_mem),
        .sdram_init     (!pll_locked),

        .wb_cyc_i       (wb_cyc),
        .wb_stb_i       (wb_stb),
        .wb_adr_i       (wb_adr),
        .wb_dat_i       (wb_dat_m2s),
        .wb_sel_i       (wb_sel),
        .wb_we_i        (wb_we),
        .wb_dat_o       (wb_dat_s2m),
        .wb_ack_o       (wb_ack),
        .wb_line_o      (wb_line_s2m),

        .fb_c_addr      (fb_c_addr),
        .fb_c_req       (fb_c_req),
        .fb_c_done      (fb_c_done),
        .fb_c_rdata     (fb_c_rdata),

        .SDRAM_CLK      (SDRAM_CLK),
        .SDRAM_CKE      (SDRAM_CKE),
        .SDRAM_nCS      (SDRAM_nCS),
        .SDRAM_nRAS     (SDRAM_nRAS),
        .SDRAM_nCAS     (SDRAM_nCAS),
        .SDRAM_nWE      (SDRAM_nWE),
        .SDRAM_BA       (SDRAM_BA),
        .SDRAM_A        (SDRAM_A),
        .SDRAM_DQ       (SDRAM_DQ),
        .SDRAM_DQML     (SDRAM_DQML),
        .SDRAM_DQMH     (SDRAM_DQMH)
    );

    // =========================================================================
    // Sun-2 Machine Core
    // =========================================================================
    wire       fb_video_en;
    wire [7:0] diag_leds;
    wire [7:0] todebug;
    wire       en_boot;
    wire       eth_crs_stuck;

    top machine (
        .cpu_clk        (cpu_clk),
        .clk40          (clk40),
        .clk4m9152      (clk4m9152),
        .sys_reset      (sys_reset_cpu),

        // Serial console
        .tx             (UART_TXD),
        .rx             (UART_RXD),

        // Serial Keyboard and Mouse
        .kbm_rxda       (kbd_ser_tx),
        .kbm_txda       (kbd_ser_rx),
        .kbm_rxdb       (mouse_ser_tx),
        .kbm_txdb       (),

        // Debug & status
        .diag_leds      (diag_leds),
        .en_boot        (en_boot),
        .todebug        (todebug),
        .eth_crs_stuck  (eth_crs_stuck),
        .fb_video_en    (fb_video_en),

        // PHY interface (tied off)
        .phy_id         (16'd0),
        .phy_present    (1'b0),
        .phy_cfg_done   (1'b1),
        .phy_link       (1'b0),
        .phy_fd         (1'b1),
        .phy_speed      (2'b01),

        // MII interface (tied off)
        .mii_tx_clk     (1'b0),
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_er      (),
        .mii_rx_clk     (1'b0),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_crs        (1'b0),
        .mii_col        (1'b0),

        // Block media interface (Xylogics 450)
        .blk_start      (blk_start),
        .blk_we         (blk_we),
        .blk_lba        (blk_lba),
        .blk_buf_rdata  (blk_buf_rdata),
        .blk_done       (blk_done),
        .blk_err        (blk_err),
        .blk_ready      (blk_ready),
        .blk_count      (blk_count),
        .blk_buf_we     (blk_buf_we),
        .blk_buf_addr   (blk_buf_addr),
        .blk_buf_wdata  (blk_buf_wdata),

        // Wishbone interface
        .wb_cyc_o       (wb_cyc),
        .wb_stb_o       (wb_stb),
        .wb_adr_o       (wb_adr),
        .wb_dat_o       (wb_dat_m2s),
        .wb_sel_o       (wb_sel),
        .wb_we_o        (wb_we),
        .wb_dat_i       (wb_dat_s2m),
        .wb_ack_i       (wb_ack),
        .wb_clk_i       (clk_mem),
        .wb_rst_i       (sys_reset_mem),
        .wb_line_i      (wb_line_s2m)
    );

    // =========================================================================
    // Video Timing & Framebuffer Scanout
    // =========================================================================
    wire [11:0] cx;
    wire [10:0] cy;
    wire        vde;
    wire        hsync;
    wire        vsync;
    wire [23:0] rgb;

    video_timing #(
        .H_ACTIVE   (1280),
        .H_FRONT    (48),
        .H_SYNC     (112),
        .H_TOTAL    (1688),
        .V_ACTIVE   (1024),
        .V_FRONT    (1),
        .V_SYNC     (3),
        .V_TOTAL    (1066),
        .H_POSITIVE (1'b1),
        .V_POSITIVE (1'b1),
        .CXW        (12),
        .CYW        (11)
    ) timing_inst (
        .clk        (clk_pixel),
        .rst        (sys_reset_pix),
        .cx         (cx),
        .cy         (cy),
        .de         (vde),
        .hsync      (hsync),
        .vsync      (vsync)
    );

    fb_scanout #(
        .FB_APP_BASE (28'h0000000),
        .FB_W        (1152),
        .FB_H        (900),
        .SCREEN_W    (1280),
        .SCREEN_H    (1024)
    ) fb_scanout_inst (
        .ui_clk      (clk_mem),
        .ui_rst      (sys_reset_mem),
        .c_addr      (fb_c_addr),
        .c_req       (fb_c_req),
        .c_done      (fb_c_done),
        .c_rdata     (fb_c_rdata),

        .clk_pixel   (clk_pixel),
        .pix_rst     (sys_reset_pix),
        .cx          (cx),
        .cy          (cy),
        .video_en    (fb_video_en),
        .rgb         (rgb)
    );

    // Assign Video to MiSTer Scaler / HDMI / VGA
    assign CLK_VIDEO = clk_pixel;
    assign CE_PIXEL  = 1'b1;
    assign VGA_R     = rgb[23:16];
    assign VGA_G     = rgb[15:8];
    assign VGA_B     = rgb[7:0];
    assign VGA_HS    = hsync;
    assign VGA_VS    = vsync;
    assign VGA_DE    = vde;

    // =========================================================================
    // Front Panel LEDs
    // =========================================================================
    assign LED_USER  = ~pll_locked | sys_reset_cpu;
    assign LED_POWER = 2'b00;
    assign LED_DISK  = {blk_start, 1'b0};

endmodule
