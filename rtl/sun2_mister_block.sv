//
// sun2_mister_block.sv
//
// The disk: the Sun-2 SCSI target's block seam (blk_*, on the CPU clock) on
// one side, MiSTer's virtual-disk port (sd_*, in hps_io's clock) on the other.
// The image is a plain file of 512-byte blocks mounted from the OSD.
//
// The seam (Wish5380 wish5380_pkg.sv, blk_req_t / blk_rsp_t):
//   blk_start  one clock, with blk_lba and blk_we valid
//   blk_buf_*  the target's own sector buffer: we write it (blk_buf_we) for a
//              read, and read it for a write -- blk_buf_rdata answers
//              blk_buf_addr one clock late
//   blk_done   one clock, blk_err valid with it
//   blk_ready, blk_count   media present, and its size in blocks
//
// hps_io (sys/hps_io.sv), for one 512-byte block:
//   the core holds sd_rd or sd_wr with sd_lba until sd_ack rises, and drops
//   it then -- held longer, the HPS sees the request again and repeats it;
//   on a read, each byte arrives as a one-clock sd_buff_wr at sd_buff_addr;
//   on a write, hps_io takes sd_buff_din for sd_buff_addr and then steps the
//   address, its bus strobes several clocks apart, so a registered read is in
//   time;
//   the transfer is over when sd_ack FALLS, not when it rises.
//
// The two sides are in different clocks, so a sector is staged in a buffer of
// this module's own -- one each way, each written in one clock and read in
// the other -- and the request and its completion cross as toggles.  The
// address and direction are held steady while a request is outstanding, so
// they cross with it.  A read is: hps_io fills rbuf, then the CPU side copies
// rbuf into the target's buffer and raises blk_done.  A write is the reverse:
// the CPU side copies the target's buffer into wbuf, then hps_io drains it.
// Copying costs 512 CPU clocks, about 26 us at 20 MHz, against the
// millisecond or so the HPS takes for the block itself.
//
`timescale 1ns / 1ps

module sun2_mister_block (
    // ---- the Sun side: the SCSI target's clock -------------------------------
    input  wire        clk,
    input  wire        blk_start,
    input  wire        blk_we,
    input  wire [31:0] blk_lba,
    input  wire [7:0]  blk_buf_rdata,
    output reg         blk_done      = 1'b0,
    output reg         blk_err       = 1'b0,
    output reg         blk_ready     = 1'b0,
    output reg  [31:0] blk_count     = 32'd0,
    output reg         blk_buf_we    = 1'b0,
    output reg  [8:0]  blk_buf_addr  = 9'd0,
    output reg  [7:0]  blk_buf_wdata = 8'd0,
    output wire        busy,            // for the disk LED

    // ---- the MiSTer side: hps_io's clock -----------------------------------
    input  wire        clk_hps,
    output reg  [31:0] sd_lba      = 32'd0,
    output reg         sd_rd       = 1'b0,
    output reg         sd_wr       = 1'b0,
    input  wire        sd_ack,
    input  wire [8:0]  sd_buff_addr,
    input  wire [7:0]  sd_buff_dout,
    output reg  [7:0]  sd_buff_din = 8'd0,
    input  wire        sd_buff_wr,
    input  wire        img_mounted,
    input  wire [63:0] img_size
);

    // ---- the two staging buffers ----------------------------------------------
    reg [7:0] rbuf [0:511];             // hps_io -> CPU side
    reg [7:0] wbuf [0:511];             // CPU side -> hps_io
    reg [8:0] rbuf_ra = 9'd0;
    reg [7:0] rbuf_q  = 8'd0;
    reg [8:0] wbuf_wa = 9'd0;
    reg [7:0] wbuf_wd = 8'd0;
    reg       wbuf_we = 1'b0;

    always @(posedge clk_hps)
        if (sd_ack && sd_buff_wr) rbuf[sd_buff_addr] <= sd_buff_dout;
    always @(posedge clk)
        rbuf_q <= rbuf[rbuf_ra];

    always @(posedge clk)
        if (wbuf_we) wbuf[wbuf_wa] <= wbuf_wd;
    always @(posedge clk_hps)
        sd_buff_din <= wbuf[sd_buff_addr];

    // ---- crossings ----------------------------------------------------------------
    reg        req_t   = 1'b0;          // CPU side -> hps side: a block to move
    reg [31:0] req_lba = 32'd0;
    reg        req_we  = 1'b0;
    reg        done_t  = 1'b0;          // hps side -> CPU side: it has moved

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] req_s = 3'd0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0] done_s = 3'd0;
    always @(posedge clk_hps) req_s  <= {req_s[1:0], req_t};
    always @(posedge clk)     done_s <= {done_s[1:0], done_t};

    // Media size: latched on the hps side when the OSD mounts or unmounts an
    // image, then carried across by a toggle once it is steady.
    reg        m_ready = 1'b0;
    reg [31:0] m_count = 32'd0;
    reg        mount_t = 1'b0;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [2:0]  mount_s = 3'd0;
    always @(posedge clk_hps)
        if (img_mounted) begin
            m_ready <= (img_size != 64'd0);
            m_count <= img_size[40:9];
            mount_t <= ~mount_t;
        end
    always @(posedge clk) begin
        mount_s <= {mount_s[1:0], mount_t};
        if (mount_s[2] != mount_s[1]) begin
            blk_ready <= m_ready;
            blk_count <= m_count;
        end
    end

    // ---- hps side ---------------------------------------------------------------------
    localparam [1:0] H_IDLE = 2'd0, H_REQ = 2'd1, H_XFER = 2'd2;
    reg [1:0] hst = H_IDLE;
    reg       req_seen = 1'b0;

    always @(posedge clk_hps) begin
        case (hst)
            H_IDLE:
                if (req_s[2] != req_seen) begin
                    req_seen <= req_s[2];
                    sd_lba   <= req_lba;
                    sd_rd    <= ~req_we;
                    sd_wr    <=  req_we;
                    hst      <= H_REQ;
                end
            H_REQ:
                if (sd_ack) begin
                    sd_rd <= 1'b0;
                    sd_wr <= 1'b0;
                    hst   <= H_XFER;
                end
            H_XFER:
                if (!sd_ack) begin
                    done_t <= ~done_t;
                    hst    <= H_IDLE;
                end
            default:
                hst <= H_IDLE;
        endcase
    end

    // ---- CPU side ------------------------------------------------------------------------
    localparam [2:0] S_IDLE = 3'd0, S_TOWBUF = 3'd1, S_WAIT = 3'd2, S_FROMRBUF = 3'd3;
    reg [2:0] st = S_IDLE;
    reg [9:0] n  = 10'd0;
    reg       done_seen = 1'b0;

    assign busy = (st != S_IDLE);

    always @(posedge clk) begin
        blk_done   <= 1'b0;
        blk_buf_we <= 1'b0;
        wbuf_we    <= 1'b0;

        case (st)
            S_IDLE: begin
                done_seen <= done_s[2];
                if (blk_start) begin
                    if (!blk_ready || blk_lba >= blk_count) begin
                        blk_err  <= 1'b1;
                        blk_done <= 1'b1;
                    end else begin
                        blk_err <= 1'b0;
                        req_lba <= blk_lba;
                        req_we  <= blk_we;
                        n       <= 10'd0;
                        if (blk_we) st <= S_TOWBUF;
                        else begin
                            req_t <= ~req_t;
                            st    <= S_WAIT;
                        end
                    end
                end
            end

            // The target's buffer -> wbuf.  Address n goes out on this edge; its
            // byte comes back on blk_buf_rdata two edges later.
            S_TOWBUF: begin
                if (n < 10'd512) blk_buf_addr <= n[8:0];
                if (n >= 10'd2) begin
                    wbuf_we <= 1'b1;
                    wbuf_wa <= n[8:0] - 9'd2;
                    wbuf_wd <= blk_buf_rdata;
                end
                if (n == 10'd513) begin
                    req_t <= ~req_t;
                    st    <= S_WAIT;
                end
                n <= n + 10'd1;
            end

            S_WAIT:
                if (done_s[2] != done_seen) begin
                    done_seen <= done_s[2];
                    n         <= 10'd0;
                    if (req_we) begin
                        blk_done <= 1'b1;
                        st       <= S_IDLE;
                    end else
                        st <= S_FROMRBUF;
                end

            // rbuf -> the target's buffer.  rbuf's read is registered, so the
            // byte for address n is written on the edge after it is asked for.
            S_FROMRBUF: begin
                if (n < 10'd512) rbuf_ra <= n[8:0];
                if (n >= 10'd2) begin
                    blk_buf_we    <= 1'b1;
                    blk_buf_addr  <= n[8:0] - 9'd2;
                    blk_buf_wdata <= rbuf_q;
                end
                if (n == 10'd513) begin
                    blk_done <= 1'b1;
                    st       <= S_IDLE;
                end
                n <= n + 10'd1;
            end

            default:
                st <= S_IDLE;
        endcase
    end

endmodule
