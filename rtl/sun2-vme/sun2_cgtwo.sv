`timescale 1ns / 1ps
//
// sun2_cgtwo.sv -- the Sun-2 Color board (cgtwo): 1152x900x8, VME A24 0x400000.
//
// The specification is tools/cg2model/cg2model.c, checked against SunOS 4.0's
// own libpixrect and kernel (doc/cgtwo.md).  This is that model in hardware,
// rule for rule; where it differs, the difference is noted.
//
// Two halves, two clocks:
//
//   cpu_clk  the card slot: decode, and one request per 68010 data phase,
//            handed to the engine and answered with DTACK.  Keyed on the data
//            strobes rather than on AS, so the two halves of a read-modify-
//            write are two requests, as they are everywhere else here.
//   clk_mem  the engine, which owns everything the board holds: the
//            registers, the eight raster-op units, the colour maps and the
//            pixels, a byte a pixel in SDRAM.
//
// Requests cross as a toggle with the request held stable until it is
// answered; the answer comes back the same way.  A request is never dropped:
// a reset (P.RESET-) clears the card's registers but the handshake runs on,
// so the CPU side can never take a stale answer for a new question.
//
// **The memory.**  Pixel n is SDRAM byte n of the board's megabyte, and a
// 16-pixel plane word is exactly one aligned 16-byte line -- one BL8 burst --
// so every access, plane mode, pixel mode or rop, is one line read and a
// write-back of the halfwords that changed.  The engine keeps the last line it
// touched (it is the only writer, so the copy cannot go stale), which makes the
// eight pixel-mode writes that cover a line cost one read.  It answers the CPU
// as soon as the answer is known -- for a write, before the write-back -- and
// takes the next request only when the write-back is done.
//
// The bus timeout.  An access here costs a line read and up to eight word
// writes in an SDRAM the CPU's memory and two scan-outs share, so it does not
// fit in the twelve clocks sun2_fpga.v allows a card.  mb_hold exempts a cycle
// this card has decoded -- memory's bargain: an address the card does not
// decode still times out, which is what the probes depend on.
//
module sun2_cgtwo (
    // ---- cpu_clk: the card slot (top_fpga's TYPE 2 space) ------------------
    input  wire         clk,
    input  wire         rst_n,          // P.RESET-: VME SYSRESET
    input  wire         present,        // the OSD's Colour board; any clock
    input  wire         mb_sel,
    input  wire [22:0]  mb_addr,        // byte address in VME A24's low 8 MiB
    input  wire         mb_we,
    input  wire         mb_uds_n,       // D15:8, the even byte
    input  wire         mb_lds_n,       // D7:0, the odd byte
    input  wire [15:0]  mb_din,
    output wire [15:0]  mb_dout,
    output wire         mb_hit,
    output wire         mb_ack,
    output wire         mb_hold,        // exempt this cycle from the bus timeout
    output wire         int_o,          // level 4
    output wire [7:0]   intvec_o,

    // ---- clk_mem: the engine -----------------------------------------------
    input  wire         mclk,
    input  wire         mrst,           // the memory clock's own: power-up only
    // the pixels: a 16-byte line read, or one halfword written
    output reg  [15:0]  m_line  = 16'd0,
    output reg  [2:0]   m_word  = 3'd0,
    output reg          m_req   = 1'b0,
    output reg          m_we    = 1'b0,
    output reg  [15:0]  m_wdata = 16'd0,
    output reg  [1:0]   m_bs    = 2'b00,
    input  wire         m_done,
    input  wire [127:0] m_rdata,
    // the display's colour map, and its enable
    output reg          cm_we   = 1'b0,
    output reg  [7:0]   cm_addr = 8'd0,
    output reg  [23:0]  cm_data = 24'd0,
    output wire         video_en,
    input  wire         retrace         // the display's vertical blank; any clock
);

    // ======================================================================
    // cpu_clk: the slot
    // ======================================================================
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  pres_s1 = 1'b0;
    reg  pres_s2 = 1'b0;
    always @(posedge clk) begin
        pres_s1 <= present;
        pres_s2 <= pres_s1;
    end

    // The board is the top half of VME0: 0x400000..0x7FFFFF.
    wire hit    = pres_s2 & mb_sel & mb_addr[22];
    wire strobe = ~mb_uds_n | ~mb_lds_n;

    reg         req_t   = 1'b0;         // toggles once per request
    reg  [21:0] q_off   = 22'd0;        // byte offset in the board's 4 MiB
    reg         q_we    = 1'b0;
    reg         q_uds   = 1'b0;
    reg         q_lds   = 1'b0;
    reg  [15:0] q_din   = 16'd0;

    wire        ack_t;                  // the engine's, mclk
    wire [15:0] e_rdata;                // stable while ack_t is
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg         ack_s1  = 1'b0;
    reg         ack_s2  = 1'b0;
    reg         ack_seen = 1'b0;
    reg         pending = 1'b0;         // a request is with the engine
    reg         issued  = 1'b0;         // this data phase has asked
    reg         done    = 1'b0;         // and has its answer
    reg  [15:0] rdata_c = 16'd0;

    always @(posedge clk) begin
        ack_s1 <= ack_t;
        ack_s2 <= ack_s1;
        if (ack_s2 != ack_seen) begin
            ack_seen <= ack_s2;
            pending  <= 1'b0;
            rdata_c  <= e_rdata;
            if (issued)
                done <= 1'b1;
        end
        if (!(hit & strobe)) begin
            issued <= 1'b0;
            done   <= 1'b0;
        end else if (!issued && !pending) begin
            issued <= 1'b1;
            pending <= 1'b1;
            // A byte with only LDS is the odd address.
            q_off  <= {mb_addr[21:1], mb_uds_n & ~mb_lds_n};
            q_we   <= mb_we;
            q_uds  <= ~mb_uds_n;
            q_lds  <= ~mb_lds_n;
            q_din  <= mb_din;
            req_t  <= ~req_t;
        end
    end

    assign mb_hit  = hit;
    assign mb_ack  = hit & strobe & done;
    assign mb_hold = hit;
    assign mb_dout = rdata_c;

    // ======================================================================
    // clk_mem: the engine
    // ======================================================================
    // The machine's reset, from the slot; the request toggle; the display.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg  rst_s1 = 1'b1, req_s1 = 1'b0, rt_s1 = 1'b0;
    reg  rst_s2 = 1'b1, req_s2 = 1'b0, rt_s2 = 1'b0;
    reg  rt_s3 = 1'b0;
    always @(posedge mclk) begin
        rst_s1 <= ~rst_n;  rst_s2 <= rst_s1;
        req_s1 <= req_t;   req_s2 <= req_s1;
        rt_s1  <= retrace; rt_s2  <= rt_s1;  rt_s3 <= rt_s2;
    end
    wire creset = rst_s2 | mrst;        // the card's registers
    wire rt_rise = rt_s2 & ~rt_s3;
    wire rt_fall = ~rt_s2 & rt_s3;

    // ---- the board's registers ---------------------------------------------
    reg  [5:0]  status  = 6'd0;         // ropmode[5:3] inten[2] update_cmap[1] video_en[0]
    reg  [7:0]  ppmask  = 8'hFF;        // the PROM draws into plane 0 without setting it
    reg  [15:0] wordpan = 16'd0, zoom = 16'd0, pixpan = 16'd0, varzoom = 16'd0, intvec = 16'd0;
    reg         inpend  = 1'b0;

    wire [2:0]  ropmode = status[5:3];
    assign video_en = status[0];

    wire [15:0] status_rd = {8'h00, rt_s2, inpend, status};  // resolution 0, no fastread, no id

    // ---- the raster-op units ---------------------------------------------------
    // memreg.h's struct memropc, the ten registers SunOS uses.  decoderout and
    // x11..x15 are not kept: nothing writes them and nothing reads any of these.
    reg  [15:0] u_dest  [0:7];
    reg  [15:0] u_src1  [0:7];
    reg  [15:0] u_src2  [0:7];
    reg  [15:0] u_pat   [0:7];
    reg  [15:0] u_mask1 [0:7];
    reg  [15:0] u_mask2 [0:7];
    reg  [3:0]  u_cnt   [0:7];          // shift, bits 3..0
    reg         u_dir   [0:7];          // shift, bit 8: 1 is left to right
    reg  [7:0]  u_op    [0:7];
    reg  [15:0] u_width [0:7];
    reg  [15:0] u_ocnt  [0:7];

    integer i;
    initial for (i = 0; i < 8; i = i + 1) begin
        u_dest[i] = 16'd0;  u_src1[i] = 16'd0;  u_src2[i] = 16'd0;  u_pat[i] = 16'd0;
        u_mask1[i] = 16'd0; u_mask2[i] = 16'd0; u_cnt[i] = 4'd0;    u_dir[i] = 1'b0;
        u_op[i] = 8'd0;     u_width[i] = 16'd0; u_ocnt[i] = 16'd0;
    end

    // ---- the colour maps -------------------------------------------------------
    // The shadow (TTL) map, red/green/blue x 256 at {colour, entry}: written by
    // the CPU, read by the CPU and by the copy to the active map.  One read
    // port, shared: the copy takes 768 clocks and the CPU waits for it.
    reg  [7:0]  shadow [0:1023];
    reg  [9:0]  sh_raddr = 10'd0;
    reg  [7:0]  sh_q = 8'd0;
    reg         sh_we = 1'b0;
    reg  [9:0]  sh_waddr = 10'd0;
    reg  [7:0]  sh_wdata = 8'd0;
    always @(posedge mclk) begin
        if (sh_we) shadow[sh_waddr] <= sh_wdata;
        sh_q <= shadow[sh_raddr];
    end

    // The copy: "copy TTL cmap to ECL cmap next vert retrace" while
    // update_cmap is set (cg2reg.h), at the leading edge of every retrace.
    // It starts only from E_IDLE, so it never takes the read port from under
    // a CPU read of the map; a CPU read that arrives meanwhile waits for it.
    reg         copy_req = 1'b0;
    reg         copying  = 1'b0;
    reg  [9:0]  cp_idx   = 10'd0;       // {entry, colour} being addressed
    reg  [9:0]  cp_i1 = 10'd0, cp_i2 = 10'd0;   // ... a clock later, two clocks later
    reg         cp_v1 = 1'b0,  cp_v2 = 1'b0;
    reg  [15:0] cp_rg    = 16'd0;

    // ---- the request, as the engine took it ------------------------------------
    reg         req_seen = 1'b0;
    reg         ack_r    = 1'b0;
    reg  [15:0] rdata_r  = 16'd0;
    assign ack_t   = ack_r;
    assign e_rdata = rdata_r;

    reg  [21:0] r_off = 22'd0;
    reg         r_we = 1'b0, r_uds = 1'b0, r_lds = 1'b0;
    reg  [15:0] r_din = 16'd0;

    wire [1:0]  r_area  = r_off[21:20];             // 0 plane, 1 pixel, 2 rop, 3 registers
    wire        r_rop   = (r_area == 2'd2);
    wire        r_pix   = (r_area == 2'd1) | (r_rop & ropmode[0]);
    wire [15:0] r_lidx  = r_pix ? r_off[19:4] : r_off[16:1];
    wire        r_word  = r_uds & r_lds;
    wire [3:0]  r_j     = r_word ? {r_off[3:1], 1'b0} : r_off[3:0];
    wire [7:0]  r_byte  = r_uds ? r_din[15:8] : r_din[7:0];   // a byte access's byte

    // write enables in a plane word, bit 15 the line's first pixel
    wire [15:0] we_pix  = r_word ? (16'hC000 >> r_j) : (16'h8000 >> r_j);
    wire [15:0] we_lane = {{8{r_uds}}, {8{r_lds}}};
    wire [15:0] r_we16  = r_pix ? we_pix : we_lane;

    // rop: what this access loads (cg2reg.h's ropmode table, doc/cgtwo.md)
    wire        ld_dst  = r_we ? ropmode[1] : ~ropmode[1];
    wire        ld_src  = ropmode[0] ? r_we : (r_we ? ~ropmode[2] : ropmode[2]);

    // ---- the line ------------------------------------------------------------------
    reg  [127:0] cline = 128'd0;        // the line last touched
    reg  [15:0]  ctag  = 16'd0;
    reg          cvalid = 1'b0;

    // pixel j of a line: halfword j>>1, the even pixel in its high byte
    function automatic [7:0] lpix(input [127:0] l, input [3:0] j);
        lpix = l[{j[3:1], ~j[0], 3'b000} +: 8];
    endfunction

    // plane p of a line, as a plane word: bit 15 is pixel 0
    function automatic [15:0] lplane(input [127:0] l, input [2:0] p);
        integer j;
        for (j = 0; j < 16; j = j + 1)
            lplane[15 - j] = l[{j[3:1], ~j[0], 3'b000} + p];
    endfunction

    // the aligner: shift right by the count, and a count of 0 is the older word
    function automatic [15:0] aligned(input [15:0] s1, input [15:0] s2,
                                      input [3:0] cnt, input dir);
        if (cnt == 4'd0)
            aligned = dir ? s2 : s1;
        else
            aligned = 16'({s2, s1} >> cnt);
    endfunction

    // the function: an 8-bit truth table over pattern, source and destination
    function automatic [15:0] ropfn(input [7:0] op, input [15:0] p,
                                    input [15:0] s, input [15:0] d);
        integer b;
        for (b = 0; b < 16; b = b + 1)
            ropfn[b] = op[{p[b], s[b], d[b]}];
    endfunction

    // a pixel-format word as unit p's source: the even byte's bit p in the
    // even bit positions, the odd byte's in the odd
    function automatic [15:0] pixsrc(input [15:0] d, input [2:0] p);
        pixsrc = (d[8 + p] ? 16'hAAAA : 16'h0000) | (d[p] ? 16'h5555 : 16'h0000);
    endfunction

    // ---- per-access working state --------------------------------------------------
    reg  [15:0] pw    [0:7];            // the line's plane words, before
    reg  [15:0] pwn   [0:7];            // and after
    reg  [7:0]  first = 8'd0, last = 8'd0;
    reg  [127:0] nline = 128'd0;
    reg  [15:0] chg   = 16'd0;          // bytes the access changed
    reg  [2:0]  wbk   = 3'd0;           // write-back: the next halfword to look at

    initial for (i = 0; i < 8; i = i + 1) begin
        pw[i] = 16'd0;
        pwn[i] = 16'd0;
    end

    // the line as it will be, from pwn
    reg  [127:0] nline_c;
    integer jj, pp;
    always @* begin
        for (jj = 0; jj < 16; jj = jj + 1)
            for (pp = 0; pp < 8; pp = pp + 1)
                nline_c[{jj[3:1], ~jj[0], 3'b000} + pp] = pwn[pp][15 - jj];
    end

    localparam [3:0] E_IDLE = 4'd0,
                     E_LOOK = 4'd1,     // decode; registers, or find the line
                     E_READ = 4'd2,     // the line is coming
                     E_C1   = 4'd3,     // plane words, unit loads, the answer
                     E_C2   = 4'd4,     // the function and the merge
                     E_C3   = 4'd5,     // the new line, what changed
                     E_WB   = 4'd6,     // write back the changed halfwords
                     E_WBW  = 4'd7,     // ... waiting for one
                     E_REGR = 4'd8,     // a colour-map read: one clock of RAM
                     E_REGQ = 4'd9;

    reg  [3:0]  est = E_IDLE;

    // Register decode, for E_LOOK.
    wire        rg_ropc   = (r_off[19:16] == 4'h0) && (r_off[15:12] <= 4'd8);
    wire [3:0]  rg_unit   = r_off[15:12];
    wire        rg_prime  = r_off[11];
    wire [3:0]  rg_reg    = r_off[4:1];
    wire        rg_cmap   = (r_off[19:16] == 4'h1) && (r_off[15:11] == 5'd0) && (r_off[10:9] != 2'b11);
    wire [2:0]  rd_unit   = (rg_unit == 4'd8) ? 3'd0 : rg_unit[2:0];  // ALLROP "reads from plane zero"

    function automatic [15:0] merge(input [15:0] old, input hi, input lo, input [15:0] d);
        merge = {hi ? d[15:8] : old[15:8], lo ? d[7:0] : old[7:0]};
    endfunction

    reg  [15:0] ropc_rd;
    always @* begin
        case (rg_reg)
            4'd0:  ropc_rd = u_dest[rd_unit];
            4'd1:  ropc_rd = u_src1[rd_unit];
            4'd2:  ropc_rd = u_src2[rd_unit];
            4'd3:  ropc_rd = u_pat[rd_unit];
            4'd4:  ropc_rd = u_mask1[rd_unit];
            4'd5:  ropc_rd = u_mask2[rd_unit];
            4'd6:  ropc_rd = {7'd0, u_dir[rd_unit], 4'd0, u_cnt[rd_unit]};
            4'd7:  ropc_rd = {8'd0, u_op[rd_unit]};
            4'd8:  ropc_rd = u_width[rd_unit];
            4'd9:  ropc_rd = u_ocnt[rd_unit];
            default: ropc_rd = 16'd0;
        endcase
    end

    integer p;
    reg [15:0] t_d, t_s1, t_s2;

    always @(posedge mclk) begin
        cm_we <= 1'b0;
        sh_we <= 1'b0;

        // ---- retrace: the colour map copy, and the interrupt --------------------
        if (rt_rise && status[1])
            copy_req <= 1'b1;
        if (copy_req && !copying && est == E_IDLE) begin
            copy_req <= 1'b0;
            copying  <= 1'b1;
            cp_idx   <= 10'd0;
            cp_v1    <= 1'b0;
            cp_v2    <= 1'b0;
        end
        if (rt_fall && status[2])
            inpend <= 1'b1;             // "enab interrupt at end of retrace"

        if (copying) begin
            // Address {entry, colour} in order, colour 3 a bubble.  The RAM
            // registers its output, so an address set on one edge has its
            // data in sh_q after the next: two stages of index to match.
            sh_raddr <= {cp_idx[1:0], cp_idx[9:2]};
            cp_i1    <= cp_idx;
            cp_v1    <= (cp_idx[1:0] != 2'd3);
            cp_i2    <= cp_i1;
            cp_v2    <= cp_v1;
            if (cp_idx != 10'd1023)
                cp_idx <= cp_idx + 10'd1;
            if (cp_v2) begin
                case (cp_i2[1:0])
                    2'd0: cp_rg[15:8] <= sh_q;
                    2'd1: cp_rg[7:0]  <= sh_q;
                    default: begin
                        cm_we   <= 1'b1;
                        cm_addr <= cp_i2[9:2];
                        cm_data <= {cp_rg, sh_q};
                        if (cp_i2[9:2] == 8'd255)
                            copying <= 1'b0;
                    end
                endcase
            end
        end

        case (est)
            E_IDLE:
                if (req_s2 != req_seen) begin
                    req_seen <= req_s2;
                    r_off <= q_off;
                    r_we  <= q_we;
                    r_uds <= q_uds;
                    r_lds <= q_lds;
                    r_din <= q_din;
                    est   <= E_LOOK;
                end

            E_LOOK:
                if (r_area == 2'd3) begin
                    // ---- registers -------------------------------------------------
                    est <= E_IDLE;
                    if (rg_ropc) begin
                        rdata_r <= ropc_rd;
                        if (r_we)
                            for (p = 0; p < 8; p = p + 1)
                                // "CG2_ALLROP: writes to all units enabled by PPMASK"
                                if (rg_unit == 4'd8 ? ppmask[p] : (rg_unit[2:0] == p[2:0])) begin
                                    if (rg_prime && (rg_reg == 4'd1 || rg_reg == 4'd2)) begin
                                        // prime sources take the value in pixel format
                                        if (rg_reg == 4'd1) u_src1[p] <= pixsrc(r_din, p[2:0]);
                                        else                u_src2[p] <= pixsrc(r_din, p[2:0]);
                                    end else case (rg_reg)
                                        4'd0: u_dest[p]  <= merge(u_dest[p],  r_uds, r_lds, r_din);
                                        4'd1: u_src1[p]  <= merge(u_src1[p],  r_uds, r_lds, r_din);
                                        4'd2: u_src2[p]  <= merge(u_src2[p],  r_uds, r_lds, r_din);
                                        4'd3: u_pat[p]   <= merge(u_pat[p],   r_uds, r_lds, r_din);
                                        4'd4: u_mask1[p] <= merge(u_mask1[p], r_uds, r_lds, r_din);
                                        4'd5: u_mask2[p] <= merge(u_mask2[p], r_uds, r_lds, r_din);
                                        4'd6: begin
                                            if (r_uds) u_dir[p] <= r_din[8];
                                            if (r_lds) u_cnt[p] <= r_din[3:0];
                                        end
                                        4'd7: if (r_lds) u_op[p] <= r_din[7:0];
                                        4'd8: u_width[p] <= merge(u_width[p], r_uds, r_lds, r_din);
                                        4'd9: u_ocnt[p]  <= merge(u_ocnt[p],  r_uds, r_lds, r_din);
                                        default: ;
                                    endcase
                                end
                        ack_r <= ~ack_r;
                    end else if (rg_cmap) begin
                        if (r_we) begin
                            // update_cmap "silently disables writing to TTL cmap"
                            if (r_lds && !status[1]) begin
                                sh_we    <= 1'b1;
                                sh_waddr <= r_off[10:1];
                                sh_wdata <= r_din[7:0];
                            end
                            rdata_r <= 16'd0;
                            ack_r   <= ~ack_r;
                        end else if (!copying) begin
                            sh_raddr <= r_off[10:1];
                            est      <= E_REGR;
                        end else
                            est <= E_LOOK;      // wait out the copy
                    end else begin
                        case (r_off[19:12])
                            8'h09: begin                // status
                                rdata_r <= status_rd;
                                if (r_we && r_lds) begin
                                    status <= r_din[5:0];
                                    // cgtwointr: "inten = 0; clear pending interrupt"
                                    if (!r_din[2]) inpend <= 1'b0;
                                end
                            end
                            8'h0A: begin
                                rdata_r <= {8'h00, ppmask};
                                if (r_we && r_lds) ppmask <= r_din[7:0];
                            end
                            8'h0B: begin
                                rdata_r <= wordpan;
                                if (r_we) wordpan <= merge(wordpan, r_uds, r_lds, r_din);
                            end
                            8'h0C: begin
                                rdata_r <= zoom;
                                if (r_we) zoom <= merge(zoom, r_uds, r_lds, r_din);
                            end
                            8'h0D: begin
                                rdata_r <= pixpan;
                                if (r_we) pixpan <= merge(pixpan, r_uds, r_lds, r_din);
                            end
                            8'h0E: begin
                                rdata_r <= varzoom;
                                if (r_we) varzoom <= merge(varzoom, r_uds, r_lds, r_din);
                            end
                            8'h0F: begin
                                rdata_r <= intvec;
                                if (r_we) intvec <= merge(intvec, r_uds, r_lds, r_din);
                            end
                            default: rdata_r <= 16'hFFFF;   // undecoded
                        endcase
                        ack_r <= ~ack_r;
                    end
                end else if (cvalid && ctag == r_lidx) begin
                    est <= E_C1;
                end else begin
                    m_line <= r_lidx;
                    m_we   <= 1'b0;
                    m_req  <= 1'b1;
                    est    <= E_READ;
                end

            E_READ:
                if (m_done) begin
                    m_req  <= 1'b0;
                    cline  <= m_rdata;
                    ctag   <= r_lidx;
                    cvalid <= 1'b1;
                    est    <= E_C1;
                end

            E_C1: begin
                // The line's plane words, and the answer.  A rop access also
                // loads its units here: the source FIFO, the destination
                // latch, the word counter.
                for (p = 0; p < 8; p = p + 1)
                    pw[p] <= lplane(cline, p[2:0]);
                case (r_area)
                    2'd0: rdata_r <= lplane(cline, r_off[19:17]);
                    2'd1: rdata_r <= r_word ? {lpix(cline, r_j), lpix(cline, r_j | 4'd1)}
                                            : {2{lpix(cline, r_j)}};
                    default:
                        if (r_pix)
                            rdata_r <= r_word ? {lpix(cline, r_j), lpix(cline, r_j | 4'd1)}
                                              : {2{lpix(cline, r_j)}};
                        else
                            rdata_r <= lplane(cline, 3'd0);   // unknown; nothing uses it
                endcase
                if (r_rop)
                    for (p = 0; p < 8; p = p + 1) begin
                        t_d = r_pix ? (r_word ? pixsrc(r_din, p[2:0])
                                              : pixsrc({r_byte, r_byte}, p[2:0]))
                                    : (r_we ? r_din : lplane(cline, p[2:0]));
                        if (ld_src) begin
                            if (u_dir[p]) begin
                                u_src2[p] <= u_src1[p];
                                u_src1[p] <= t_d;
                            end else begin
                                u_src1[p] <= u_src2[p];
                                u_src2[p] <= t_d;
                            end
                        end
                        first[p] <= 1'b0;
                        last[p]  <= 1'b0;
                        if (ld_dst) begin
                            u_dest[p] <= lplane(cline, p[2:0]);
                            first[p]  <= (u_ocnt[p] == u_width[p]);
                            last[p]   <= (u_ocnt[p] == 16'd0);
                            u_ocnt[p] <= (u_ocnt[p] == 16'd0) ? u_width[p] : u_ocnt[p] - 16'd1;
                        end
                    end
                ack_r <= ~ack_r;                // the CPU has its answer
                est   <= r_we ? E_C2 : E_IDLE;
            end

            E_C2: begin
                for (p = 0; p < 8; p = p + 1) begin
                    if (r_rop) begin
                        // the end masks protect only a destination loaded this cycle
                        t_s1 = (ld_dst ? ((first[p] ? u_mask1[p] : 16'd0) |
                                          (last[p]  ? u_mask2[p] : 16'd0)) : 16'd0);
                        t_s2 = ppmask[p] ? (r_we16 & ~t_s1) : 16'd0;
                        t_d  = ropfn(u_op[p], u_pat[p],
                                     aligned(u_src1[p], u_src2[p], u_cnt[p], u_dir[p]),
                                     u_dest[p]);
                        pwn[p] <= (pw[p] & ~t_s2) | (t_d & t_s2);
                    end else if (r_area == 2'd0) begin
                        // plane mode: the addressed plane, by byte lane
                        t_s2 = (ppmask[p] && r_off[19:17] == p[2:0]) ? we_lane : 16'd0;
                        pwn[p] <= (pw[p] & ~t_s2) | (r_din & t_s2);
                    end else begin
                        // pixel mode: the pixel(s), through the plane mask
                        t_s2 = ppmask[p] ? we_pix : 16'd0;
                        t_d  = r_word ? pixsrc(r_din, p[2:0]) : pixsrc({r_byte, r_byte}, p[2:0]);
                        pwn[p] <= (pw[p] & ~t_s2) | (t_d & t_s2);
                    end
                end
                est <= E_C3;
            end

            E_C3: begin
                nline <= nline_c;
                for (jj = 0; jj < 16; jj = jj + 1)
                    chg[15 - jj] <= (lpix(nline_c, jj[3:0]) != lpix(cline, jj[3:0]));
                cline <= nline_c;
                wbk   <= 3'd0;
                est   <= E_WB;
            end

            E_WB:
                // halfword k holds pixels 2k (high byte) and 2k+1
                if (chg[15 - {wbk, 1'b0}] | chg[14 - {wbk, 1'b0}]) begin
                    m_line  <= r_lidx;
                    m_word  <= wbk;
                    m_wdata <= nline[wbk * 16 +: 16];
                    m_bs    <= {chg[15 - {wbk, 1'b0}], chg[14 - {wbk, 1'b0}]};
                    m_we    <= 1'b1;
                    m_req   <= 1'b1;
                    est     <= E_WBW;
                end else if (wbk == 3'd7)
                    est <= E_IDLE;
                else
                    wbk <= wbk + 3'd1;

            E_WBW:
                if (m_done) begin
                    m_req <= 1'b0;
                    m_we  <= 1'b0;
                    if (wbk == 3'd7)
                        est <= E_IDLE;
                    else begin
                        wbk <= wbk + 3'd1;
                        est <= E_WB;
                    end
                end

            E_REGR:
                est <= E_REGQ;                  // the address is in; sh_q next clock

            E_REGQ: begin
                rdata_r <= {8'h00, sh_q};
                ack_r   <= ~ack_r;
                est     <= E_IDLE;
            end

            default:
                est <= E_IDLE;
        endcase

        // P.RESET- clears the board: the registers and the line, not the
        // handshake, which finishes whatever it was doing.
        if (creset) begin
            status  <= 6'd0;
            ppmask  <= 8'hFF;
            wordpan <= 16'd0;
            zoom    <= 16'd0;
            pixpan  <= 16'd0;
            varzoom <= 16'd0;
            intvec  <= 16'd0;
            inpend  <= 1'b0;
            copy_req <= 1'b0;
            copying <= 1'b0;
            cvalid  <= 1'b0;
            for (p = 0; p < 8; p = p + 1) begin
                u_dest[p] <= 16'd0;  u_src1[p] <= 16'd0;  u_src2[p] <= 16'd0;
                u_pat[p] <= 16'd0;   u_mask1[p] <= 16'd0; u_mask2[p] <= 16'd0;
                u_cnt[p] <= 4'd0;    u_dir[p] <= 1'b0;    u_op[p] <= 8'd0;
                u_width[p] <= 16'd0; u_ocnt[p] <= 16'd0;
            end
        end
    end

    // ---- to the CPU's clock: the interrupt and its vector -----------------------------
    reg irq_m = 1'b0;
    always @(posedge mclk) irq_m <= inpend & status[2];

    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg       irq_s1 = 1'b0;
    reg       irq_s2 = 1'b0;
    reg [7:0] vec_s1 = 8'd0, vec_s2 = 8'd0;   // quasi-static: written once, by cgtwoattach
    always @(posedge clk) begin
        irq_s1 <= irq_m;   irq_s2 <= irq_s1;
        vec_s1 <= intvec[7:0]; vec_s2 <= vec_s1;
    end
    assign int_o    = irq_s2 & pres_s2;
    assign intvec_o = vec_s2;

endmodule
