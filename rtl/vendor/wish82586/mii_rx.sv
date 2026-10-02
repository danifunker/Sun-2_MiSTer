// SPDX-License-Identifier: MIT
//
// MII / GMII receive front end.  Runs entirely in the PHY's receive clock
// domain and hands bytes to the rest of the chip through an asynchronous FIFO.
//
// DATA_W selects the interface: 4 for MII, where a byte arrives as two nibbles
// low nibble first, or 8 for GMII, where a byte arrives whole.  Everything
// else - stripping the preamble and delimiter, checking the FCS, holding the
// last four bytes back so the frame handed on never includes it - is the same
// either way.
//
// FIFO word: {end, err[2:0], data[7:0]}.  Data words carry a byte of frame;
// the single end word closes the frame and carries, in err, whether the FCS
// was wrong, whether the frame ended part way through a byte, and whether the
// FIFO overflowed while the frame was being received.

module mii_rx #(
    parameter int DATA_W = 4
) (
    input  logic              rx_clk,
    input  logic              rst,

    input  logic [DATA_W-1:0] rxd,
    input  logic              rx_dv,
    input  logic              rx_er,

    output logic              fifo_wr_o,
    output logic [11:0]       fifo_data_o,
    input  logic              fifo_full_i,

    // For the unit tests and for waveform reading.
    output logic              active_o,
    output logic [15:0]       byte_count_o
);

  initial begin
    if (DATA_W != 4 && DATA_W != 8)
      $fatal(1, "mii_rx: DATA_W must be 4 (MII) or 8 (GMII)");
  end

  localparam int         HALF     = (DATA_W == 4) ? 1 : 0;  // two symbols/byte
  localparam logic [7:0] SFD_LAST = 8'h0d;   // MII: the last nibble of 0xD5
  localparam logic [7:0] SFD_FULL = 8'hd5;   // GMII: the whole byte

  localparam logic [DATA_W-1:0] PRE_SYM = {(DATA_W/4){4'h5}};
  localparam logic [DATA_W-1:0] SFD_SYM = (DATA_W == 4) ? SFD_LAST[DATA_W-1:0]
                                                        : SFD_FULL[DATA_W-1:0];

  typedef enum logic [1:0] { RX_IDLE, RX_PREAMBLE, RX_DATA, RX_END } state_e;
  state_e state;

  logic [3:0]  lo_nibble;
  logic        odd;            // MII only: a nibble is waiting for its partner
  logic [15:0] nbytes;
  logic        crc_err_q, dribble_q, overrun_q, rx_er_q;

  // The last four bytes of a frame are its FCS, which is not passed on.  Bytes
  // move into the FIFO only once four more have arrived behind them.
  logic [7:0] dl0, dl1, dl2, dl3;
  logic [2:0] dl_cnt;

  wire [7:0] rxd_pad  = {{(8-DATA_W){1'b0}}, rxd};
  wire [7:0] new_byte = (DATA_W == 4) ? {rxd_pad[3:0], lo_nibble} : rxd_pad;
  // A whole byte has arrived: always with GMII, on the second nibble with MII.
  wire       byte_now = (DATA_W == 4) ? odd : 1'b1;

  // ---- FCS ----------------------------------------------------------------
  logic crc_init, crc_en;
  logic crc_ok;
  logic [31:0] crc_unused, fcs_unused;
  crc32_eth #(.DATA_W(DATA_W)) u_crc (
      .clk      (rx_clk),
      .rst      (rst),
      .init     (crc_init),
      .en       (crc_en),
      .data_i   (rxd),
      .crc_o    (crc_unused),
      .fcs_o    (fcs_unused),
      .crc_ok_o (crc_ok)
  );

  assign crc_init = (state == RX_IDLE) || (state == RX_PREAMBLE && rx_dv &&
                                           rxd == SFD_SYM);
  assign crc_en   = (state == RX_DATA) && rx_dv;

  assign active_o     = (state != RX_IDLE);
  assign byte_count_o = nbytes;

  always_ff @(posedge rx_clk) begin
    if (rst) begin
      state       <= RX_IDLE;
      lo_nibble   <= 4'h0;
      odd         <= 1'b0;
      nbytes      <= 16'h0;
      crc_err_q   <= 1'b0;
      dribble_q   <= 1'b0;
      overrun_q   <= 1'b0;
      rx_er_q     <= 1'b0;
      dl0         <= 8'h0;
      dl1         <= 8'h0;
      dl2         <= 8'h0;
      dl3         <= 8'h0;
      dl_cnt      <= 3'h0;
      fifo_wr_o   <= 1'b0;
      fifo_data_o <= 12'h0;
    end else begin
      fifo_wr_o <= 1'b0;

      case (state)
        RX_IDLE: begin
          odd     <= 1'b0;
          nbytes  <= 16'h0;
          dl_cnt  <= 3'h0;
          rx_er_q <= 1'b0;
          if (rx_dv) begin
            overrun_q <= 1'b0;
            dribble_q <= 1'b0;
            crc_err_q <= 1'b0;
            // A frame starts with preamble; anything else is noise but is
            // followed anyway, so a missing SFD shows up as a bad frame.
            state <= RX_PREAMBLE;
          end
        end

        RX_PREAMBLE: begin
          if (!rx_dv) begin
            state <= RX_IDLE;                    // carrier event, no frame
          end else if (rxd == SFD_SYM) begin
            state <= RX_DATA;
            odd   <= 1'b0;
          end else if (rxd != PRE_SYM) begin
            // Not preamble and not the delimiter: treat what follows as data
            // so the frame is reported rather than silently dropped.
            state     <= RX_DATA;
            odd       <= (HALF == 1);
            lo_nibble <= rxd_pad[3:0];
          end
        end

        RX_DATA: begin
          if (rx_er) rx_er_q <= 1'b1;
          if (rx_dv) begin
            odd <= ~odd;
            if (!byte_now) begin
              lo_nibble <= rxd_pad[3:0];
            end else begin
              nbytes <= nbytes + 16'd1;
              if (dl_cnt == 3'd4) begin
                fifo_wr_o   <= 1'b1;
                fifo_data_o <= {4'h0, dl0};
                if (fifo_full_i) overrun_q <= 1'b1;
                dl0 <= dl1;
                dl1 <= dl2;
                dl2 <= dl3;
                dl3 <= new_byte;
              end else begin
                case (dl_cnt)
                  3'd0: dl0 <= new_byte;
                  3'd1: dl1 <= new_byte;
                  3'd2: dl2 <= new_byte;
                  default: dl3 <= new_byte;
                endcase
                dl_cnt <= dl_cnt + 3'd1;
              end
            end
          end else begin
            // Only MII can stop part way through a byte.
            dribble_q <= (HALF == 1) && odd;
            crc_err_q <= ~crc_ok;
            state     <= RX_END;
          end
        end

        RX_END: begin
          // One end word closes the frame.  It cannot be dropped, so wait for
          // room rather than losing the frame boundary.
          if (!fifo_full_i) begin
            fifo_wr_o   <= 1'b1;
            fifo_data_o <= {1'b1, crc_err_q | rx_er_q, dribble_q, overrun_q, 8'h00};
            state       <= RX_IDLE;
          end
        end

        default: state <= RX_IDLE;
      endcase
    end
  end

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, crc_unused, fcs_unused, rxd_pad};
  // verilator lint_on UNUSED

endmodule
