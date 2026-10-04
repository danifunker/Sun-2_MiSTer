// tb_cgtwo -- the colour board's RTL against the C model, bus cycle by bus cycle.
//
// tools/cg2model's harness runs SunOS 4.0's own libpixrect (or its kernel's
// cg2_rop and cgtwo driver) against the model and records every bus cycle it
// makes on the board, with the data, plus the board's megabyte of pixels
// before the first and after the last (harness -t TRACE -I INIT -F FINAL).
// This replays the cycles into rtl/sun2-vme/sun2_cgtwo.sv as 68010 data
// phases on the CPU's clock, behind a line-port memory with random latency on
// a memory clock at an awkward ratio to it, and checks
//
//   * every read returns what the model returned -- except the status
//     register's retrace and interrupt-pending bits, which follow this bench's
//     own display rather than the harness's;
//   * the megabyte matches the model's at the end, byte for byte.
//
//   make -C tb/verilator tb_cgtwo [CG2_N=400] [CG2_SEED=1] [CG2_KERNEL=1]
//
`timescale 1ns / 1ps

module tb_cgtwo;

    // ---- clocks: the CPU's 20 MHz, and a memory clock that never lines up --------
    reg clk = 1'b0, mclk = 1'b0;
    always #25 clk = ~clk;
    always #4.85 mclk = ~mclk;

    // ---- the slot ---------------------------------------------------------------
    reg         rst_n    = 1'b0;
    reg         mb_sel   = 1'b0;
    reg  [22:0] mb_addr  = 23'd0;
    reg         mb_we    = 1'b0;
    reg         mb_uds_n = 1'b1;
    reg         mb_lds_n = 1'b1;
    reg  [15:0] mb_din   = 16'd0;
    wire [15:0] mb_dout;
    wire        mb_hit, mb_ack, mb_hold, int_o;
    wire [7:0]  intvec_o;

    // ---- the memory side ---------------------------------------------------------
    wire [15:0] m_line, m_wdata;
    wire [2:0]  m_word;
    wire [1:0]  m_bs;
    wire        m_req, m_we;
    reg         m_done  = 1'b0;
    reg [127:0] m_rdata = 128'd0;
    wire        cm_we, video_en;
    wire [7:0]  cm_addr;
    wire [23:0] cm_data;
    reg         retrace = 1'b0;

    sun2_cgtwo dut (
        .clk(clk), .rst_n(rst_n), .present(1'b1),
        .mb_sel(mb_sel), .mb_addr(mb_addr), .mb_we(mb_we),
        .mb_uds_n(mb_uds_n), .mb_lds_n(mb_lds_n), .mb_din(mb_din),
        .mb_dout(mb_dout), .mb_hit(mb_hit), .mb_ack(mb_ack), .mb_hold(mb_hold),
        .int_o(int_o), .intvec_o(intvec_o),
        .mclk(mclk), .mrst(1'b0),
        .m_line(m_line), .m_word(m_word), .m_req(m_req), .m_we(m_we),
        .m_wdata(m_wdata), .m_bs(m_bs), .m_done(m_done), .m_rdata(m_rdata),
        .cm_we(cm_we), .cm_addr(cm_addr), .cm_data(cm_data),
        .video_en(video_en), .retrace(retrace)
    );

    // ---- the board's megabyte, and the line port into it --------------------------
    // Line L is pixels 16L..16L+15; halfword k of it is pixels 2k (high byte)
    // and 2k+1, as rtl/sun2_mister_sdram.sv lays an SDRAM burst out.
    reg [7:0] pix  [0:1048575];
    reg [7:0] want [0:1048575];

    function automatic [127:0] line_of(input [15:0] l);
        for (int j = 0; j < 16; j++)
            line_of[{j[3:1], ~j[0], 3'b000} +: 8] = pix[{l, j[3:0]}];
    endfunction

    typedef enum logic [1:0] { M_IDLE, M_WAIT, M_GAP } mstate_t;
    mstate_t ms = M_IDLE;
    int      mdelay = 0;
    longint  nreads = 0, nwrites = 0;

    always @(posedge mclk) begin
        m_done <= 1'b0;
        case (ms)
            M_IDLE: if (m_req) begin
                mdelay <= $urandom % 24;
                ms     <= M_WAIT;
            end
            M_WAIT: if (mdelay == 0) begin
                if (m_we) begin
                    if (m_bs[1]) pix[{m_line, m_word, 1'b0}] <= m_wdata[15:8];
                    if (m_bs[0]) pix[{m_line, m_word, 1'b1}] <= m_wdata[7:0];
                    nwrites <= nwrites + 1;
                end else begin
                    m_rdata <= line_of(m_line);
                    nreads  <= nreads + 1;
                end
                m_done <= 1'b1;
                ms     <= M_GAP;
            end else
                mdelay <= mdelay - 1;
            M_GAP: ms <= M_IDLE;
            default: ms <= M_IDLE;
        endcase
    end

    // A display of sorts: the retrace bit moves, so the colour map copy runs.
    int rcount = 0;
    always @(posedge mclk) begin
        rcount <= rcount + 1;
        if (rcount == 5000) begin
            rcount  <= 0;
            retrace <= ~retrace;
        end
    end

    // ---- one 68010 data phase ---------------------------------------------------------
    int     errors = 0;
    longint ncycles = 0;

    task automatic phase(input bit wr, input [1:0] strobes, input [21:0] off,
                         input [15:0] wdata, output [15:0] rdata);
        int n;
        @(posedge clk);
        mb_addr  <= {1'b1, off[21:1], 1'b0};
        mb_we    <= wr;
        mb_din   <= wdata;
        mb_sel   <= 1'b1;
        mb_uds_n <= ~strobes[1];
        mb_lds_n <= ~strobes[0];
        n = 0;
        do begin
            @(posedge clk);
            n++;
        end while (!mb_ack && n < 200000);
        if (!mb_ack) begin
            $display("tb_cgtwo: no DTACK for %s%0d %06x", wr ? "w" : "r", strobes, off);
            $fatal;
        end
        if (!mb_hold) begin
            $display("tb_cgtwo: a decoded cycle without mb_hold");
            errors++;
        end
        rdata = mb_dout;
        mb_sel   <= 1'b0;
        mb_uds_n <= 1'b1;
        mb_lds_n <= 1'b1;
        ncycles++;
    endtask

    // ---- the replay -----------------------------------------------------------------------
    string trace_f, init_f, final_f;
    initial begin
        int fd, rc, strobes;
        string tok;
        logic [31:0] off, data;
        logic [15:0] got, mask;
        if (!$value$plusargs("trace=%s", trace_f) || !$value$plusargs("init=%s", init_f) ||
            !$value$plusargs("final=%s", final_f)) begin
            $display("tb_cgtwo: +trace=, +init= and +final= are required");
            $fatal;
        end
        fd = $fopen(init_f, "rb");
        if (fd == 0) $fatal(1, "can't open %s", init_f);
        rc = $fread(pix, fd);
        $fclose(fd);
        fd = $fopen(final_f, "rb");
        if (fd == 0) $fatal(1, "can't open %s", final_f);
        rc = $fread(want, fd);
        $fclose(fd);

        repeat (10) @(posedge clk);
        rst_n <= 1'b1;
        repeat (10) @(posedge clk);

        fd = $fopen(trace_f, "r");
        if (fd == 0) $fatal(1, "can't open %s", trace_f);
        while ($fscanf(fd, "%s %h %h\n", tok, off, data) == 3) begin
            bit wr = (tok[0] == "w");
            strobes = tok[1] - "0";
            phase(wr, strobes[1:0], off[21:0], data[15:0], got);
            if (!wr) begin
                mask = {strobes[1] ? 8'hFF : 8'h00, strobes[0] ? 8'hFF : 8'h00};
                // the status register's retrace and pending bits are this
                // bench's display's, not the harness's
                if ((off & 32'hFFF000) == 32'h309000)
                    mask &= 16'hFF3F;
                if ((got & mask) != (data[15:0] & mask)) begin
                    if (errors < 20)
                        $display("tb_cgtwo: cycle %0d: read %0d %06x gave %04x, the model %04x",
                                 ncycles, strobes, off, got, data[15:0]);
                    errors++;
                end
            end
        end
        $fclose(fd);

        // let the last write-back land
        repeat (200) @(posedge mclk);
        begin
            int bad = 0;
            for (int i = 0; i < 1048576; i++)
                if (pix[i] != want[i]) begin
                    if (bad < 10)
                        $display("tb_cgtwo: pixel %0d (%0d,%0d): RTL %02x, model %02x",
                                 i, i % 1152, i / 1152, pix[i], want[i]);
                    bad++;
                end
            if (bad) begin
                $display("tb_cgtwo: %0d pixels differ", bad);
                errors++;
            end
        end
        $display("tb_cgtwo: %0d bus cycles, %0d line reads, %0d halfword writes, %0d errors: %s",
                 ncycles, nreads, nwrites, errors, errors ? "FAIL" : "PASS");
        $finish;
    end

endmodule
