//============================================================================
//  tb_mister_block -- rtl/sun2_mister_block.sv between a model of the SCSI
//  target's sector buffer (20 MHz) and a model of hps_io's virtual-disk port
//  (100 MHz), sequenced as sys/hps_io.sv does it:
//
//    the request is seen; some time later sd_ack rises with sd_buff_addr = 0;
//    a read delivers each byte as sd_buff_dout and a one-clock sd_buff_wr,
//    stepping the address two clocks later; a write takes sd_buff_din and
//    steps the address; strobes are several clocks apart; sd_ack falls at the
//    end of the command.
//
//  Checked: bytes round-trip through the image and land in the image where
//  they should; a read overwrites all 512 bytes of the target's buffer; an
//  out-of-range or unmounted block is an error without touching hps_io; the
//  request is down before the transfer ends (left up, the HPS would repeat
//  it); remounting changes the size the target sees.
//
//      make -C tb/verilator tb_mister_block
//============================================================================
`timescale 1ps/1ps

module tb_mister_block;

reg clk = 0, clk_hps = 0;
always #25000 clk     = ~clk;               // 20 MHz
always #5000  clk_hps = ~clk_hps;           // 100 MHz

// ---- DUT ------------------------------------------------------------------
reg         blk_start = 0, blk_we = 0;
reg  [31:0] blk_lba = 0;
wire [7:0]  blk_buf_rdata;
wire        blk_done, blk_err, blk_ready, blk_buf_we, busy;
wire [31:0] blk_count;
wire [8:0]  blk_buf_addr;
wire [7:0]  blk_buf_wdata;

wire [31:0] sd_lba;
wire        sd_rd, sd_wr;
reg         sd_ack = 0;
reg  [8:0]  sd_buff_addr = 0;
reg  [7:0]  sd_buff_dout = 0;
wire [7:0]  sd_buff_din;
reg         sd_buff_wr = 0;
reg         img_mounted = 0;
reg  [63:0] img_size = 0;

sun2_mister_block dut (
    .clk(clk), .blk_start(blk_start), .blk_we(blk_we), .blk_lba(blk_lba),
    .blk_buf_rdata(blk_buf_rdata), .blk_done(blk_done), .blk_err(blk_err),
    .blk_ready(blk_ready), .blk_count(blk_count), .blk_buf_we(blk_buf_we),
    .blk_buf_addr(blk_buf_addr), .blk_buf_wdata(blk_buf_wdata), .busy(busy),
    .clk_hps(clk_hps), .sd_lba(sd_lba), .sd_rd(sd_rd), .sd_wr(sd_wr), .sd_ack(sd_ack),
    .sd_buff_addr(sd_buff_addr), .sd_buff_dout(sd_buff_dout), .sd_buff_din(sd_buff_din),
    .sd_buff_wr(sd_buff_wr), .img_mounted(img_mounted), .img_size(img_size)
);

integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) passes = passes + 1;
        else begin fails = fails + 1; $display("FAIL  %s", what); end
    end
endtask

// ---- the target's sector buffer: registered read, one clock behind ----------
reg [7:0] tbuf [0:511];
reg [7:0] tbuf_q = 0;
always @(posedge clk) begin
    if (blk_buf_we) tbuf[blk_buf_addr] <= blk_buf_wdata;
    tbuf_q <= tbuf[blk_buf_addr];
end
assign blk_buf_rdata = tbuf_q;

// ---- hps_io and the image -------------------------------------------------------
bit [7:0] disk [int];                       // byte index lba*512 + i
integer   hps_reads = 0, hps_writes = 0;
integer   req_left_up = 0;
int unsigned hseed = 32'h0BADF00D;
function automatic int hrnd(input int lo, input int hi);
    hseed = hseed * 32'd1664525 + 32'd1013904223;
    hrnd = lo + int'(hseed % (hi - lo + 1));
endfunction

initial begin : hps
    forever begin
        @(posedge clk_hps);
        if (sd_rd || sd_wr) begin
            bit rd;
            int lba;
            rd  = sd_rd;
            lba = int'(sd_lba);
            repeat (hrnd(20, 300)) @(posedge clk_hps);     // the HPS notices
            sd_ack <= 1;
            sd_buff_addr <= 0;
            for (int i = 0; i < 512; i++) begin
                repeat (hrnd(4, 9)) @(posedge clk_hps);    // the next bus strobe
                if (rd) begin
                    sd_buff_dout <= disk.exists(lba*512 + i) ? disk[lba*512 + i] : 8'h00;
                    @(posedge clk_hps); sd_buff_wr <= 1;
                    @(posedge clk_hps); sd_buff_wr <= 0;
                    @(posedge clk_hps); if (i != 511) sd_buff_addr <= sd_buff_addr + 1;
                end else begin
                    disk[lba*512 + i] = sd_buff_din;
                    if (i != 511) sd_buff_addr <= sd_buff_addr + 1;
                end
            end
            repeat (3) @(posedge clk_hps);
            if (sd_rd || sd_wr) req_left_up = req_left_up + 1;
            sd_ack <= 0;
            if (rd) hps_reads = hps_reads + 1; else hps_writes = hps_writes + 1;
        end
    end
end

task automatic mount(input int blocks);
    begin
        @(posedge clk_hps);
        img_size    <= 64'(blocks) * 512;
        img_mounted <= 1;
        @(posedge clk_hps);
        img_mounted <= 0;
        repeat (20) @(posedge clk);
    end
endtask

// One transfer from the target's side; returns err.
task automatic xfer(input bit w, input int lba, output bit err);
    begin
        @(negedge clk);
        blk_we = w; blk_lba = 32'(lba); blk_start = 1;
        @(negedge clk);
        blk_start = 0;
        while (!blk_done) @(negedge clk);
        err = blk_err;
        @(negedge clk);
    end
endtask

task automatic fill_tbuf(input int seed);
    for (int i = 0; i < 512; i++) tbuf[i] = 8'((seed * 37 + i * 11 + (i >> 3)) ^ (i * 7));
endtask

bit [7:0] expect_buf [0:511];
bit err;

initial begin
    $display("tb_mister_block: sun2_mister_block between a target model and an hps_io model");
    repeat (10) @(posedge clk);

    check(!blk_ready, "no image: not ready");
    xfer(0, 0, err);
    check(err, "no image: a read is an error");
    check(hps_reads == 0, "no image: hps_io was not asked");

    mount(64);
    check(blk_ready && blk_count == 64, $sformatf("mounted: ready=%0d count=%0d", blk_ready, blk_count));

    // write blocks 5 and 63, read them back over a dirtied buffer
    fill_tbuf(5);
    for (int i = 0; i < 512; i++) expect_buf[i] = tbuf[i];
    xfer(1, 5, err);
    check(!err, "write block 5");
    for (int i = 0; i < 512; i++)
        if (disk[5*512 + i] != expect_buf[i]) begin
            check(0, $sformatf("image byte %0d of block 5 is %02x, expected %02x", i, disk[5*512+i], expect_buf[i]));
            break;
        end
    check(disk.exists(5*512) && disk.exists(5*512 + 511), "block 5 landed at bytes 2560..3071 of the image");

    fill_tbuf(63);
    xfer(1, 63, err);
    check(!err, "write the last block, 63");

    for (int i = 0; i < 512; i++) tbuf[i] = 8'hEE;
    xfer(0, 5, err);
    check(!err, "read block 5");
    begin
        int bad = 0;
        for (int i = 0; i < 512; i++) if (tbuf[i] != expect_buf[i]) bad++;
        check(bad == 0, $sformatf("block 5 read back: %0d of 512 bytes wrong", bad));
    end

    xfer(0, 64, err);
    check(err, "block 64 of 64 is out of range");
    begin
        int r0;
        r0 = hps_reads;
        xfer(0, 1000, err);
        check(err && hps_reads == r0, "out of range never reaches hps_io");
    end

    // a run of mixed transfers against a model of the image
    for (int k = 0; k < 40; k++) begin
        int lba;
        lba = (k * 13) % 64;
        if (k % 3 != 2) begin
            fill_tbuf(1000 + k);
            xfer(1, lba, err);
            check(!err, $sformatf("write %0d", lba));
        end else begin
            for (int i = 0; i < 512; i++) tbuf[i] = ~tbuf[i];
            xfer(0, lba, err);
            check(!err, $sformatf("read %0d", lba));
            begin
                int bad = 0;
                for (int i = 0; i < 512; i++)
                    if (tbuf[i] != (disk.exists(lba*512+i) ? disk[lba*512+i] : 8'h00)) bad++;
                check(bad == 0, $sformatf("read %0d: %0d bytes differ from the image", lba, bad));
            end
        end
    end

    check(req_left_up == 0, $sformatf("sd_rd/sd_wr still up at the end of %0d transfers", req_left_up));

    mount(128);
    check(blk_ready && blk_count == 128, "remounted larger: count follows");
    mount(0);
    check(!blk_ready, "unmounted: not ready");

    $display("");
    $display("tb_mister_block: %0d checks, %0d failed (%0d hps reads, %0d writes)",
             passes + fails, fails, hps_reads, hps_writes);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #(64'd2_000_000_000_000);
    $display("FAIL  timeout");
    $finish;
end

endmodule
