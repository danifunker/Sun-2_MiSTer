//============================================================================
//  Sun-2/160 for MiSTer
//
//  The emu module: the MiSTer framework (sys/) on one side, the Sun-2 machine
//  (rtl/sun2-common/top_fpga.v) on the other, and the board-level pieces that
//  join them.  The machine is fixed by Sun-2.qsf's macro block: a VME Sun-2
//  with its Rev Q boot PROM, the VME SCSI board, the on-board mono frame
//  buffer, keyboard/mouse SCC and 82586.
//
//  Clocks (rtl/pll.v, rtl/pll_serial.v)
//    clk_mem   100.000 MHz  SDRAM, the memory side of the Wishbone bridge, hps_io
//    cpu_clk    20.000 MHz  the machine, its block seam and the keyboard/mouse bridge
//    clk_pix    83.333 MHz  the raster
//    clk_mii    25.000 MHz  the 82586's MII clocks; nothing is on the wire
//    clk_ser     4.9152 MHz the SCCs, the Am9513 and the MM58167
//
//  Memory: 8 MiB of main memory and the 128 KiB frame buffer on the SDRAM
//  board, behind rtl/sun2_mister_sdram.sv.  The boot PROM is not in the
//  bitstream: it is games/Sun-2/boot0.rom, which Main_MiSTer sends on ioctl
//  index 0 at start-up, and the machine stays in reset until it has arrived.
//============================================================================

`timescale 1ns / 1ps

module emu
(
    `include "sys/emu_ports.vh"
);

    // ---- what this core does not use ------------------------------------------
    assign ADC_BUS  = 'Z;
    assign USER_OUT = '1;
    assign {UART_RTS, UART_DTR} = 2'b00;
    assign {SD_SCK, SD_MOSI, SD_CS} = 'Z;
    assign {DDRAM_CLK, DDRAM_BURSTCNT, DDRAM_ADDR, DDRAM_DIN, DDRAM_BE, DDRAM_RD, DDRAM_WE} = '0;

    assign VGA_SL      = 2'b00;
    assign VGA_F1      = 1'b0;
    assign VGA_SCALER  = 1'b0;
    assign VGA_DISABLE = 1'b0;
    assign HDMI_FREEZE    = 1'b0;
    assign HDMI_BLACKOUT  = 1'b0;
    assign HDMI_BOB_DEINT = 1'b0;

    assign AUDIO_S   = 1'b0;
    assign AUDIO_MIX = 2'b00;
    assign AUDIO_L   = 16'd0;
    assign AUDIO_R   = 16'd0;

    assign BUTTONS   = 2'b00;
    assign LED_POWER = 2'b00;

    // ---- the OSD ---------------------------------------------------------------
    // status[0] is the reset item and nothing else; the options start at 1.
    // The disk is SC: Main_MiSTer remembers the image last chosen for it (in
    // config/Sun-2.s0) and mounts it again whenever the core starts, so the
    // PROM finds it and auto-boots SunOS with nothing selected by hand.  The
    // core holds reset until boot0.rom arrives, and Main mounts the disk right
    // after loading it.  The tape stays plain S: a cartridge is chosen for an
    // install, not kept in the drive.
    `include "build_id.v"
    localparam CONF_STR = {
        "Sun-2;UART9600;",
        "SC0,IMGVHD,SCSI disk (sd0);",
        "S1,QIC,Tape (st0);",
        "O[4:3],Tape volume,1,2,3;",
        "-;",
        "O[2:1],Aspect ratio,Original,Full Screen,4:3;",
        "O[6:5],Scale,V-Integer,Normal,Narrower HV-Integer,Wider HV-Integer;",
        "-;",
        "R0,Reset;",
        "V,v",`BUILD_DATE
    };

    wire [127:0] status;
    wire [1:0]   buttons;

    // The raster is 1160x904 (the 1152x900 screen and a small border, which
    // fb_scanout needs for its prefetch) of square pixels.  The aspect ratio
    // and the integer scaling are the framework's video_freak, below the
    // frame buffer.
    // V-Integer is the default, so it is listed first and its status value is
    // 0: video_freak's own numbering is 0 normal, 1 V-integer.
    wire [1:0] ar    = status[2:1];
    wire [2:0] scale = (status[6:5] == 2'd0) ? 3'd1 :
                       (status[6:5] == 2'd1) ? 3'd0 : {1'b0, status[6:5]};

    // ---- clocks ------------------------------------------------------------------
    wire clk_mem, cpu_clk, clk_pix, clk_mii, clk_ser;
    wire locked_main, locked_ser;

    pll pll (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (clk_mem),
        .outclk_1 (cpu_clk),
        .outclk_2 (clk_pix),
        .outclk_3 (clk_mii),
        .locked   (locked_main)
    );

    pll_serial pll_serial (
        .refclk   (CLK_50M),
        .rst      (1'b0),
        .outclk_0 (clk_ser),
        .locked   (locked_ser)
    );

    wire locked = locked_main & locked_ser;

    // ---- hps_io --------------------------------------------------------------------
    wire [10:0] ps2_key;
    wire [24:0] ps2_mouse;
    wire [64:0] rtc;

    // Two virtual drives: VD 0 the disk, VD 1 the tape.
    wire [31:0] sd_lba[2];
    wire [1:0]  sd_rd, sd_wr, sd_ack;
    wire [13:0] sd_buff_addr;
    wire [7:0]  sd_buff_dout;
    wire [7:0]  sd_buff_din[2];
    wire        sd_buff_wr;
    wire [1:0]  img_mounted;
    wire [63:0] img_size;

    wire        ioctl_download;
    wire [15:0] ioctl_index;
    wire        ioctl_wr;
    wire [26:0] ioctl_addr;
    wire [7:0]  ioctl_dout;

    hps_io #(.CONF_STR(CONF_STR), .VDNUM(2)) hps_io (
        .clk_sys        (clk_mem),
        .HPS_BUS        (HPS_BUS),
        .EXT_BUS        (),

        .buttons        (buttons),
        .status         (status),
        .status_menumask(16'd0),

        .ps2_key        (ps2_key),
        .ps2_mouse      (ps2_mouse),
        .RTC            (rtc),

        .sd_lba         (sd_lba),
        .sd_rd          (sd_rd),
        .sd_wr          (sd_wr),
        .sd_ack         (sd_ack),
        .sd_buff_addr   (sd_buff_addr),
        .sd_buff_dout   (sd_buff_dout),
        .sd_buff_din    (sd_buff_din),
        .sd_buff_wr     (sd_buff_wr),
        .img_mounted    (img_mounted),
        .img_readonly   (),
        .img_size       (img_size),

        .ioctl_download (ioctl_download),
        .ioctl_index    (ioctl_index),
        .ioctl_wr       (ioctl_wr),
        .ioctl_addr     (ioctl_addr),
        .ioctl_dout     (ioctl_dout),
        .ioctl_wait     (1'b0)
    );

    // ---- the boot PROM, from boot0.rom ---------------------------------------------
    // 32 KiB, big-endian 16-bit words: the even byte is the high half.  The
    // machine is held in reset until a whole image has been received.
    reg        rom_wr_en   = 1'b0;
    reg [13:0] rom_wr_addr = 14'd0;
    reg [15:0] rom_wr_data = 16'h0;
    reg [7:0]  rom_hi      = 8'h0;
    reg        rom_loading = 1'b0;
    reg        rom_loaded  = 1'b0;

    always @(posedge clk_mem) begin
        rom_wr_en <= 1'b0;
        if (ioctl_download && ioctl_index[7:0] == 8'd0) begin       // boot0.rom; boot1.rom would be 64
            rom_loading <= 1'b1;
            rom_loaded  <= 1'b0;
            if (ioctl_wr && ioctl_addr < 27'd32768) begin
                if (!ioctl_addr[0])
                    rom_hi <= ioctl_dout;
                else begin
                    rom_wr_en   <= 1'b1;
                    rom_wr_addr <= ioctl_addr[14:1];
                    rom_wr_data <= {rom_hi, ioctl_dout};
                end
            end
        end else if (rom_loading) begin
            rom_loading <= 1'b0;
            rom_loaded  <= 1'b1;
        end
    end

    // ---- resets -----------------------------------------------------------------------
    // The machine: the OSD's reset, the framework's, an unlocked PLL, or no PROM yet.
    wire machine_reset_raw = status[0] | buttons[1] | RESET | ~locked | ~rom_loaded;

    wire reset_cpu;
    reset_sync rst_cpu (.clk(cpu_clk), .rst_async_in(machine_reset_raw), .rst_sync_out(reset_cpu));

    // Memory and video restart only when the clocks do: a machine reset must
    // not lose the SDRAM's contents or blank the screen.
    wire reset_mem, reset_pix;
    reset_sync rst_mem (.clk(clk_mem), .rst_async_in(~locked), .rst_sync_out(reset_mem));
    reset_sync rst_pix (.clk(clk_pix), .rst_async_in(~locked), .rst_sync_out(reset_pix));

    // ---- keyboard and mouse ---------------------------------------------------------
    wire kbm_rxda, kbm_txda, kbm_rxdb;

    sun2_mister_kbd_mouse #(.CLK_HZ(20_000_000)) kbd_mouse (
        .clk          (cpu_clk),
        .rst          (reset_cpu),
        .ps2_key      (ps2_key),
        .ps2_mouse    (ps2_mouse),
        .kbd_ser_tx   (kbm_rxda),
        .kbd_ser_rx   (kbm_txda),
        .mouse_ser_tx (kbm_rxdb),
        .bell         ()
    );

    // ---- the time of day -------------------------------------------------------------
    // MiSTer's local time as it is when the core loads, less 36 years and in
    // SunOS's own encoding, into the MM58167 on the SCSI board
    // (rtl/sun2_mister_tod.sv).
    wire        tod_ld;
    wire [47:0] tod_time;

    sun2_mister_tod tod (
        .clk       (cpu_clk),
        .rtc       (rtc),
        .ld        (tod_ld),
        .tod       (tod_time)
    );

    // ---- the disk ----------------------------------------------------------------------
    wire        blk_start, blk_we, blk_done, blk_err, blk_ready, blk_buf_we, blk_busy;
    wire [31:0] blk_lba, blk_count;
    wire [7:0]  blk_buf_rdata, blk_buf_wdata;
    wire [8:0]  blk_buf_addr;

    sun2_mister_block disk (
        .clk           (cpu_clk),
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
        .busy          (blk_busy),

        .clk_hps       (clk_mem),
        .sd_lba        (sd_lba[0]),
        .sd_rd         (sd_rd[0]),
        .sd_wr         (sd_wr[0]),
        .sd_ack        (sd_ack[0]),
        .sd_buff_addr  (sd_buff_addr[8:0]),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   (sd_buff_din[0]),
        .sd_buff_wr    (sd_buff_wr),
        .img_mounted   (img_mounted[0]),
        .img_size      (img_size)
    );

    // ---- the tape --------------------------------------------------------------------------
    // The same bridge on VD 1, read only: the image is a .qic from
    // tools/mktape, and the OSD's "Tape volume" picks the cartridge in it.
    wire        tblk_start, tblk_done, tblk_err, tblk_ready, tblk_buf_we, tblk_busy, tape_changed;
    wire [31:0] tblk_lba, tblk_count;
    wire [7:0]  tblk_buf_rdata, tblk_buf_wdata;
    wire [8:0]  tblk_buf_addr;

    sun2_mister_block tape (
        .clk           (cpu_clk),
        .blk_start     (tblk_start),
        .blk_we        (1'b0),
        .blk_lba       (tblk_lba),
        .blk_buf_rdata (tblk_buf_rdata),
        .blk_done      (tblk_done),
        .blk_err       (tblk_err),
        .blk_ready     (tblk_ready),
        .blk_count     (tblk_count),
        .blk_buf_we    (tblk_buf_we),
        .blk_buf_addr  (tblk_buf_addr),
        .blk_buf_wdata (tblk_buf_wdata),
        .busy          (tblk_busy),
        .changed       (tape_changed),

        .clk_hps       (clk_mem),
        .sd_lba        (sd_lba[1]),
        .sd_rd         (sd_rd[1]),
        .sd_wr         (sd_wr[1]),
        .sd_ack        (sd_ack[1]),
        .sd_buff_addr  (sd_buff_addr[8:0]),
        .sd_buff_dout  (sd_buff_dout),
        .sd_buff_din   (sd_buff_din[1]),
        .sd_buff_wr    (sd_buff_wr),
        .img_mounted   (img_mounted[1]),
        .img_size      (img_size)
    );

    // The volume, from the OSD's clock: taken once two samples agree, so a
    // change caught between its two bits is never seen as a third volume.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0] tvol_s1 = 2'd0;
    reg [1:0] tvol_s2 = 2'd0, tape_volume = 2'd0;
    always @(posedge cpu_clk) begin
        tvol_s1 <= status[4:3];
        tvol_s2 <= tvol_s1;
        if (tvol_s2 == tvol_s1) tape_volume <= tvol_s2;
    end

    // ---- memory -------------------------------------------------------------------------
    wire         wb_cyc, wb_stb, wb_we, wb_ack;
    wire [29:0]  wb_adr;
    wire [31:0]  wb_dat_m2s, wb_dat_s2m;
    wire [3:0]   wb_sel;
    wire [127:0] wb_line;

    wire [27:0]  fb_c_addr;
    wire         fb_c_req, fb_c_done;
    wire [127:0] fb_c_rdata;

    sun2_mister_sdram sdram (
        .clk        (clk_mem),
        .init       (reset_mem),

        .wb_cyc_i   (wb_cyc),
        .wb_stb_i   (wb_stb),
        .wb_adr_i   (wb_adr),
        .wb_dat_i   (wb_dat_m2s),
        .wb_sel_i   (wb_sel),
        .wb_we_i    (wb_we),
        .wb_dat_o   (wb_dat_s2m),
        .wb_ack_o   (wb_ack),
        .wb_line_o  (wb_line),

        .fb_c_addr  (fb_c_addr),
        .fb_c_req   (fb_c_req),
        .fb_c_done  (fb_c_done),
        .fb_c_rdata (fb_c_rdata),

        .SDRAM_DQ   (SDRAM_DQ),
        .SDRAM_A    (SDRAM_A),
        .SDRAM_DQML (SDRAM_DQML),
        .SDRAM_DQMH (SDRAM_DQMH),
        .SDRAM_BA   (SDRAM_BA),
        .SDRAM_nCS  (SDRAM_nCS),
        .SDRAM_nWE  (SDRAM_nWE),
        .SDRAM_nRAS (SDRAM_nRAS),
        .SDRAM_nCAS (SDRAM_nCAS),
        .SDRAM_CKE  (SDRAM_CKE),
        .SDRAM_CLK  (SDRAM_CLK)
    );

    // ---- the machine ----------------------------------------------------------------------
    wire       fb_video_en;
    wire [7:0] diag_leds, todebug;

    top machine (
        .cpu_clk        (cpu_clk),
        .clk40          (cpu_clk),          // used only under CPU_CLK_MULTIPLE_SERIAL
        .clk4m9152      (clk_ser),
        .sys_reset      (reset_cpu),

        .tx             (UART_TXD),
        .rx             (UART_RXD),
        .kbm_rxda       (kbm_rxda),
        .kbm_txda       (kbm_txda),
        .kbm_rxdb       (kbm_rxdb),
        .kbm_txdb       (),

        .rom_wr_clk     (clk_mem),
        .rom_wr_en      (rom_wr_en),
        .rom_wr_addr    (rom_wr_addr),
        .rom_wr_data    (rom_wr_data),

        .diag_leds      (diag_leds),
        .en_boot        (),
        .todebug        (todebug),
        .eth_crs_stuck  (),
        .fb_video_en    (fb_video_en),

        // No PHY: status reads back as absent.
        .phy_id         (16'd0),
        .phy_present    (1'b0),
        .phy_cfg_done   (1'b1),
        .phy_link       (1'b0),
        .phy_fd         (1'b0),
        .phy_speed      (2'b00),

        // MII clocks run, so the 82586 transmits into nothing and its
        // driver sees a quiet wire, not a dead chip.
        .mii_tx_clk     (clk_mii),
        .mii_txd        (),
        .mii_tx_en      (),
        .mii_tx_er      (),
        .mii_rx_clk     (clk_mii),
        .mii_rxd        (4'd0),
        .mii_rx_dv      (1'b0),
        .mii_rx_er      (1'b0),
        .mii_crs        (1'b0),
        .mii_col        (1'b0),

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

        .tblk_start     (tblk_start),
        .tblk_lba       (tblk_lba),
        .tblk_buf_rdata (tblk_buf_rdata),
        .tblk_done      (tblk_done),
        .tblk_err       (tblk_err),
        .tblk_ready     (tblk_ready),
        .tblk_count     (tblk_count),
        .tblk_buf_we    (tblk_buf_we),
        .tblk_buf_addr  (tblk_buf_addr),
        .tblk_buf_wdata (tblk_buf_wdata),
        .tape_changed   (tape_changed),
        .tape_volume    (tape_volume),

        .tod_ld         (tod_ld),
        .tod_time       (tod_time),

        .wb_cyc_o       (wb_cyc),
        .wb_stb_o       (wb_stb),
        .wb_adr_o       (wb_adr),
        .wb_dat_o       (wb_dat_m2s),
        .wb_sel_o       (wb_sel),
        .wb_we_o        (wb_we),
        .wb_dat_i       (wb_dat_s2m),
        .wb_ack_i       (wb_ack),
        .wb_clk_i       (clk_mem),
        .wb_rst_i       (reset_mem),
        .wb_line_i      (wb_line)
    );

    // ---- video --------------------------------------------------------------------------
    // 1160x904 active in a 1472x937 total at 83.333 MHz: 60.4 Hz.  fb_scanout
    // centres the 1152x900 screen in it, a 4-pixel and 2-line border.
    wire [11:0] cx;
    wire [10:0] cy;
    wire        de, hs, vs;
    wire [23:0] rgb;

    video_timing #(
        .H_ACTIVE(1160), .H_FRONT(24), .H_SYNC(128), .H_TOTAL(1472),
        .V_ACTIVE(904),  .V_FRONT(3),  .V_SYNC(4),   .V_TOTAL(937),
        .H_POSITIVE(1'b0), .V_POSITIVE(1'b0),
        .CXW(12), .CYW(11)
    ) timing (
        .clk(clk_pix), .rst(reset_pix),
        .cx(cx), .cy(cy), .de(de), .hsync(hs), .vsync(vs)
    );

    fb_scanout #(
        .FB_APP_BASE (28'h0000000),         // sun2_mister_sdram adds the frame buffer's offset
        .FB_W        (1152),
        .FB_H        (900),
        .SCREEN_W    (1160),
        .SCREEN_H    (904)
    ) scanout (
        .ui_clk    (clk_mem),
        .ui_rst    (reset_mem),
        .c_addr    (fb_c_addr),
        .c_req     (fb_c_req),
        .c_done    (fb_c_done),
        .c_rdata   (fb_c_rdata),
        .clk_pixel (clk_pix),
        .pix_rst   (reset_pix),
        .cx        (cx),
        .cy        (cy),
        .video_en  (fb_video_en),
        .rgb       (rgb)
    );

    assign CLK_VIDEO = clk_pix;
    assign CE_PIXEL  = 1'b1;
    assign VGA_R     = rgb[23:16];
    assign VGA_G     = rgb[15:8];
    assign VGA_B     = rgb[7:0];
    assign VGA_HS    = hs;
    assign VGA_VS    = vs;

    // A one-pixel font scaled by 1080/904 is a font whose strokes are one or two
    // pixels wide depending on where they land, and blurred between.  V-Integer
    // draws the 904 lines 1:1 at 1080p, with a border; Original keeps the
    // pixels square, Full Screen fills the display, 4:3 is 4:3.
    video_freak video_freak (
        .CLK_VIDEO   (clk_pix),
        .CE_PIXEL    (1'b1),
        .VGA_VS      (vs),
        .HDMI_WIDTH  (HDMI_WIDTH),
        .HDMI_HEIGHT (HDMI_HEIGHT),
        .VGA_DE      (VGA_DE),
        .VIDEO_ARX   (VIDEO_ARX),
        .VIDEO_ARY   (VIDEO_ARY),
        .VGA_DE_IN   (de),
        .ARX         ((ar == 2'd0) ? 12'd1160 : (ar == 2'd2) ? 12'd4 : 12'd0),
        .ARY         ((ar == 2'd0) ? 12'd904  : (ar == 2'd2) ? 12'd3 : 12'd0),
        .CROP_SIZE   (12'd0),
        .CROP_OFF    (5'd0),
        .SCALE       (scale)
    );

    // ---- LEDs ---------------------------------------------------------------------------
    // User: the machine is in reset (no PROM yet, or the OSD's reset).
    // Disk: the disk or the tape is moving a block, ORed with the HPS's own activity.
    assign LED_USER = reset_cpu;
    assign LED_DISK = {1'b0, blk_busy | tblk_busy};

endmodule
