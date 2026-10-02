// Transcribed from sys/emu_ports.vh: every emu port as a testbench wire of
// the same name and width, so that `emu dut(.*)' connects them all.  Keep it
// in step with that file when the framework changes -- a port missing here is
// a compile error, which is the point of using .* rather than naming them.

wire          CLK_50M;
wire          RESET;
tri  [45:0]   HPS_BUS;
wire          CLK_VIDEO;
wire          CE_PIXEL;
wire [12:0]   VIDEO_ARX;
wire [12:0]   VIDEO_ARY;
wire [7:0]    VGA_R;
wire [7:0]    VGA_G;
wire [7:0]    VGA_B;
wire          VGA_HS;
wire          VGA_VS;
wire          VGA_DE;
wire          VGA_F1;
wire [1:0]    VGA_SL;
wire          VGA_SCALER;
wire          VGA_DISABLE;
wire [11:0]   HDMI_WIDTH;
wire [11:0]   HDMI_HEIGHT;
wire          HDMI_FREEZE;
wire          HDMI_BLACKOUT;
wire          HDMI_BOB_DEINT;
`ifdef MISTER_FB
wire          FB_EN;
wire [4:0]    FB_FORMAT;
wire [11:0]   FB_WIDTH;
wire [11:0]   FB_HEIGHT;
wire [31:0]   FB_BASE;
wire [13:0]   FB_STRIDE;
wire          FB_VBL;
wire          FB_LL;
wire          FB_FORCE_BLANK;
`ifdef MISTER_FB_PALETTE
wire          FB_PAL_CLK;
wire [7:0]    FB_PAL_ADDR;
wire [23:0]   FB_PAL_DOUT;
wire [23:0]   FB_PAL_DIN;
wire          FB_PAL_WR;
`endif
`endif
wire          LED_USER;
wire [1:0]    LED_POWER;
wire [1:0]    LED_DISK;
wire [1:0]    BUTTONS;
wire          CLK_AUDIO;
wire [15:0]   AUDIO_L;
wire [15:0]   AUDIO_R;
wire          AUDIO_S;
wire [1:0]    AUDIO_MIX;
tri  [3:0]    ADC_BUS;
wire          SD_SCK;
wire          SD_MOSI;
wire          SD_MISO;
wire          SD_CS;
wire          SD_CD;
wire          DDRAM_CLK;
wire          DDRAM_BUSY;
wire [7:0]    DDRAM_BURSTCNT;
wire [28:0]   DDRAM_ADDR;
wire [63:0]   DDRAM_DOUT;
wire          DDRAM_DOUT_READY;
wire          DDRAM_RD;
wire [63:0]   DDRAM_DIN;
wire [7:0]    DDRAM_BE;
wire          DDRAM_WE;
wire          SDRAM_CLK;
wire          SDRAM_CKE;
wire [12:0]   SDRAM_A;
wire [1:0]    SDRAM_BA;
tri  [15:0]   SDRAM_DQ;
wire          SDRAM_DQML;
wire          SDRAM_DQMH;
wire          SDRAM_nCS;
wire          SDRAM_nCAS;
wire          SDRAM_nRAS;
wire          SDRAM_nWE;
`ifdef MISTER_DUAL_SDRAM
wire          SDRAM2_EN;
wire          SDRAM2_CLK;
wire [12:0]   SDRAM2_A;
wire [1:0]    SDRAM2_BA;
tri  [15:0]   SDRAM2_DQ;
wire          SDRAM2_nCS;
wire          SDRAM2_nCAS;
wire          SDRAM2_nRAS;
wire          SDRAM2_nWE;
`endif
wire          UART_CTS;
wire          UART_RTS;
wire          UART_RXD;
wire          UART_TXD;
wire          UART_DTR;
wire          UART_DSR;
wire [6:0]    USER_IN;
wire [6:0]    USER_OUT;
wire          OSD_STATUS;
