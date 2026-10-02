// SPDX-License-Identifier: MIT
//
// Command unit.
//
// Walks the linked list of command blocks the host built and hung off
// SCB.CBL.  For each block: mark it busy, read the opcode and the link, do
// what it asks, write back the completion status, then follow the link unless
// the block says to stop (EL) or to suspend (S).
//
// A block's command word carries EL at bit 15, S at bit 14, I at bit 13 and
// the opcode in bits [2:0].  Its status word gets C at bit 15, B at bit 14 and
// OK at bit 13, which is what the drivers poll.
//
// Implemented: NOP, IA-SETUP, CONFIGURE, MC-SETUP, TRANSMIT, TDR and
// DIAGNOSE.  DUMP completes without OK - it would have to invent the contents
// of registers this design does not have.
//
// TDR is not optional in practice: NetBSD's i82586_init() runs it on every
// bring-up and complains in the log if it fails.  There is no coaxial cable
// on the other side of an MII PHY to reflect anything, so what it reports is
// "no fault found", which is the accurate answer for this hardware.  Cable
// and link state belong to the PHY and are read over MDIO.
//
// TRANSMIT copies the buffer chain into the staging RAM and then hands it to
// mii_tx.  It reads whole words wherever the buffer allows - bytes only for an
// unaligned start or a short tail - so a full frame costs a quarter of the bus
// transactions it used to.  Staging has no real time constraint, unlike the
// receive side, so this is bus traffic and latency rather than a limit; it is
// worth doing because the bus is shared with the receive unit, which does have
// one.
//
// It hands the staged frame to mii_tx, which owns deferral, padding, the FCS and the retry
// loop.  Staging the whole frame first is what lets a collision be retried
// without going back to host memory, and it is also what makes AL-LOC = 0
// cost nothing extra: the header is simply staged ahead of the payload, so
// the transmitter never has to know which mode it is in.
//
// With AL-LOC = 1 - what both reference drivers configure - the buffer holds
// the whole frame.  With AL-LOC = 0 the destination address and the type or
// length field come from the command block and the source address from the
// last IA-SETUP, and the buffer holds only what follows them.

module ie_cu (
    input  logic        clk,
    input  logic        rst,
    input  logic        core_rst_i,

    input  logic [23:0] cbbase_i,

    // ---- control from the SCB handler --------------------------------------
    input  logic        start_i,        // one cycle, with the CBL offset
    input  logic [15:0] start_cbl_i,
    input  logic        resume_i,
    input  logic        suspend_i,
    input  logic        abort_i,

    output logic [2:0]  cus_o,
    output logic        ev_cx_o,        // a block with I completed
    output logic        ev_cna_o,       // the unit stopped being active

    // ---- parameters the datapath will need ---------------------------------
    output logic [47:0] ia_addr_o,      // individual address, first octet in [7:0]
    output logic [95:0] cfg_bytes_o,    // CONFIGURE bytes, byte 0 in [7:0]

    // ---- transmit staging RAM and the transmitter --------------------------
    output logic        tx_ram_we_o,
    output logic [10:0] tx_ram_addr_o,
    output logic [7:0]  tx_ram_data_o,
    output logic        tx_go_o,
    output logic [15:0] tx_len_o,
    input  logic        tx_done_i,
    input  logic        tx_ok_i,
    input  logic [3:0]  tx_ncoll_i,
    input  logic        tx_xcoll_i,
    input  logic        tx_defer_i,
    input  logic        tx_no_crs_i,

    // ---- internal loopback -------------------------------------------------
    // With loopback configured the frame never reaches the wire: it is handed
    // straight to the receive unit as it is read out of host memory, which
    // keeps it in one clock domain and needs no second port on the staging
    // RAM.  Word format matches the receive FIFO: {end, err[2:0], data[7:0]}.
    input  logic        lb_enable_i,
    output logic        lb_wr_o,
    output logic [11:0] lb_data_o,
    input  logic        lb_full_i,

    // ---- multicast list, streamed to the receive unit ----------------------
    output logic        mc_clear_o,     // one cycle, start of a new list
    output logic        mc_wr_o,        // one cycle, mc_addr_o is valid
    output logic [47:0] mc_addr_o,      // first octet in [7:0]
    output logic        mc_all_o,       // more addresses than can be stored

    // ---- memory port -------------------------------------------------------
    output logic        bus_req_o,
    output logic        bus_we_o,
    output logic [1:0]  bus_size_o,
    output logic [3:0]  bus_sel_o,
    output logic [23:0] bus_addr_o,
    output logic [31:0] bus_wdata_o,
    input  logic        bus_ack_i,
    input  logic [31:0] bus_rdata_i,
    input  logic        bus_err_i
);

  localparam logic [15:0] CB_ST_BUSY = 16'h4000;              // B
  localparam logic [15:0] CB_ST_DONE = 16'h8000;              // C
  localparam logic [15:0] CB_ST_OK   = 16'h2000;              // OK

  typedef enum logic [4:0] {
    CU_IDLE,
    CU_FETCH_CMD,
    CU_FETCH_LINK,
    CU_WR_BUSY,
    CU_IA,
    CU_CFG,
    CU_TX_RD_TBD,
    CU_TX_RD_CNT,
    CU_TX_RD_BUF_LO,
    CU_TX_RD_BUF_HI,
    CU_TX_SEL,
    CU_TX_RD_BYTE,
    CU_TX_RD_WORD,
    CU_TX_ST_WORD,
    CU_TX_NEXT_TBD,
    CU_TX_GO,
    CU_TX_LB_PAD,
    CU_TX_LB_END,
    CU_MC_RD_CNT,
    CU_MC_RD_ADDR,
    CU_TX_HDR_DST,
    CU_TX_HDR_SRC,
    CU_TX_HDR_LEN,
    CU_TDR_WR,
    CU_FINISH,
    CU_NEXT
  } state_e;

  state_e      state;
  logic [15:0] cb_off;
  logic [15:0] cmd;
  logic [15:0] link;
  logic [2:0]  idx;
  logic [2:0]  cfg_words;
  logic        ok;
  logic        suspended;
  logic        suspend_pending;
  logic        abort_pending;

  // Transmit staging.
  logic [15:0] tbd;
  logic [13:0] tbd_count;
  logic        tbd_eof;
  logic [23:0] tbd_buf;
  logic [13:0] tbd_off;
  logic [15:0] tx_bytes;
  logic [15:0] tx_status;      // the extra bits a transmit puts in its status
  logic        tx_done_s1, tx_done_s2;

  // Read data comes back a full word wide; these blocks all want the
  // 16-bit field that was addressed.
  wire [15:0] rdata = bus_rdata_i[15:0];

  // Multicast setup.  The command gives a byte count, six bytes per address;
  // only as many as the receive unit can hold are fetched.
  logic [31:0] tx_word;        // the four bytes last read from a buffer
  logic [1:0]  tx_st;          // which of them is going into the RAM
  logic [15:0] mc_off;         // byte offset of the address being read
  logic [3:0]  mc_left;        // addresses still to fetch

  wire [15:0] mc_bytes = rdata;   // valid while the count is being read
  wire [3:0]  mc_n = (mc_bytes >= 16'd48) ? 4'd8 :
                     (mc_bytes >= 16'd42) ? 4'd7 :
                     (mc_bytes >= 16'd36) ? 4'd6 :
                     (mc_bytes >= 16'd30) ? 4'd5 :
                     (mc_bytes >= 16'd24) ? 4'd4 :
                     (mc_bytes >= 16'd18) ? 4'd3 :
                     (mc_bytes >= 16'd12) ? 4'd2 :
                     (mc_bytes >= 16'd6)  ? 4'd1 : 4'd0;

  wire [23:0] cb_addr = cbbase_i + {8'h00, cb_off};

  // Where the next transmit byte comes from, and whether a whole word of it
  // can be taken in one go.
  wire [23:0] tx_addr     = tbd_buf + {10'h0, tbd_off};
  wire [13:0] tbd_left    = tbd_count - tbd_off;
  wire        tx_buf_done = (tbd_off >= tbd_count);
  wire        can_word    = (tbd_left >= 14'd4) && (tx_addr[1:0] == 2'b00);
  wire [2:0]  opcode  = cmd[2:0];

  // Words of CONFIGURE parameters to fetch, from the byte count in byte 0.
  // The part accepts 4 to 12 bytes; anything else is clamped.
  wire [3:0] cfg_count = rdata[3:0];
  wire [2:0] cfg_words_next = (cfg_count < 4'd2)   ? 3'd1 :
                              (cfg_count >= 4'd12) ? 3'd6 :
                              (cfg_count[3:1] + {2'b00, cfg_count[0]});

  // ---- request presented to the memory port -------------------------------
  always_comb begin
    bus_req_o   = 1'b0;
    bus_we_o    = 1'b0;
    bus_size_o  = wish82586_pkg::BUS_SZ_HALF;
    bus_sel_o   = 4'h0;
    bus_addr_o  = 24'h0;
    bus_wdata_o = 32'h0;
    case (state)
      CU_FETCH_CMD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cb_addr + 24'd2;
      end
      CU_FETCH_LINK: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cb_addr + 24'd4;
      end
      CU_WR_BUSY: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = cb_addr;
        bus_wdata_o = {16'h0, CB_ST_BUSY};
      end
      CU_IA, CU_CFG: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cb_addr + 24'd6 + {19'h0, idx, 1'b0};
      end
      CU_TX_RD_TBD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cb_addr + 24'd6;
      end
      CU_TX_HDR_DST: begin
        bus_req_o  = !(lb_enable_i && lb_full_i);
        bus_size_o = wish82586_pkg::BUS_SZ_BYTE;
        bus_addr_o = cb_addr + 24'd8 + {21'h0, idx};
      end
      CU_TX_HDR_LEN: begin
        bus_req_o  = !(lb_enable_i && lb_full_i);
        bus_size_o = wish82586_pkg::BUS_SZ_BYTE;
        bus_addr_o = cb_addr + 24'd14 + {21'h0, idx};
      end
      CU_TX_RD_CNT: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cbbase_i + {8'h00, tbd};
      end
      CU_TX_RD_BUF_LO: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cbbase_i + {8'h00, tbd} + 24'd4;
      end
      CU_TX_RD_BUF_HI: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cbbase_i + {8'h00, tbd} + 24'd6;
      end
      CU_TX_RD_BYTE: begin
        bus_req_o  = !(lb_enable_i && lb_full_i);
        bus_size_o = wish82586_pkg::BUS_SZ_BYTE;
        bus_addr_o = tx_addr;
      end
      CU_TX_RD_WORD: begin
        bus_req_o  = 1'b1;
        bus_size_o = wish82586_pkg::BUS_SZ_WORD;
        bus_sel_o  = 4'hf;
        bus_addr_o = tx_addr;
      end
      CU_TX_NEXT_TBD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cbbase_i + {8'h00, tbd} + 24'd2;
      end
      CU_MC_RD_CNT: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cb_addr + 24'd6;
      end
      CU_TDR_WR: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = cb_addr + 24'd6;
        bus_wdata_o = 32'h8000;      // link OK: no open, no short, no problem
      end
      CU_MC_RD_ADDR: begin
        bus_req_o  = 1'b1;
        bus_addr_o = cb_addr + {8'h00, mc_off} + {19'h0, idx, 1'b0};
      end
      CU_FINISH: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = cb_addr;
        bus_wdata_o = {16'h0, CB_ST_DONE | (ok ? CB_ST_OK : 16'h0) | tx_status};
      end
      default: ;
    endcase
  end

  // ---- sequencer ----------------------------------------------------------
  always_ff @(posedge clk) begin
    if (rst || core_rst_i) begin
      state           <= CU_IDLE;
      cb_off          <= 16'h0;
      cmd             <= 16'h0;
      link            <= 16'h0;
      idx             <= 3'd0;
      cfg_words       <= 3'd1;
      ok              <= 1'b0;
      suspended       <= 1'b0;
      suspend_pending <= 1'b0;
      abort_pending   <= 1'b0;
      ev_cx_o         <= 1'b0;
      ev_cna_o        <= 1'b0;
      ia_addr_o       <= 48'h0;
      cfg_bytes_o     <= 96'h0;
      tbd             <= 16'h0;
      tbd_count       <= 14'h0;
      tbd_eof         <= 1'b0;
      tbd_buf         <= 24'h0;
      tbd_off         <= 14'h0;
      tx_word         <= 32'h0;
      tx_st           <= 2'd0;
      tx_bytes        <= 16'h0;
      tx_status       <= 16'h0;
      tx_done_s1      <= 1'b0;
      tx_done_s2      <= 1'b0;
      tx_go_o         <= 1'b0;
      tx_len_o        <= 16'h0;
      tx_ram_we_o     <= 1'b0;
      tx_ram_addr_o   <= 11'h0;
      tx_ram_data_o   <= 8'h0;
      lb_wr_o         <= 1'b0;
      lb_data_o       <= 12'h0;
      mc_clear_o      <= 1'b0;
      mc_wr_o         <= 1'b0;
      mc_addr_o       <= 48'h0;
      mc_all_o        <= 1'b0;
      mc_off          <= 16'h0;
      mc_left         <= 4'h0;
    end else begin
      ev_cx_o     <= 1'b0;
      ev_cna_o    <= 1'b0;
      tx_ram_we_o <= 1'b0;
      lb_wr_o     <= 1'b0;
      mc_clear_o  <= 1'b0;
      mc_wr_o     <= 1'b0;
      tx_done_s1  <= tx_done_i;
      tx_done_s2  <= tx_done_s1;

      if (suspend_i) suspend_pending <= 1'b1;
      if (abort_i)   abort_pending   <= 1'b1;

      case (state)
        CU_IDLE: begin
          if (start_i) begin
            cb_off          <= start_cbl_i;
            suspended       <= 1'b0;
            suspend_pending <= 1'b0;
            abort_pending   <= 1'b0;
            state           <= CU_FETCH_CMD;
          end else if (resume_i && suspended) begin
            // cb_off already points at the block the list stopped on.
            suspended       <= 1'b0;
            suspend_pending <= 1'b0;
            state           <= CU_FETCH_CMD;
          end else if (abort_i) begin
            suspended <= 1'b0;
          end
        end

        CU_FETCH_CMD:
          if (bus_ack_i) begin
            cmd   <= rdata;
            state <= CU_FETCH_LINK;
          end

        CU_FETCH_LINK:
          if (bus_ack_i) begin
            link  <= rdata;
            state <= CU_WR_BUSY;
          end

        CU_WR_BUSY:
          if (bus_ack_i) begin
            idx       <= 3'd0;
            ok        <= 1'b1;
            tx_status <= 16'h0;
            case (opcode)
              wish82586_pkg::CMD_NOP:       state <= CU_FINISH;
              wish82586_pkg::CMD_IA_SETUP:  state <= CU_IA;
              wish82586_pkg::CMD_CONFIGURE: state <= CU_CFG;
              wish82586_pkg::CMD_MC_SETUP:  state <= CU_MC_RD_CNT;
              wish82586_pkg::CMD_TRANSMIT: begin
                tx_bytes <= 16'h0;
                // AL-LOC is bit 3 of CONFIGURE byte 3: set means the whole
                // frame is in the buffer, clear means the header is here.
                state <= cfg_bytes_o[27] ? CU_TX_RD_TBD : CU_TX_HDR_DST;
              end
              wish82586_pkg::CMD_TDR:      state <= CU_TDR_WR;
              // The internal logic is what it is; there is nothing to fail.
              wish82586_pkg::CMD_DIAGNOSE: state <= CU_FINISH;
              // DUMP would have to invent 170 bytes of register contents.
              default: begin
                ok    <= 1'b0;
                state <= CU_FINISH;
              end
            endcase
          end

        CU_IA:
          if (bus_ack_i) begin
            ia_addr_o[{idx[1:0], 4'h0} +: 16] <= rdata;
            if (idx == 3'd2) state <= CU_FINISH;
            else             idx   <= idx + 3'd1;
          end

        CU_CFG:
          if (bus_ack_i) begin
            cfg_bytes_o[{idx, 4'h0} +: 16] <= rdata;
            if (idx == 3'd0) begin
              // Byte 0 of the parameters says how many bytes to configure, so
              // how many more words there are to fetch only becomes known once
              // the first one has arrived.
              cfg_words <= cfg_words_next;
              if (cfg_words_next <= 3'd1) state <= CU_FINISH;
              else                        idx   <= 3'd1;
            end else if (idx + 3'd1 >= cfg_words) begin
              state <= CU_FINISH;
            end else begin
              idx <= idx + 3'd1;
            end
          end

        // ---- multicast setup -----------------------------------------------
        // The count is in bytes, six per address.  More addresses than the
        // receive unit can hold makes it take every multicast frame instead;
        // see doc/interface.md.
        CU_MC_RD_CNT:
          if (bus_ack_i) begin
            mc_clear_o <= 1'b1;
            mc_all_o   <= (rdata > 16'd48);
            mc_left    <= mc_n;
            mc_off     <= 16'd8;
            idx        <= 3'd0;
            if (rdata < 16'd6) state <= CU_FINISH;
            else                     state <= CU_MC_RD_ADDR;
          end

        CU_MC_RD_ADDR:
          if (bus_ack_i) begin
            mc_addr_o[{idx[1:0], 4'h0} +: 16] <= rdata;
            if (idx == 3'd2) begin
              mc_wr_o <= 1'b1;
              idx     <= 3'd0;
              mc_off  <= mc_off + 16'd6;
              mc_left <= mc_left - 4'd1;
              if (mc_left == 4'd1) state <= CU_FINISH;
            end else begin
              idx <= idx + 3'd1;
            end
          end

        // ---- transmit ------------------------------------------------------
        // ---- AL-LOC = 0: stage the header before the payload ---------------
        CU_TX_HDR_DST:
          if (bus_ack_i) begin
            tx_ram_we_o   <= 1'b1;
            tx_ram_addr_o <= tx_bytes[10:0];
            tx_ram_data_o <= rdata[7:0];
            tx_bytes      <= tx_bytes + 16'd1;
            if (lb_enable_i) begin
              lb_wr_o   <= 1'b1;
              lb_data_o <= {4'h0, rdata[7:0]};
            end
            if (idx == 3'd5) begin
              idx   <= 3'd0;
              state <= CU_TX_HDR_SRC;
            end else begin
              idx <= idx + 3'd1;
            end
          end

        // The source address is ours, so it needs no reading.
        CU_TX_HDR_SRC:
          if (!(lb_enable_i && lb_full_i)) begin
            tx_ram_we_o   <= 1'b1;
            tx_ram_addr_o <= tx_bytes[10:0];
            tx_ram_data_o <= ia_addr_o[{idx, 3'b000} +: 8];
            tx_bytes      <= tx_bytes + 16'd1;
            if (lb_enable_i) begin
              lb_wr_o   <= 1'b1;
              lb_data_o <= {4'h0, ia_addr_o[{idx, 3'b000} +: 8]};
            end
            if (idx == 3'd5) begin
              idx   <= 3'd0;
              state <= CU_TX_HDR_LEN;
            end else begin
              idx <= idx + 3'd1;
            end
          end

        CU_TX_HDR_LEN:
          if (bus_ack_i) begin
            tx_ram_we_o   <= 1'b1;
            tx_ram_addr_o <= tx_bytes[10:0];
            tx_ram_data_o <= rdata[7:0];
            tx_bytes      <= tx_bytes + 16'd1;
            if (lb_enable_i) begin
              lb_wr_o   <= 1'b1;
              lb_data_o <= {4'h0, rdata[7:0]};
            end
            if (idx == 3'd1) begin
              idx   <= 3'd0;
              state <= CU_TX_RD_TBD;
            end else begin
              idx <= idx + 3'd1;
            end
          end

        CU_TX_RD_TBD:
          if (bus_ack_i) begin
            tbd <= rdata;
            if (rdata == 16'hffff) begin
              // Nothing to send; report it rather than transmitting rubbish.
              ok    <= 1'b0;
              state <= CU_FINISH;
            end else begin
              state <= CU_TX_RD_CNT;
            end
          end

        CU_TX_RD_CNT:
          if (bus_ack_i) begin
            tbd_count <= rdata[13:0];
            tbd_eof   <= rdata[15];
            tbd_off   <= 14'h0;
            state     <= CU_TX_RD_BUF_LO;
          end

        CU_TX_RD_BUF_LO:
          if (bus_ack_i) begin
            tbd_buf[15:0] <= rdata;
            state         <= CU_TX_RD_BUF_HI;
          end

        CU_TX_RD_BUF_HI:
          if (bus_ack_i) begin
            tbd_buf[23:16] <= rdata[7:0];
            state          <= CU_TX_SEL;
          end

        // Take a whole word where the buffer allows it, a byte otherwise.
        CU_TX_SEL:
          if (tx_buf_done)   state <= tbd_eof ? CU_TX_GO : CU_TX_NEXT_TBD;
          else if (can_word) state <= CU_TX_RD_WORD;
          else               state <= CU_TX_RD_BYTE;

        CU_TX_RD_BYTE:
          if (bus_ack_i) begin
            tx_ram_we_o   <= 1'b1;
            tx_ram_addr_o <= tx_bytes[10:0];
            tx_ram_data_o <= rdata[7:0];
            tx_bytes      <= tx_bytes + 16'd1;
            tbd_off       <= tbd_off + 14'd1;
            if (lb_enable_i) begin
              lb_wr_o   <= 1'b1;
              lb_data_o <= {4'h0, rdata[7:0]};
            end
            state <= CU_TX_SEL;
          end

        CU_TX_RD_WORD:
          if (bus_ack_i) begin
            tx_word <= bus_rdata_i;
            tx_st   <= 2'd0;
            state   <= CU_TX_ST_WORD;
          end

        // The staging RAM takes a byte a cycle, so the word goes in over four.
        CU_TX_ST_WORD:
          if (!(lb_enable_i && lb_full_i)) begin
            tx_ram_we_o   <= 1'b1;
            tx_ram_addr_o <= tx_bytes[10:0];
            tx_ram_data_o <= tx_word[{tx_st, 3'b000} +: 8];
            tx_bytes      <= tx_bytes + 16'd1;
            tbd_off       <= tbd_off + 14'd1;
            if (lb_enable_i) begin
              lb_wr_o   <= 1'b1;
              lb_data_o <= {4'h0, tx_word[{tx_st, 3'b000} +: 8]};
            end
            tx_st <= tx_st + 2'd1;
            if (tx_st == 2'd3) state <= CU_TX_SEL;
          end

        CU_TX_NEXT_TBD:
          if (bus_ack_i) begin
            tbd <= rdata;
            if (rdata == 16'hffff) state <= CU_TX_GO;
            else                         state <= CU_TX_RD_CNT;
          end

        CU_TX_GO: begin
          tx_len_o <= tx_bytes;
          if (lb_enable_i) begin
            state <= CU_TX_LB_PAD;
          end else begin
            tx_go_o <= 1'b1;
          end
          if (tx_go_o && tx_done_s2) begin
            tx_go_o   <= 1'b0;
            ok        <= tx_ok_i;
            // Transmit status bits, see doc/drivers/NetBSD/i82586reg.h.
            tx_status <= (tx_no_crs_i ? 16'h0400 : 16'h0000) |
                         (tx_defer_i  ? 16'h0080 : 16'h0000) |
                         (tx_xcoll_i  ? 16'h0020 : 16'h0000) |
                         {12'h000, tx_ncoll_i};
            state     <= CU_FINISH;
          end
        end

        // Loopback pads the same way the wire would before closing the frame.
        CU_TX_LB_PAD:
          if (!lb_full_i) begin
            if (tx_bytes + 16'd4 >= {8'h00, cfg_bytes_o[87:80]}) begin
              state <= CU_TX_LB_END;
            end else begin
              lb_wr_o   <= 1'b1;
              lb_data_o <= 12'h000;
              tx_bytes  <= tx_bytes + 16'd1;
            end
          end

        CU_TX_LB_END:
          if (!lb_full_i) begin
            lb_wr_o   <= 1'b1;
            lb_data_o <= 12'h800;          // end of frame, no errors
            ok        <= 1'b1;
            state     <= CU_FINISH;
          end

        CU_TDR_WR:
          if (bus_ack_i) state <= CU_FINISH;

        CU_FINISH:
          if (bus_ack_i) begin
            if (cmd[13]) ev_cx_o <= 1'b1;   // I: interrupt on completion
            state <= CU_NEXT;
          end

        CU_NEXT: begin
          if (abort_pending || cmd[15]) begin          // aborted, or end of list
            abort_pending <= 1'b0;
            suspended     <= 1'b0;
            ev_cna_o      <= 1'b1;
            state         <= CU_IDLE;
          end else if (cmd[14] || suspend_pending) begin   // suspend after this
            cb_off          <= link;
            suspend_pending <= 1'b0;
            suspended       <= 1'b1;
            ev_cna_o        <= 1'b1;
            state           <= CU_IDLE;
          end else begin
            cb_off <= link;
            state  <= CU_FETCH_CMD;
          end
        end

        default: state <= CU_IDLE;
      endcase
    end
  end

  always_comb begin
    if (state != CU_IDLE)   cus_o = wish82586_pkg::CUS_ACTIVE;
    else if (suspended)     cus_o = wish82586_pkg::CUS_SUSPENDED;
    else                    cus_o = wish82586_pkg::CUS_IDLE;
  end

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, bus_err_i, cmd[12:3]};
  // verilator lint_on UNUSED

endmodule
