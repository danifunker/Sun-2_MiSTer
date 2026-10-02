// SPDX-License-Identifier: MIT
//
// Wish82586 - shared constants for the Intel 82586-compatible Ethernet MAC.
//
// Everything the 82586 exchanges with the host lives in shared memory as
// little-endian 16-bit words.  The offsets below are byte offsets inside each
// structure, matching the layout the vintage drivers in doc/drivers expect.

// Most of these describe the shared memory layout and are consumed by the
// blocks that are still to be written, so they read as unused for now.
/* verilator lint_off UNUSEDPARAM */
package wish82586_pkg;

  // -------------------------------------------------------------------------
  // System Configuration Pointer (SCP).  The real chip fetches it from the
  // fixed address 0xFFFFF6; here the address is programmable (CSR SCP_ADDR)
  // and defaults to the historical value.
  // -------------------------------------------------------------------------
  localparam logic [31:0] SCP_ADDR_RESET = 32'h00ff_fff6;

  localparam int SCP_SYSBUS_OFF = 0;   // byte: 0 => 16-bit bus, 1 => 8-bit bus
  localparam int SCP_ISCP_OFF   = 6;   // 24-bit address of the ISCP

  // -------------------------------------------------------------------------
  // Intermediate System Configuration Pointer (ISCP)
  // -------------------------------------------------------------------------
  localparam int ISCP_BUSY_OFF   = 0;  // byte: 1 while init is in progress
  localparam int ISCP_SCB_OFF    = 2;  // 16-bit offset of the SCB from CBBASE
  localparam int ISCP_CBBASE_OFF = 4;  // 24-bit base of all control blocks

  // -------------------------------------------------------------------------
  // System Control Block (SCB)
  // -------------------------------------------------------------------------
  localparam int SCB_STATUS_OFF  = 0;   // status word
  localparam int SCB_CMD_OFF     = 2;   // command word
  localparam int SCB_CBL_OFF     = 4;   // offset of first command block
  localparam int SCB_RFA_OFF     = 6;   // offset of the receive frame area
  localparam int SCB_CRCERRS_OFF = 8;
  localparam int SCB_ALNERRS_OFF = 10;
  localparam int SCB_RSCERRS_OFF = 12;
  localparam int SCB_OVRNERRS_OFF = 14;
  localparam int SCB_SIZE        = 16;

  // SCB status word bits.  See doc/drivers/NetBSD/i82586reg.h - the layout
  // below is the chip's own view of the word, which is what the RTL sees in
  // memory.  Big-endian hosts byte swap on the way in and out, which is why
  // the Sun ROM headers appear to disagree.
  localparam int SCB_ST_RUS_LSB = 4;   // [6:4]   receive unit state
  localparam int SCB_ST_CUS_LSB = 8;   // [10:8]  command unit state
  localparam int SCB_ST_RNR     = 12;
  localparam int SCB_ST_CNA     = 13;
  localparam int SCB_ST_FR      = 14;
  localparam int SCB_ST_CX      = 15;

  // SCB command word bits
  localparam int SCB_CMD_RUC_LSB = 4;   // [6:4]   receive unit control
  localparam int SCB_CMD_CUC_LSB = 8;   // [10:8]  command unit control
  localparam int SCB_CMD_RESET   = 7;
  localparam int SCB_CMD_ACK_RNR = 12;
  localparam int SCB_CMD_ACK_CNA = 13;
  localparam int SCB_CMD_ACK_FR  = 14;
  localparam int SCB_CMD_ACK_CX  = 15;

  // Command unit control / state
  localparam logic [2:0] CUC_NOP     = 3'd0;
  localparam logic [2:0] CUC_START   = 3'd1;
  localparam logic [2:0] CUC_RESUME  = 3'd2;
  localparam logic [2:0] CUC_SUSPEND = 3'd3;
  localparam logic [2:0] CUC_ABORT   = 3'd4;

  localparam logic [2:0] CUS_IDLE      = 3'd0;
  localparam logic [2:0] CUS_SUSPENDED = 3'd1;
  localparam logic [2:0] CUS_ACTIVE    = 3'd2;

  // Receive unit control / state
  localparam logic [2:0] RUC_NOP     = 3'd0;
  localparam logic [2:0] RUC_START   = 3'd1;
  localparam logic [2:0] RUC_RESUME  = 3'd2;
  localparam logic [2:0] RUC_SUSPEND = 3'd3;
  localparam logic [2:0] RUC_ABORT   = 3'd4;

  localparam logic [2:0] RUS_IDLE        = 3'd0;
  localparam logic [2:0] RUS_SUSPENDED   = 3'd1;
  localparam logic [2:0] RUS_NO_RESOURCE = 3'd2;
  localparam logic [2:0] RUS_READY       = 3'd4;

  // -------------------------------------------------------------------------
  // Command block (CB) - common header
  // -------------------------------------------------------------------------
  localparam int CB_STATUS_OFF = 0;
  localparam int CB_CMD_OFF    = 2;
  localparam int CB_LINK_OFF   = 4;
  localparam int CB_PARAM_OFF  = 6;   // first command-specific byte

  // CB status word bits
  localparam int CB_ST_ABORTED = 12;
  localparam int CB_ST_OK      = 13;
  localparam int CB_ST_BUSY    = 14;
  localparam int CB_ST_C       = 15;  // complete

  // CB command word bits
  localparam int CB_CMD_EL  = 15;
  localparam int CB_CMD_S   = 14;
  localparam int CB_CMD_I   = 13;

  // CB opcodes (bits [2:0] of the command word)
  localparam logic [2:0] CMD_NOP       = 3'd0;
  localparam logic [2:0] CMD_IA_SETUP  = 3'd1;
  localparam logic [2:0] CMD_CONFIGURE = 3'd2;
  localparam logic [2:0] CMD_MC_SETUP  = 3'd3;
  localparam logic [2:0] CMD_TRANSMIT  = 3'd4;
  localparam logic [2:0] CMD_TDR       = 3'd5;
  localparam logic [2:0] CMD_DUMP      = 3'd6;
  localparam logic [2:0] CMD_DIAGNOSE  = 3'd7;

  // Transmit command block layout (after the common header)
  localparam int TX_TBD_OFF  = 6;   // offset of the first transmit buffer desc
  localparam int TX_DEST_OFF = 8;   // 6 destination address bytes
  localparam int TX_TYPE_OFF = 14;  // type/length field

  // Transmit command block status bits
  localparam int TX_ST_NCOL_LSB = 0;   // [3:0] collision count
  localparam int TX_ST_XCOLL    = 5;
  localparam int TX_ST_HEART    = 6;
  localparam int TX_ST_DEFER    = 7;
  localparam int TX_ST_UNDERRUN = 8;
  localparam int TX_ST_NO_CTS   = 9;
  localparam int TX_ST_NO_CRS   = 10;
  localparam int TX_ST_LATECOLL = 11;

  // Transmit buffer descriptor (TBD)
  localparam int TBD_COUNT_OFF = 0;   // [13:0] count, [15] EOF
  localparam int TBD_NEXT_OFF  = 2;
  localparam int TBD_BUF_OFF   = 4;   // 24-bit buffer address
  localparam int TBD_SIZE      = 8;
  localparam int TBD_EOF_BIT   = 15;

  // -------------------------------------------------------------------------
  // Receive frame descriptor (RFD)
  // -------------------------------------------------------------------------
  localparam int RFD_STATUS_OFF = 0;
  localparam int RFD_CMD_OFF    = 2;
  localparam int RFD_LINK_OFF   = 4;
  localparam int RFD_RBD_OFF    = 6;
  localparam int RFD_DEST_OFF   = 8;
  localparam int RFD_SRC_OFF    = 14;
  localparam int RFD_TYPE_OFF   = 20;
  localparam int RFD_SIZE       = 22;

  // RFD status bits
  localparam int RFD_ST_NO_EOF   = 6;
  localparam int RFD_ST_SHORT    = 7;
  localparam int RFD_ST_OVERRUN  = 8;
  localparam int RFD_ST_NO_SPACE = 9;
  localparam int RFD_ST_ALIGN    = 10;
  localparam int RFD_ST_CRC      = 11;
  localparam int RFD_ST_OK       = 13;
  localparam int RFD_ST_BUSY     = 14;
  localparam int RFD_ST_C        = 15;

  localparam int RFD_CMD_EL = 15;
  localparam int RFD_CMD_S  = 14;

  // Receive buffer descriptor (RBD)
  localparam int RBD_COUNT_OFF = 0;   // [13:0] count, [14] F, [15] EOF
  localparam int RBD_NEXT_OFF  = 2;
  localparam int RBD_BUF_OFF   = 4;   // 24-bit buffer address
  localparam int RBD_SIZE_OFF  = 8;   // [13:0] size, [15] EL
  localparam int RBD_SIZE      = 10;
  localparam int RBD_EOF_BIT   = 15;
  localparam int RBD_F_BIT     = 14;
  localparam int RBD_EL_BIT    = 15;

  localparam logic [15:0] NULL_PTR = 16'hffff;

  // How much a memory port access moves.  BUS_SZ_WORD carries the caller's own
  // byte lanes, which is how frame data goes in and out four bytes at a time.
  localparam logic [1:0] BUS_SZ_BYTE = 2'd0;
  localparam logic [1:0] BUS_SZ_HALF = 2'd1;
  localparam logic [1:0] BUS_SZ_WORD = 2'd2;

  // -------------------------------------------------------------------------
  // CSR (Wishbone slave) register map - byte offsets
  // -------------------------------------------------------------------------
  localparam logic [7:0] CSR_CTRL     = 8'h00;
  localparam logic [7:0] CSR_STATUS   = 8'h04;
  localparam logic [7:0] CSR_SCP_ADDR = 8'h08;
  localparam logic [7:0] CSR_ID       = 8'h10;

  localparam logic [31:0] CSR_ID_VALUE = 32'h8258_6001;

  // CSR_CTRL bits
  localparam int CTRL_RST_BIT    = 0;   // level: holds the core in reset
  localparam int CTRL_CA_BIT     = 1;   // write-1-to-pulse channel attention
  localparam int CTRL_IRQ_EN_BIT = 8;

  // CSR_STATUS bits
  localparam int STAT_INT_BIT  = 0;
  localparam int STAT_BUSY_BIT = 1;
  localparam int STAT_CUS_LSB  = 4;
  localparam int STAT_RUS_LSB  = 8;

endpackage
/* verilator lint_on UNUSEDPARAM */
