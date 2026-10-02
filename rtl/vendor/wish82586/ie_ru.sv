// SPDX-License-Identifier: MIT
//
// Receive unit.
//
// Takes the byte stream the MII front end put in the receive FIFO and files it
// into the receive frame area the host set up: a list of receive frame
// descriptors, and a separate list of buffer descriptors that the frames are
// poured into one after another.
//
// With AL-LOC = 1 - the way both the Sun ROM and the NetBSD drivers configure
// it - the whole frame including its MAC header goes into the buffers and the
// address fields of the descriptor are left alone.  With AL-LOC = 0 the first
// fourteen bytes go into the descriptor instead, where they land contiguously
// at offset 8 as destination, source and type, and the buffers hold only what
// follows.  The FCS has already been stripped by the front end.
//
// A frame that fails the address filter, has a bad FCS or is too short is not
// handed to the host: the descriptor and buffers it was being written into are
// rewound and used again by the next frame, and the matching SCB error counter
// is bumped.  That is what "the chip discards bad frames" means, and it is
// what the drivers expect when they configure SAV-BF off.

module ie_ru (
    input  logic        clk,
    input  logic        rst,
    input  logic        core_rst_i,

    input  logic [23:0] cbbase_i,
    input  logic [23:0] scb_addr_i,

    // ---- control from the SCB handler --------------------------------------
    input  logic        start_i,        // one cycle, with the RFA offset
    input  logic [15:0] start_rfa_i,
    input  logic        resume_i,
    input  logic        suspend_i,
    input  logic        abort_i,

    output logic [2:0]  rus_o,
    output logic        ev_fr_o,        // a frame was filed
    output logic        ev_rnr_o,       // the unit ran out of resources

    // ---- filtering, from the CONFIGURE and IA-SETUP commands ---------------
    input  logic [47:0] ia_addr_i,      // first octet in [7:0]
    input  logic        promisc_i,
    input  logic        no_bcast_i,
    input  logic        addr_in_buffer_i,   // CONFIGURE AL-LOC

    // ---- multicast list, loaded by the MC-SETUP command --------------------
    input  logic        mc_clear_i,
    input  logic        mc_wr_i,
    input  logic [47:0] mc_addr_i,
    input  logic        mc_all_i,       // list too long to hold, take them all

    input  logic        save_bad_i,
    input  logic [7:0]  min_frame_len_i,

    // ---- receive FIFO, read side -------------------------------------------
    input  logic        rx_empty_i,
    input  logic [11:0] rx_data_i,
    output logic        rx_rd_o,

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

  // Read data comes back a full word wide; these blocks all want the
  // 16-bit field that was addressed.
  wire [15:0] rdata = bus_rdata_i[15:0];

  // Descriptor field offsets, see doc/drivers/NetBSD/i82586reg.h.
  localparam logic [23:0] RFD_STATUS = 24'd0;
  localparam logic [23:0] RFD_CMD    = 24'd2;
  localparam logic [23:0] RFD_LINK   = 24'd4;
  localparam logic [23:0] RFD_RBD    = 24'd6;
  localparam logic [23:0] RBD_COUNT  = 24'd0;
  localparam logic [23:0] RBD_NEXT   = 24'd2;
  localparam logic [23:0] RBD_BUF_LO = 24'd4;
  localparam logic [23:0] RBD_BUF_HI = 24'd6;
  localparam logic [23:0] RBD_SIZE   = 24'd8;
  localparam logic [23:0] SCB_ERRCRC = 24'd8;
  localparam logic [23:0] SCB_ERRALN = 24'd10;
  localparam logic [23:0] SCB_ERRRES = 24'd12;
  localparam logic [23:0] SCB_ERROVR = 24'd14;

  localparam logic [15:0] NULL_PTR = 16'hffff;

  typedef enum logic [4:0] {
    RU_IDLE,
    RU_RD_RFD_RBD,     // first RBD of the chain, taken from the RFD at start
    RU_RD_BUF_LO,
    RU_RD_BUF_HI,
    RU_RD_SIZE,
    RU_READY,          // armed, waiting for a frame
    RU_POP,
    RU_FLUSH,          // push the part filled word out before moving on
    RU_FULL_PEEK,      // full -- but is the frame over too?  look before closing
    RU_CLOSE_FULL,     // this buffer is full, close it and move on
    RU_RD_NEXT_RBD,
    RU_DROP,           // swallow the rest of a frame we are not keeping
    RU_FIN_CLOSE_RBD,
    RU_FIN_WR_RFD_RBD,
    RU_FIN_RD_CMD,
    RU_FIN_WR_STATUS,
    RU_FIN_RD_LINK,
    RU_COUNT_ERR,
    RU_NO_RESOURCE
  } state_e;

  state_e      state;
  logic [15:0] rfd;               // current receive frame descriptor
  logic [15:0] rbd;               // current receive buffer descriptor
  logic [23:0] buf_addr;
  logic [13:0] buf_size;
  logic        rbd_el;
  logic [13:0] buf_off;
  logic [15:0] frame_len;
  logic [47:0] dst;               // destination address as it arrives
  logic        suspended;
  logic        suspend_pending;
  logic        in_frame;       // a frame is being written, not just armed
  logic        count_then_file; // the counter bump is on the way to filing

  // Frame data goes to memory a word at a time.  Bytes land in their own lane
  // of an accumulator and the word is posted as soon as the last lane fills,
  // so the bus transaction overlaps the next four bytes coming out of the
  // FIFO.  One byte per transaction is fine at 100 Mb/s and nowhere near fast
  // enough at gigabit; this is what makes the difference.
  logic [31:0] acc;
  logic [3:0]  acc_sel;
  logic [23:0] acc_addr;         // word aligned address the accumulator is for

  // The posted write: at most one is in flight, and the state machine waits
  // for it to drain before using the port for anything else.
  logic        wp_valid;
  logic [1:0]  wp_size;
  logic [3:0]  wp_sel;
  logic [23:0] wp_addr;
  logic [31:0] wp_data;
  logic        flush_to_end;     // where to go once the accumulator is empty

  wire [23:0] byte_addr = buf_addr + {10'h0, buf_off};
  wire [1:0]  lane      = byte_addr[1:0];
  wire        last_lane = (lane == 2'd3);
  // Anything held that has not been posted yet.
  wire        acc_dirty = (acc_sel != 4'h0);

  // Where this frame started, so a rejected frame can be rewound.
  logic [15:0] rbd_frame;
  logic [23:0] buf_frame;
  logic [13:0] size_frame;
  logic        el_frame;

  // Error flags carried by the end word, plus what we decide ourselves.
  logic        err_bad, err_dribble, err_overrun, err_short, rejected;

  // SCB error counters.  The chip keeps them; the host only reads them.
  logic [15:0] cnt_crc, cnt_aln, cnt_rsc, cnt_ovr;
  logic [1:0]  which_err;         // 0 crc, 1 aln, 2 rsc, 3 ovr
  logic [15:0] err_value;
  logic [23:0] err_addr;

  wire [23:0] rfd_addr = cbbase_i + {8'h00, rfd};
  wire [23:0] rbd_addr = cbbase_i + {8'h00, rbd};

  wire       word_end  = rx_data_i[11];
  wire [2:0] word_err  = rx_data_i[10:8];
  wire [7:0] word_data = rx_data_i[7:0];

  // With AL-LOC = 0 the header is written into the descriptor rather than the
  // buffer.  Destination, source and type sit one after another from offset 8,
  // so the byte index doubles as the offset.
  localparam int HDR_BYTES = 14;
  wire hdr_phase = !addr_in_buffer_i && (frame_len < 16'(HDR_BYTES));

  // ---- address filter ------------------------------------------------------
  // The multicast list is held exactly, up to MC_SLOTS entries.  A driver that
  // asks for more than that gets every multicast frame instead of a silently
  // shortened list; see doc/interface.md.
  localparam int MC_SLOTS = 8;

  logic [47:0] mc [MC_SLOTS];
  logic [3:0]  mc_n;

  always_ff @(posedge clk) begin
    if (rst || core_rst_i) begin
      mc_n <= 4'd0;
    end else if (mc_clear_i) begin
      mc_n <= 4'd0;
    end else if (mc_wr_i && mc_n < 4'(MC_SLOTS)) begin
      mc[mc_n[2:0]] <= mc_addr_i;
      mc_n     <= mc_n + 4'd1;
    end
  end

  // The decision is made on the cycle the sixth byte arrives, so it has to
  // include that byte rather than the register that is about to hold it.
  wire [47:0] dst_next = (frame_len < 16'd6)
                       ? (dst | (48'(word_data) << {frame_len[2:0], 3'b000}))
                       : dst;

  logic mc_hit;
  always_comb begin
    mc_hit = 1'b0;
    for (int i = 0; i < MC_SLOTS; i++)
      if ((4'(i) < mc_n) && (dst_next == mc[i])) mc_hit = 1'b1;
  end

  wire is_broadcast = (dst_next == 48'hffff_ffff_ffff);
  wire is_multicast = dst_next[0];         // group bit of the first octet
  wire is_ours      = (dst_next == ia_addr_i);
  wire accept_next = promisc_i || is_ours || (is_broadcast && !no_bcast_i) ||
                     (is_multicast && !is_broadcast && (mc_all_i || mc_hit));

  wire frame_is_short = ({8'h00, min_frame_len_i} > (frame_len + 16'd4));

  // What goes in the descriptor's status word.  A frame kept because SAV-BF is
  // configured still says what was wrong with it - the driver decides what to
  // do about that, but only if it is told.  Bit numbers are IE_FD_* in
  // doc/drivers/NetBSD/i82586reg.h.
  wire frame_good = !(err_bad || err_dribble || err_overrun || err_short);
  wire [15:0] rfd_status = 16'h8000                              // C
                         | (frame_good  ? 16'h2000 : 16'h0000)   // OK
                         | (err_bad     ? 16'h0800 : 16'h0000)   // CRC
                         | (err_dribble ? 16'h0400 : 16'h0000)   // alignment
                         | (err_overrun ? 16'h0100 : 16'h0000)   // overrun
                         | (err_short   ? 16'h0080 : 16'h0000);  // short

  // ---- request presented to the memory port -------------------------------
  always_comb begin
    bus_req_o   = 1'b0;
    bus_we_o    = 1'b0;
    bus_size_o  = wish82586_pkg::BUS_SZ_HALF;
    bus_sel_o   = 4'h0;
    bus_addr_o  = 24'h0;
    bus_wdata_o = 32'h0;
    if (wp_valid) begin
      // A posted frame data write always goes first; the states below wait.
      bus_req_o   = 1'b1;
      bus_we_o    = 1'b1;
      bus_size_o  = wp_size;
      bus_sel_o   = wp_sel;
      bus_addr_o  = wp_addr;
      bus_wdata_o = wp_data;
    end else
    case (state)
      RU_RD_RFD_RBD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rfd_addr + RFD_RBD;
      end
      RU_RD_BUF_LO: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rbd_addr + RBD_BUF_LO;
      end
      RU_RD_BUF_HI: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rbd_addr + RBD_BUF_HI;
      end
      RU_RD_SIZE: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rbd_addr + RBD_SIZE;
      end
      RU_CLOSE_FULL: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = rbd_addr + RBD_COUNT;
        bus_wdata_o = {16'h0, 2'b01, buf_size};            // F set, not end of frame
      end
      RU_RD_NEXT_RBD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rbd_addr + RBD_NEXT;
      end
      RU_FIN_CLOSE_RBD: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = rbd_addr + RBD_COUNT;
        bus_wdata_o = {16'h0, 2'b11, buf_off};             // F and EOF
      end
      RU_FIN_WR_RFD_RBD: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = rfd_addr + RFD_RBD;
        bus_wdata_o = {16'h0, rbd_frame};
      end
      RU_FIN_RD_CMD: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rfd_addr + RFD_CMD;
      end
      RU_FIN_WR_STATUS: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = rfd_addr + RFD_STATUS;
        bus_wdata_o = {16'h0, rfd_status};
      end
      RU_FIN_RD_LINK: begin
        bus_req_o  = 1'b1;
        bus_addr_o = rfd_addr + RFD_LINK;
      end
      RU_COUNT_ERR: begin
        bus_req_o   = 1'b1;
        bus_we_o    = 1'b1;
        bus_addr_o  = err_addr;
        bus_wdata_o = {16'h0, err_value};
      end
      default: ;
    endcase
  end

  // A word is taken from the FIFO exactly when it is dealt with, never
  // speculatively: the read enable and the state machine use the same term.
  wire pop_stall = wp_valid && (last_lane || hdr_phase);
  wire pop_now   = (state == RU_POP) && !rx_empty_i && !pop_stall;
  assign rx_rd_o = pop_now || ((state == RU_DROP) && !rx_empty_i)
                           || ((state == RU_FULL_PEEK) && !rx_empty_i && word_end);

  always_comb begin
    if (state == RU_NO_RESOURCE)                        rus_o = 3'd2;  // no resource
    else if (state == RU_IDLE && suspended)             rus_o = 3'd1;  // suspended
    else if (state == RU_IDLE)                          rus_o = 3'd0;  // idle
    else                                                rus_o = 3'd4;  // ready
  end

  // Which counter a rejected frame belongs to, and its next value.
  always_comb begin
    if (err_overrun) begin
      which_err = 2'd3;
      err_value = cnt_ovr + 16'd1;
      err_addr  = scb_addr_i + SCB_ERROVR;
    end else if (err_dribble) begin
      which_err = 2'd1;
      err_value = cnt_aln + 16'd1;
      err_addr  = scb_addr_i + SCB_ERRALN;
    end else if (err_bad) begin
      which_err = 2'd0;
      err_value = cnt_crc + 16'd1;
      err_addr  = scb_addr_i + SCB_ERRCRC;
    end else begin
      which_err = 2'd2;
      err_value = cnt_rsc + 16'd1;
      err_addr  = scb_addr_i + SCB_ERRRES;
    end
  end

  always_ff @(posedge clk) begin
    if (rst || core_rst_i) begin
      state           <= RU_IDLE;
      rfd             <= 16'h0;
      rbd             <= NULL_PTR;
      buf_addr        <= 24'h0;
      buf_size        <= 14'h0;
      rbd_el          <= 1'b0;
      buf_off         <= 14'h0;
      frame_len       <= 16'h0;
      dst             <= 48'h0;
      suspended       <= 1'b0;
      suspend_pending <= 1'b0;
      in_frame        <= 1'b0;
      count_then_file <= 1'b0;
      acc             <= 32'h0;
      acc_sel         <= 4'h0;
      acc_addr        <= 24'h0;
      wp_valid        <= 1'b0;
      wp_size         <= wish82586_pkg::BUS_SZ_WORD;
      wp_sel          <= 4'h0;
      wp_addr         <= 24'h0;
      wp_data         <= 32'h0;
      flush_to_end    <= 1'b0;
      rbd_frame       <= NULL_PTR;
      buf_frame       <= 24'h0;
      size_frame      <= 14'h0;
      el_frame        <= 1'b0;
      err_bad         <= 1'b0;
      err_dribble     <= 1'b0;
      err_overrun     <= 1'b0;
      err_short       <= 1'b0;
      rejected        <= 1'b0;
      cnt_crc         <= 16'h0;
      cnt_aln         <= 16'h0;
      cnt_rsc         <= 16'h0;
      cnt_ovr         <= 16'h0;
      ev_fr_o         <= 1'b0;
      ev_rnr_o        <= 1'b0;
    end else begin
      ev_fr_o  <= 1'b0;
      ev_rnr_o <= 1'b0;

      if (wp_valid && bus_ack_i) wp_valid <= 1'b0;

      if (suspend_i) suspend_pending <= 1'b1;
      if (abort_i) begin
        suspended       <= 1'b0;
        suspend_pending <= 1'b0;
        if (state != RU_IDLE) ev_rnr_o <= 1'b1;
        state <= RU_IDLE;
      end else begin
        case (state)
          RU_IDLE:
            if (start_i) begin
              rfd             <= start_rfa_i;
              suspended       <= 1'b0;
              suspend_pending <= 1'b0;
              state           <= RU_RD_RFD_RBD;
            end else if (resume_i && suspended) begin
              suspended <= 1'b0;
              state     <= RU_RD_RFD_RBD;
            end

          // ---- arm on a descriptor ------------------------------------------
          RU_RD_RFD_RBD:
            if (bus_ack_i) begin
              if (rdata == NULL_PTR) begin
                state <= RU_NO_RESOURCE;
              end else begin
                rbd   <= rdata;
                state <= RU_RD_BUF_LO;
              end
            end

          RU_RD_BUF_LO:
            if (bus_ack_i) begin
              buf_addr[15:0] <= rdata;
              state          <= RU_RD_BUF_HI;
            end

          RU_RD_BUF_HI:
            if (bus_ack_i) begin
              buf_addr[23:16] <= rdata[7:0];
              state           <= RU_RD_SIZE;
            end

          RU_RD_SIZE:
            if (bus_ack_i) begin
              buf_size <= rdata[13:0];
              rbd_el   <= rdata[15];
              buf_off  <= 14'h0;
              // Mid frame this is the next buffer of a frame still arriving,
              // so carry on taking bytes rather than waiting for a new one.
              state    <= in_frame ? RU_POP : RU_READY;
            end

          // ---- waiting for a frame ------------------------------------------
          // Arriving data starts a frame; the byte itself is taken in RU_POP.
          RU_READY:
            if (!rx_empty_i) begin
              // Remember where this frame starts so it can be rewound.
              // Every frame starts with an empty accumulator, whatever
              // happened to the last one.
              acc         <= 32'h0;
              acc_sel     <= 4'h0;
              rbd_frame   <= rbd;
              buf_frame   <= buf_addr;
              size_frame  <= buf_size;
              el_frame    <= rbd_el;
              buf_off     <= 14'h0;
              frame_len   <= 16'h0;
              dst         <= 48'h0;
              rejected    <= 1'b0;
              in_frame    <= 1'b1;
              err_bad     <= 1'b0;
              err_dribble <= 1'b0;
              err_overrun <= 1'b0;
              err_short   <= 1'b0;
              state <= RU_POP;
            end

          // Take a byte, put it where it belongs, and post a word whenever
          // one fills.  Nothing here waits on the bus unless the previous
          // post has not drained yet, which is what keeps up with the wire.
          RU_POP:
            if (pop_now) begin
              if (word_end) begin
                err_bad     <= word_err[2];
                err_dribble <= word_err[1];
                err_overrun <= word_err[0];
                err_short   <= frame_is_short;
                in_frame    <= 1'b0;
                flush_to_end <= 1'b1;
                state       <= RU_FLUSH;
              end else begin
                if (frame_len < 16'd6) dst[{frame_len[2:0], 3'b000} +: 8] <= word_data;
                frame_len <= frame_len + 16'd1;

                if (frame_len == 16'd5 && !accept_next) begin
                  // Not for us.  Drop what has been gathered so far as well,
                  // or it would be flushed into the next frame's buffer.
                  rejected <= 1'b1;
                  acc      <= 32'h0;
                  acc_sel  <= 4'h0;
                  state    <= RU_DROP;
                end else if (hdr_phase) begin
                  // AL-LOC = 0: the header goes into the descriptor, one byte
                  // at a time, and takes no buffer space.
                  wp_valid <= 1'b1;
                  wp_size  <= wish82586_pkg::BUS_SZ_BYTE;
                  wp_sel   <= 4'h0;
                  wp_addr  <= rfd_addr + 24'd8 + {8'h00, frame_len};
                  wp_data  <= {24'h0, word_data};
                end else begin
                  if (!acc_dirty) acc_addr <= {byte_addr[23:2], 2'b00};
                  acc[{lane, 3'b000} +: 8] <= word_data;
                  acc_sel[lane]            <= 1'b1;
                  buf_off                  <= buf_off + 14'd1;

                  if (last_lane) begin
                    // The word is complete: post it and start a fresh one.
                    wp_valid <= 1'b1;
                    wp_size  <= wish82586_pkg::BUS_SZ_WORD;
                    wp_sel   <= acc_sel | (4'h1 << lane);
                    wp_addr  <= acc_dirty ? acc_addr : {byte_addr[23:2], 2'b00};
                    wp_data  <= acc | (32'(word_data) << {lane, 3'b000});
                    acc_sel  <= 4'h0;
                    acc      <= 32'h0;
                  end

                  if (buf_off + 14'd1 >= buf_size) begin
                    flush_to_end <= 1'b0;
                    state        <= RU_FLUSH;
                  end
                end
              end
            end

          // Push out whatever is left in the accumulator, then carry on.
          RU_FLUSH:
            if (!wp_valid) begin
              if (acc_dirty) begin
                wp_valid <= 1'b1;
                wp_size  <= wish82586_pkg::BUS_SZ_WORD;
                wp_sel   <= acc_sel;
                wp_addr  <= acc_addr;
                wp_data  <= acc;
                acc_sel  <= 4'h0;
                acc      <= 32'h0;
              end else begin
                state <= flush_to_end ? RU_FIN_CLOSE_RBD : RU_FULL_PEEK;
              end
            end

          // The buffer is full.  That is not yet enough to know whether it is
          // the last one: a frame whose length is exactly the buffer size ends
          // on the same byte that fills it, and then this buffer is the end of
          // the frame and must be closed with EOF.  Closing it as merely full
          // costs an empty buffer and, worse, tells the driver the frame goes
          // on.  A driver that sizes its buffers at exactly one maximum frame
          // -- which is what SunOS's IE_BUFSZ is -- reads that as a frame too
          // long to hold, prints "giant packet" and drops it, so every
          // full-length frame is lost while everything shorter arrives.
          //
          // The receive FIFO shows its head without popping, so the answer is
          // one look: an end-of-frame marker means close with EOF, anything
          // else means the frame really does continue and the next buffer is
          // needed.  An end marker is taken as it is dealt with, the way every
          // other state takes what it handles; a data byte is left where it is
          // and picked up once the next descriptor is open.
          RU_FULL_PEEK:
            if (!rx_empty_i) begin
              if (word_end) begin
                err_bad     <= word_err[2];
                err_dribble <= word_err[1];
                err_overrun <= word_err[0];
                err_short   <= frame_is_short;
                in_frame    <= 1'b0;
                state       <= RU_FIN_CLOSE_RBD;
              end else begin
                state <= RU_CLOSE_FULL;
              end
            end

          RU_CLOSE_FULL:
            if (bus_ack_i) begin
              if (rbd_el) begin
                // The buffer list is exhausted in the middle of a frame.
                rejected <= 1'b1;
                state    <= RU_DROP;
              end else begin
                state <= RU_RD_NEXT_RBD;
              end
            end

          RU_RD_NEXT_RBD:
            if (bus_ack_i) begin
              rbd     <= rdata;
              buf_off <= 14'h0;
              state   <= RU_RD_BUF_LO;
            end

          RU_DROP:
            if (!rx_empty_i && word_end) begin
              err_bad     <= word_err[2];
              err_dribble <= word_err[1];
              err_overrun <= word_err[0];
              in_frame        <= 1'b0;
              count_then_file <= 1'b0;
              state           <= RU_COUNT_ERR;
              // Rewind to where the frame started; the buffers are ours again.
              rbd      <= rbd_frame;
              buf_addr <= buf_frame;
              buf_size <= size_frame;
              rbd_el   <= el_frame;
              buf_off  <= 14'h0;
            end

          // ---- filing a good frame -------------------------------------------
          RU_FIN_CLOSE_RBD:
            if (bus_ack_i) begin
              // A frame that was not addressed to us is never handed over.
              // Anything else that went wrong is only dropped when the host
              // has not asked for bad frames to be saved.
              if (rejected || (!save_bad_i && !frame_good)) begin
                rbd             <= rbd_frame;
                buf_addr        <= buf_frame;
                buf_size        <= size_frame;
                rbd_el          <= el_frame;
                buf_off         <= 14'h0;
                count_then_file <= 1'b0;
                state           <= RU_COUNT_ERR;
              end else if (!frame_good) begin
                // Kept because of SAV-BF, but the error still counts: the
                // drivers read these counters for their statistics.
                count_then_file <= 1'b1;
                state           <= RU_COUNT_ERR;
              end else begin
                state <= RU_FIN_WR_RFD_RBD;
              end
            end

          RU_FIN_WR_RFD_RBD:
            if (bus_ack_i) state <= RU_FIN_RD_CMD;

          RU_FIN_RD_CMD:
            if (bus_ack_i) begin
              el_frame <= rdata[15];          // reuse: EL of this RFD
              state    <= RU_FIN_WR_STATUS;
            end

          RU_FIN_WR_STATUS:
            if (bus_ack_i) begin
              ev_fr_o <= 1'b1;
              state   <= RU_FIN_RD_LINK;
            end

          RU_FIN_RD_LINK:
            if (bus_ack_i) begin
              rfd <= rdata;
              if (el_frame) begin
                // That was the last descriptor the host gave us.
                ev_rnr_o <= 1'b1;
                state    <= RU_NO_RESOURCE;
              end else if (rbd_el) begin
                // The buffer list ended too: nothing left to receive into.
                ev_rnr_o <= 1'b1;
                state    <= RU_NO_RESOURCE;
              end else if (suspend_pending) begin
                suspend_pending <= 1'b0;
                suspended       <= 1'b1;
                ev_rnr_o        <= 1'b1;
                state           <= RU_IDLE;
              end else begin
                // Carry on with the next buffer in the list.
                state <= RU_RD_NEXT_RBD;
              end
            end

          RU_COUNT_ERR:
            if (bus_ack_i) begin
              case (which_err)
                2'd0: cnt_crc <= err_value;
                2'd1: cnt_aln <= err_value;
                2'd2: cnt_rsc <= err_value;
                default: cnt_ovr <= err_value;
              endcase
              count_then_file <= 1'b0;
              state <= count_then_file ? RU_FIN_WR_RFD_RBD : RU_READY;
            end

          RU_NO_RESOURCE:
            if (resume_i || start_i) begin
              if (start_i) rfd <= start_rfa_i;
              state <= RU_RD_RFD_RBD;
            end

          default: state <= RU_IDLE;
        endcase
      end
    end
  end

  // verilator lint_off UNUSED
  wire _unused = &{1'b0, bus_rdata_i[31:16], bus_err_i};
  // verilator lint_on UNUSED

endmodule
