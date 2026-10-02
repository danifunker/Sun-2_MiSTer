//============================================================================
//  tb_scsi_odd -- rtl/sun2-common/sun2_scsi_core.sv's Odd Length bit, driven
//  the way SunOS 4.0's standalone scdoit drives it (the one tpboot carries,
//  disassembled from the 4.0 Sun-2 tape at 0x124632):
//
//    data = 1 << target; wait for BSY clear; icr = SELECT; wait for BSY;
//    icr = WORD_MODE | DMA_ENABLE; dma_addr; dma_count = ~len; six CDB bytes
//    by PIO; wait for IntReq; if Odd Length, fix up the residue -- for READ
//    and REQUEST SENSE take the last byte from the data register and count
//    it, for anything else count one byte back; status and message by PIO;
//    return len - (~dma_count & 0xFFFF).
//
//  The board's Odd Length is its SecondByte flip-flop, the parity of the
//  transfer in progress.  It must be set after an odd word-mode read, and it
//  must not survive into the next command, which selects with word mode off:
//  held over, the fix-up turns a command that moves nothing into a residue of
//  -1, which is how tpboot came to say "boot failed".
//
//  The target is the core's own disk, scsi_targ, at ID 0.
//
//      make -C tb/verilator tb_scsi_odd
//============================================================================
`timescale 1ns/1ps

module tb_scsi_odd;

reg clk = 0;
always #25 clk = ~clk;                      // 20 MHz
reg rst = 1;

// ---- the register port -----------------------------------------------------
reg         sel = 0, fire = 0, we = 0, uds_n = 1, lds_n = 1;
reg  [2:0]  regi = 0;
reg  [15:0] din = 0;
wire [15:0] dout;

// ---- DVMA: a memory that answers every cycle at once -------------------------
wire        wb_cyc, wb_stb, wb_we, wb_clr;
wire [3:0]  wb_sel;
wire [21:0] wb_adr;
wire [31:0] wb_dat_w;
reg  [31:0] wb_dat_r = 0;
reg         wb_ack = 0;
bit  [7:0]  mem [int];

always @(posedge clk) begin
    wb_ack <= 1'b0;
    if (wb_cyc && wb_stb && !wb_ack) begin
        wb_ack <= 1'b1;
        // Lane n is byte address n of the longword (the core's convention), and
        // the address is the DVMA one, 0xF00000 up; mem is keyed by dma_addr.
        for (int b = 0; b < 4; b++) begin
            int a;
            a = {wb_adr, 2'b00} - 32'hF00000 + b;
            if (wb_we && wb_sel[b]) mem[a] = wb_dat_w[8*b +: 8];
            wb_dat_r[8*b +: 8] <= mem.exists(a) ? mem[a] : 8'h00;
        end
    end
end

// ---- the disk's back end: every block is its own number, repeated -------------
wire        blk_start, blk_we;
wire [31:0] blk_lba;
wire [7:0]  blk_buf_rdata;
reg         blk_done = 0, blk_buf_we = 0;
reg  [8:0]  blk_buf_addr = 0;
reg  [7:0]  blk_buf_wdata = 0;

initial forever begin
    @(posedge clk);
    blk_done <= 1'b0;
    if (blk_start) begin
        reg [31:0] lba;
        lba = blk_lba;
        repeat (20) @(posedge clk);
        for (int i = 0; i < 512; i++) begin
            blk_buf_we <= 1'b1; blk_buf_addr <= 9'(i); blk_buf_wdata <= 8'(lba + i);
            @(posedge clk);
        end
        blk_buf_we <= 1'b0;
        blk_done   <= 1'b1;
    end
end

sun2_scsi_core #(.HAS_TAPE(0)) dut (
    .CLK(clk), .RESET(rst),
    .sel_i(sel), .fire_i(fire), .reg_i(regi), .we_i(we), .uds_n_i(uds_n), .lds_n_i(lds_n),
    .din_i(din), .dout_o(dout), .int_o(), .intvec_o(),
    .wb_cyc_o(wb_cyc), .wb_stb_o(wb_stb), .wb_we_o(wb_we), .wb_sel_o(wb_sel),
    .wb_adr_o(wb_adr), .wb_dat_o(wb_dat_w), .wb_dat_i(wb_dat_r), .wb_ack_i(wb_ack),
    .wb_err_i(1'b0), .wb_clr_o(wb_clr),
    .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba), .blk_buf_rdata(blk_buf_rdata),
    .blk_done(blk_done), .blk_err(1'b0), .blk_ready(1'b1), .blk_count(32'd1000),
    .blk_buf_we(blk_buf_we), .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata),
    .tblk_start(), .tblk_lba(), .tblk_buf_rdata(),
    .tblk_done(1'b0), .tblk_err(1'b0), .tblk_ready(1'b0), .tblk_count(32'd0),
    .tblk_buf_we(1'b0), .tblk_buf_addr(9'd0), .tblk_buf_wdata(8'd0),
    .tape_changed(1'b0), .tape_volume(2'd0));

// ---- checks -------------------------------------------------------------------
integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++; else begin fails++; $display("FAIL: %s", what); end
endtask

// ---- CPU accesses: a few clocks of decode, then the acknowledging clock --------
localparam [2:0] R_DATA = 3'd0, R_CMD = 3'd1, R_ICR = 3'd2, R_ADRHI = 3'd4,
                 R_ADRLO = 3'd5, R_COUNT = 3'd6;
localparam int B_BSY = 6, B_REQ = 11, B_INT = 12, B_ODD = 13;

task automatic wr(input [2:0] r, input [15:0] d, input bit hi, input bit lo);
    @(posedge clk);
    sel <= 1; regi <= r; we <= 1; din <= d; uds_n <= !hi; lds_n <= !lo;
    repeat (3) @(posedge clk);
    fire <= 1;
    @(posedge clk);
    fire <= 0; sel <= 0; we <= 0; uds_n <= 1; lds_n <= 1;
    repeat (2) @(posedge clk);
endtask

task automatic rd(input [2:0] r, input bit hi, input bit lo, output [15:0] d);
    @(posedge clk);
    sel <= 1; regi <= r; we <= 0; uds_n <= !hi; lds_n <= !lo;
    repeat (3) @(posedge clk);
    fire <= 1;
    @(posedge clk);
    fire <= 0;
    @(posedge clk);
    d = dout;
    sel <= 0; uds_n <= 1; lds_n <= 1;
    repeat (2) @(posedge clk);
endtask

task automatic wait_icr(input int bit_no, input bit val, output bit ok);
    reg [15:0] icr;
    ok = 0;
    for (int n = 0; n < 20000; n++) begin
        rd(R_ICR, 1, 1, icr);
        if (icr[bit_no] == val) begin ok = 1; return; end
    end
endtask

bit saw_odd;        // Odd Length as scdoit found it, before any fix-up

// scdoit, instruction for instruction where it matters.  Returns the count it
// returns: len - (~dma_count & 0xFFFF), or -1 for a SCSI-level failure.
task automatic scdoit(input bit [7:0] c0, c1, c2, c3, c4, c5, input int len,
                      input int addr, output int r);
    reg [15:0] icr, v, cnt;
    bit ok;
    bit [7:0] cdb [6];
    cdb = '{c0, c1, c2, c3, c4, c5};
    r = -1;
    wr(R_DATA, 16'h0100, 1, 0);                         // 1 << target 0, even byte
    wait_icr(B_BSY, 0, ok);  if (!ok) return;
    wr(R_ICR, 16'h0020, 0, 1);                          // SELECT, and word mode off
    wait_icr(B_BSY, 1, ok);  if (!ok) return;
    wr(R_ICR, 16'h0006, 0, 1);                          // WORD_MODE | DMA_ENABLE
    wr(R_ADRHI, 16'(addr >> 16), 0, 1);
    wr(R_ADRLO, 16'(addr), 1, 1);
    wr(R_COUNT, ~16'(len), 1, 1);
    for (int i = 0; i < 6; i++) begin
        wait_icr(B_REQ, 1, ok);  if (!ok) return;
        wr(R_CMD, {cdb[i], 8'h00}, 1, 0);
    end
    wait_icr(B_INT, 1, ok);  if (!ok) return;
    rd(R_ICR, 1, 1, icr);
    saw_odd = icr[B_ODD];
    if (icr[B_ODD]) begin
        rd(R_COUNT, 1, 1, cnt);
        if (c0 == 8'h03 || c0 == 8'h08) begin
            rd(R_DATA, 1, 0, v);
            mem[addr + len - 1] = v[15:8];
            cnt = ~(~cnt - 16'd1);
        end else
            cnt = ~(~cnt + 16'd1);
        wr(R_COUNT, cnt, 1, 1);
    end
    wait_icr(B_REQ, 1, ok);  if (!ok) return;
    rd(R_CMD, 1, 0, v);                                 // status
    wait_icr(B_REQ, 1, ok);  if (!ok) return;
    rd(R_CMD, 1, 0, v);                                 // message
    if (v[15:8] != 8'h00) return;
    rd(R_COUNT, 1, 1, cnt);
    r = len - int'(~cnt & 16'hFFFF);
endtask

int r;
initial begin
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (20) @(posedge clk);

    scdoit(8'h00, 0, 0, 0, 0, 0, 0, 'h1000, r);
    check(r == 0 && !saw_odd, $sformatf("TEST UNIT READY: residue 0, Odd Length clear (r=%0d odd=%b)", r, saw_odd));

    // The Emulex test: eleven bytes of sense, in word mode.
    scdoit(8'h03, 0, 0, 0, 11, 0, 11, 'h2000, r);
    check(saw_odd, "REQUEST SENSE of 11 in word mode: Odd Length set");
    check(r == 11, $sformatf("... and with the last byte taken from the data register, all 11 counted (r=%0d)", r));
    check(mem.exists('h2000) && mem['h2000] == 8'h70 && mem.exists('h200A),
          "... the sense is in memory, the eleventh byte included");

    // What tpboot does next, with nothing to move.
    scdoit(8'h00, 0, 0, 0, 0, 0, 0, 'h1000, r);
    check(!saw_odd, "the next command finds Odd Length clear -- selecting with word mode off reset it");
    check(r == 0, $sformatf("... so a command that moves nothing has residue 0, not -1 (r=%0d)", r));
    scdoit(8'h01, 0, 0, 0, 0, 0, 0, 'h1000, r);
    check(r == 0 && !saw_odd, $sformatf("REZERO after it: residue 0 (r=%0d)", r));

    // An even read is untouched by any of this.
    scdoit(8'h08, 0, 0, 8'd5, 8'd1, 0, 512, 'h4000, r);
    check(r == 512 && !saw_odd, $sformatf("READ of one block: 512, Odd Length clear (r=%0d)", r));
    check(mem['h4000] == 8'd5 && mem['h41FF] == 8'(5 + 511), "... and it is block 5");

    $display("tb_scsi_odd: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #200_000_000;
    $display("FAIL: tb_scsi_odd timed out");
    $finish;
end

endmodule
