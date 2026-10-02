//============================================================================
//  tb_mt02 -- rtl/sun2-common/sun2_mt02.sv on Wish5380's SCSI fabric, driven
//  by an initiator that does what the Sun-2 SCSI board does (selection by the
//  target's ID bit alone, no ATN, six-byte commands), with a block back end
//  that behaves like sun2_mister_block: a start while it is busy is ignored,
//  and every block takes a while.
//
//  The tapes are built by tools/mktape (mk_mt02_tapes.py) and every block
//  names its own volume, file and block, so a block from the wrong place
//  cannot pass.  Checked:
//
//    the drivers' identification: sixteen bytes of sense for the PROM, with
//    bit 0 of byte 4 set; eleven for the kernel when it asks for eleven; the
//    Emulex error code in byte 8 for no cartridge, file mark, end of media,
//    write protect and an illegal request;
//    READ: a whole file, a read that meets the file mark (the blocks before
//    it, then CHECK with the residue, then positioned after the mark), a
//    zero-length file, a 64-block read across a 70-block file as the PROM
//    reads, blank tape past the last file, a medium error;
//    SPACE: file marks forward, blocks forward within a file and across a
//    mark, past the end, backwards refused;
//    REWIND, LOAD, MODE SENSE/SELECT, INQUIRY, READ BLOCK LIMITS, a ten-byte
//    command taken whole and refused, a LUN that is not there;
//    changing volume, a volume the image does not have, an image with no
//    header taken as one file, unmounting;
//    a bus reset in the middle of a READ, with the block it had asked for
//    still in flight, and the drive still answering afterwards.
//
//      make -C tb/verilator tb_mt02
//============================================================================
`timescale 1ns/1ps

module tb_mt02;

reg clk = 0;
always #25 clk = ~clk;                      // 20 MHz, the machine's clock
reg rst = 1;

// ---- the bus ---------------------------------------------------------------
scsi_t ini, targ, bus;
scsi_fabric fabric (.a_i(ini), .b_i(targ), .c_i('0), .d_i('0), .bus_o(bus));

blk_req_t blk_o;
blk_rsp_t blk_i;
reg       media_changed = 0;
reg [1:0] volume = 0;

sun2_mt02 #(.CLK_PERIOD_PS(50000), .TARGET_ID(4)) dut (
    .clk_i(clk), .rst_i(rst), .drive_o(targ), .bus_i(bus),
    .blk_o(blk_o), .blk_i(blk_i),
    .media_changed_i(media_changed), .volume_i(volume));

// ---- the media -------------------------------------------------------------
bit [7:0] img [];
reg        ready = 0;
reg [31:0] count = 0;
reg [31:0] err_lba = 32'hFFFFFFFF;
integer    fetches = 0;

task automatic load_image(input string path);
    integer fd, c, n;
    fd = $fopen(path, "rb");
    if (fd == 0) begin $display("FAIL: cannot open %s", path); $finish; end
    img = new [0];
    n = 0;
    c = $fgetc(fd);
    while (c >= 0) begin
        img = new [n + 1] (img);
        img[n] = 8'(c);
        n++;
        c = $fgetc(fd);
    end
    $fclose(fd);
    count = n / 512;
endtask

task automatic mount(input string path, input bit present);
    if (present) load_image(path);
    @(posedge clk);
    ready <= present;
    if (!present) count <= 0;
    media_changed <= 1;
    @(posedge clk);
    media_changed <= 0;
    repeat (2000) @(posedge clk);           // the table is read while the bus is free
endtask

// One process drives everything the back end says.  It looks for a start only
// between blocks, so a start while it is busy is lost -- which is what
// sun2_mister_block does too.
reg       b_done = 0, b_err = 0, b_we = 0;
reg [8:0] b_addr = 0;
reg [7:0] b_wdata = 0;
integer   latency = 150;                   // clocks before a block starts to arrive

always_comb begin
    blk_i           = '0;
    blk_i.done      = b_done;
    blk_i.err       = b_err;
    blk_i.ready     = ready;
    blk_i.count     = count;
    blk_i.buf_we    = b_we;
    blk_i.buf_addr  = b_addr;
    blk_i.buf_wdata = b_wdata;
end

initial begin : backend
    reg [31:0] lba;
    forever begin
        @(posedge clk);
        b_done <= 1'b0;
        if (blk_o.start) begin
            lba = blk_o.lba;
            fetches++;
            repeat (latency) @(posedge clk);
            if (!ready || lba >= count || lba == err_lba)
                b_err <= 1'b1;
            else begin
                b_err <= 1'b0;
                for (int i = 0; i < 512; i++) begin
                    b_we    <= 1'b1;
                    b_addr  <= 9'(i);
                    b_wdata <= img[lba * 512 + i];
                    @(posedge clk);
                end
                b_we <= 1'b0;
            end
            b_done <= 1'b1;
        end
    end
end

// ---- checks ----------------------------------------------------------------
integer passes = 0, fails = 0;
task automatic check(input bit ok, input string what);
    if (ok) passes++;
    else begin fails++; $display("FAIL: %s", what); end
endtask

function automatic bit block_is(input bit [7:0] d[$], input int off, input int v, input int f, input int b);
    string tag;
    tag = $sformatf("V%0dF%02dB%04d", v, f, b);
    if (d.size() < off + 512) return 0;
    for (int i = 0; i < tag.len(); i++)
        if (d[off + i] != tag[i]) return 0;
    for (int i = tag.len(); i < 512; i++)
        if (d[off + i] != 8'((v * 31 + f * 7 + b + i - tag.len()) & 8'hFF)) return 0;
    return 1;
endfunction

// ---- the initiator ---------------------------------------------------------
initial ini = '0;

bit [7:0] din [$];
bit [7:0] st_byte, msg_byte;
bit       timed_out;

// One command, start to bus free.  `abort_after' >= 0 resets the bus once that
// many DATA IN bytes have arrived.
task automatic cmd(input bit [7:0] c0, c1, c2, c3, c4, c5,
                   input int ncdb = 6, input int nout = 0, input int abort_after = -1);
    bit [7:0] c [0:11];
    int k, n, guard;
    c = '{c0, c1, c2, c3, c4, c5, 0, 0, 0, 0, 0, 0};
    din.delete();
    st_byte = 8'hFF; msg_byte = 8'hFF; timed_out = 0;
    k = 0; n = 0;

    // Selection: the target's bit alone, as the Sun-2 board does it.
    @(posedge clk);
    ini.data <= 8'h10;
    ini.sel  <= 1'b1;
    guard = 0;
    while (!bus.bsy) begin @(posedge clk); guard = guard + 1; if (guard > 200000) begin timed_out = 1; break; end end
    ini.sel  <= 1'b0;
    ini.data <= 8'h00;
    if (timed_out) begin check(0, "selection answered"); return; end

    forever begin
        guard = 0;
        @(posedge clk);
        while (bus.bsy && !bus.req) begin
            @(posedge clk);
            guard = guard + 1;
            if (guard > 400000) begin timed_out = 1; break; end
        end
        if (timed_out) begin check(0, $sformatf("command %02x finishes", c0)); break; end
        if (!bus.bsy) break;
        if (bus.io) begin
            case ({bus.msg, bus.cd})
                2'b00: din.push_back(bus.data);
                2'b01: st_byte  = bus.data;
                2'b11: msg_byte = bus.data;
                default: ;
            endcase
            ini.ack <= 1'b1;
        end else begin
            ini.data <= bus.cd ? c[k] : 8'h00;
            if (bus.cd) k = k + 1;
            if (!bus.cd) n++;
            ini.ack  <= 1'b1;
        end
        @(posedge clk);
        while (bus.req) @(posedge clk);
        ini.ack  <= 1'b0;
        ini.data <= 8'h00;
        if (abort_after >= 0 && din.size() == abort_after) begin
            // Long enough for the drive to have asked for the next block.
            repeat (8) @(posedge clk);
            ini.rst <= 1'b1;
            repeat (20) @(posedge clk);
            ini.rst <= 1'b0;
            repeat (5) @(posedge clk);
            break;
        end
    end
    if (ncdb != k && abort_after < 0)
        check(0, $sformatf("command %02x: target took %0d CDB bytes, not %0d", c0, k, ncdb));
    if (nout != n && abort_after < 0)
        check(0, $sformatf("command %02x: target took %0d DATA OUT bytes, not %0d", c0, n, nout));
    repeat (3) @(posedge clk);
endtask

bit [7:0] sense [$];
task automatic get_sense(input int alloc = 16);
    cmd(8'h03, 0, 0, 0, 8'(alloc), 0);
    sense = din;
endtask

function automatic bit [31:0] info_of(input bit [7:0] s[$]);
    // The residue, without the bit the PROM wants in byte 4.
    return {s[3], s[4] & 8'hFE, s[5], s[6]};
endfunction

// READ n blocks; returns how many whole blocks arrived.
task automatic read_blocks(input int n);
    cmd(8'h08, 8'h01, 8'(n >> 16), 8'(n >> 8), 8'(n), 0);
endtask

// ---- the test --------------------------------------------------------------
string dir;
initial begin
    if (!$value$plusargs("dir=%s", dir)) dir = ".";
    repeat (10) @(posedge clk);
    rst = 0;
    repeat (50) @(posedge clk);

    // ---- no cartridge ------------------------------------------------------
    cmd(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02, "TEST UNIT READY with no tape: CHECK CONDITION");
    check(msg_byte == 8'h00, "... and COMMAND COMPLETE");
    get_sense(16);
    check(sense.size() == 16, "PROM's sense: exactly sixteen bytes");
    check(sense.size() == 16 && sense[0] == 8'h70 && sense[2][3:0] == 4'h2 && sense[8] == 8'h09,
          "no tape: NOT READY, Emulex 0x09 (no cartridge)");
    check(sense.size() == 16 && sense[4][0], "sense byte 4 bit 0 set (the PROM's file mark bit)");
    cmd(8'h08, 8'h01, 0, 0, 1, 0);
    check(st_byte == 8'h02 && din.size() == 0, "READ with no tape: CHECK, nothing moved");

    // ---- a two-volume tape -------------------------------------------------
    mount({dir, "/two.qic"}, 1);
    cmd(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "TEST UNIT READY with a tape: GOOD");
    get_sense(11);
    check(sense.size() == 11, "kernel's sense: eleven bytes when it asks for eleven (Emulex, not Sysgen)");
    check(sense.size() == 11 && sense[8] == 8'h00 && sense[7] == 8'd8, "no error: Emulex 0x00, eight more bytes");
    get_sense(0);
    check(sense.size() == 4, "REQUEST SENSE allocation 0 means four bytes");
    get_sense(32);
    check(sense.size() == 16, "asked for more, sense is still sixteen bytes");

    // SunOS 4.0's st driver knows an MT-02 by an empty vendor field.
    cmd(8'h12, 0, 0, 0, 36, 0);
    check(st_byte == 8'h00 && din.size() == 5 && din[0] == 8'h01 && din[1] == 0 && din[4] == 0,
          "INQUIRY: five bytes, a sequential device and zeroes -- what SunOS 4.0 takes for an Emulex");
    cmd(8'h12, 8'h20, 0, 0, 36, 0);
    check(din.size() == 5 && din[0] == 8'h7f, "INQUIRY of LUN 1: nothing there");
    cmd(8'h1a, 0, 0, 0, 12, 0);
    check(st_byte == 8'h00 && din.size() == 12 && din[2][7] && din[3] == 8 && din[4] == 8'h05 && din[10] == 8'h02,
          "MODE SENSE: write protected, QIC-24, 512-byte blocks");
    cmd(8'h15, 0, 0, 0, 13, 0, 6, 13);
    check(st_byte == 8'h00, "MODE SELECT with the kernel's 13-byte list: taken");
    cmd(8'h05, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00 && din.size() == 6 && din[2] == 8'h02 && din[4] == 8'h02, "READ BLOCK LIMITS: 512 and 512");
    cmd(8'h0d, 0, 8'h27, 0, 0, 0);
    check(st_byte == 8'h00, "QIC02: taken");

    // File 0, three blocks, read as the PROM reads: 64 at a time.
    read_blocks(64);
    check(din.size() == 3 * 512, $sformatf("READ 64 of a 3-block file moves 3 blocks (got %0d bytes)", din.size()));
    check(block_is(din, 0, 1, 0, 0) && block_is(din, 512, 1, 0, 1) && block_is(din, 1024, 1, 0, 2),
          "... and they are file 0's blocks 0, 1, 2");
    check(st_byte == 8'h02, "... ending CHECK CONDITION");
    get_sense(16);
    check(sense[2] == 8'h80 && sense[8] == 8'h1c, "sense: Filemark, NO SENSE, Emulex 0x1C");
    check(sense[0] == 8'hF0 && info_of(sense) == 32'd61, "... valid, residue 61 blocks");
    read_blocks(1);
    check(st_byte == 8'h00 && din.size() == 512 && block_is(din, 0, 1, 1, 0), "the next READ is file 1, past the mark");
    read_blocks(1);
    check(st_byte == 8'h02 && din.size() == 0, "file 1 is one block: the next READ meets its mark, moving nothing");
    get_sense(16);
    check(sense[8] == 8'h1c && info_of(sense) == 1, "... file mark, residue 1");
    read_blocks(64);
    check(st_byte == 8'h00 && din.size() == 64 * 512 && block_is(din, 0, 1, 2, 0) && block_is(din, 63 * 512, 1, 2, 63),
          "READ 64 of the 70-block file: all 64, GOOD");
    read_blocks(64);
    check(st_byte == 8'h02 && din.size() == 6 * 512 && block_is(din, 5 * 512, 1, 2, 69), "READ 64 more: the last 6, then CHECK");
    cmd(8'h11, 8'h01, 0, 0, 1, 0);
    check(st_byte == 8'h00, "SPACE 1 file mark: past file 3, the last");
    read_blocks(1);
    check(st_byte == 8'h02 && din.size() == 0, "READ past the last file: CHECK, nothing moved");
    get_sense(16);
    check(sense[2] == 8'h40 && sense[8] == 8'h34 && info_of(sense) == 1, "... End of Medium, Emulex 0x34, residue 1");
    cmd(8'h11, 8'h01, 0, 0, 1, 0);
    check(st_byte == 8'h02, "SPACE a file mark past the end: CHECK");
    get_sense(16);
    check(sense[8] == 8'h34 && info_of(sense) == 1, "... Emulex 0x34, residue 1");

    cmd(8'h01, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00, "REWIND");
    read_blocks(1);
    check(block_is(din, 0, 1, 0, 0), "after REWIND: file 0 block 0");
    cmd(8'h11, 8'h00, 0, 0, 1, 0);
    read_blocks(1);
    check(st_byte == 8'h00 && block_is(din, 0, 1, 0, 2), "SPACE 1 block, then READ: block 2");
    cmd(8'h11, 8'h00, 0, 0, 5, 0);
    check(st_byte == 8'h02, "SPACE 5 blocks at the end of file 0: stops at the mark, CHECK");
    get_sense(16);
    check(sense[2] == 8'h80 && sense[8] == 8'h1c && info_of(sense) == 5, "... Filemark, residue 5");
    read_blocks(1);
    check(block_is(din, 0, 1, 1, 0), "... and the tape is past the mark: file 1");
    cmd(8'h11, 8'h01, 0, 0, 2, 0);
    read_blocks(2);
    check(st_byte == 8'h00 && block_is(din, 0, 1, 3, 0) && block_is(din, 512, 1, 3, 1),
          "SPACE 2 file marks from inside file 1: file 3");
    cmd(8'h11, 8'h01, 8'hFF, 8'hFF, 8'hFF, 0);
    check(st_byte == 8'h02, "SPACE backwards: refused");
    get_sense(16);
    check(sense[2][3:0] == 4'h5 && sense[8] == 8'h20, "... ILLEGAL REQUEST, Emulex 0x20");
    cmd(8'h1b, 0, 0, 0, 8'h03, 0);
    read_blocks(1);
    check(st_byte == 8'h00 && block_is(din, 0, 1, 0, 0), "LOAD with retension: back at the start");
    cmd(8'h11, 8'h00, 0, 0, 2, 0);
    check(st_byte == 8'h00, "SPACE exactly to the end of a file: GOOD, the mark not crossed");
    read_blocks(1);
    check(st_byte == 8'h02 && din.size() == 0, "... so the next READ meets the mark");
    read_blocks(1);
    check(st_byte == 8'h00 && block_is(din, 0, 1, 1, 0), "... and the one after is file 1");
    cmd(8'h01, 0, 0, 0, 0, 0);

    cmd(8'h0a, 8'h01, 0, 0, 1, 0);
    check(st_byte == 8'h02, "WRITE: CHECK");
    get_sense(16);
    check(sense[2][3:0] == 4'h7 && sense[8] == 8'h17, "... DATA PROTECT, Emulex 0x17 (write protected)");
    cmd(8'h10, 0, 0, 0, 1, 0);
    get_sense(16);
    check(sense[8] == 8'h17, "WRITE FILEMARK: write protected");
    cmd(8'h1d, 0, 0, 0, 0, 0);
    get_sense(16);
    check(sense[2][3:0] == 4'h5 && sense[8] == 8'h20, "an unknown command: ILLEGAL REQUEST");
    cmd(8'h00, 8'h20, 0, 0, 0, 0);
    check(st_byte == 8'h02, "TEST UNIT READY of LUN 1: CHECK");
    cmd(8'h28, 0, 0, 0, 0, 0, 10);
    check(st_byte == 8'h02, "READ(10): all ten bytes taken, then refused");

    // A medium error part way through.
    cmd(8'h01, 0, 0, 0, 0, 0);
    err_lba = 32'd2;                          // file 0, block 1
    read_blocks(3);
    check(st_byte == 8'h02 && din.size() == 512 && block_is(din, 0, 1, 0, 0), "a bad block: the good one before it, then CHECK");
    get_sense(16);
    check(sense[2][3:0] == 4'h3 && sense[8] == 8'h11 && info_of(sense) == 2, "... MEDIUM ERROR, Emulex 0x11, residue 2");
    err_lba = 32'hFFFFFFFF;

    // A bus reset with a block in flight: block 1 is being fetched when the
    // bus resets, and is still arriving when the next READ -- for block 2 --
    // begins.  The drive must wait it out rather than take it for its own.
    cmd(8'h01, 0, 0, 0, 0, 0);
    latency = 4000;
    cmd(8'h08, 8'h01, 0, 0, 3, 0, 6, 0, 512);
    cmd(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h00 && !timed_out, "after a bus reset mid-READ: the drive answers");
    cmd(8'h11, 8'h00, 0, 0, 1, 0);
    read_blocks(1);
    check(st_byte == 8'h00 && !timed_out && block_is(din, 0, 1, 0, 2),
          "... and READ gets its own block, not the one the reset abandoned");
    latency = 150;

    // ---- the other volume -----------------------------------------------------
    volume = 2'd1;
    repeat (2000) @(posedge clk);
    read_blocks(64);
    check(din.size() == 2 * 512 && block_is(din, 0, 2, 0, 0) && block_is(din, 512, 2, 0, 1),
          "volume 2: its own file 0");
    read_blocks(64);
    check(st_byte == 8'h02 && din.size() == 0, "a zero-length file is just a file mark");
    read_blocks(64);
    check(din.size() == 5 * 512 && block_is(din, 4 * 512, 2, 2, 4), "volume 2, file 2");
    volume = 2'd2;
    repeat (2000) @(posedge clk);
    cmd(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02, "volume 3 of a two-volume tape: not ready");
    volume = 2'd0;
    repeat (2000) @(posedge clk);
    read_blocks(1);
    check(st_byte == 8'h00 && block_is(din, 0, 1, 0, 0), "back to volume 1: rewound");

    // ---- an image with no header -------------------------------------------------
    mount({dir, "/raw.qic"}, 1);
    read_blocks(64);
    check(st_byte == 8'h02 && din.size() == 9 * 512 && block_is(din, 0, 1, 0, 0) && block_is(din, 8 * 512, 1, 0, 8),
          "no header: the whole image is one file");
    mount("", 0);
    cmd(8'h00, 0, 0, 0, 0, 0);
    check(st_byte == 8'h02, "unmounted: not ready");

    $display("tb_mt02: %0d checks, %0d failed, %0d block fetches", passes + fails, fails, fetches);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #2_000_000_000;
    $display("FAIL: tb_mt02 timed out");
    $finish;
end

endmodule
