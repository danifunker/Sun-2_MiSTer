//============================================================================
//  tb_mister_enet -- rtl/sun2_mister_enet.sv between the 82586's own MII
//  blocks and a DDR3 mailbox, with the daemon's half of the protocol played
//  by the bench.
//
//  The transmitter is wish82586's mii_tx and the receiver its mii_rx -- the
//  very blocks behind the Sun's 82586 -- so the frames on the MII are the
//  ones the chip makes and the ones it accepts, FCS included.  The MII runs at
//  2.5 MHz and the mailbox side at 100 MHz, unrelated, as in the core.  The
//  DDR3 port is an Avalon slave that holds BUSY at random and answers reads
//  late.
//
//  Checked: the mailbox is published (magic last, the MAC beside it); a frame
//  transmitted lands in the TX ring without preamble or FCS, its length in
//  its header, and the pointer moves; short frames arrive padded as the chip
//  pads them; more frames than the ring holds, back to back, and the chip
//  never gives up on the medium (CRS is the flow control); a frame delivered
//  to the RX ring reaches the chip whole with a good FCS, a short one padded
//  to 60, four at once in order with a gap after each, twelve full-size ones
//  queued together (the sixteen-slot ring); nonsense lengths are
//  taken and dropped; the cable out (LOOPB-) keeps the line quiet and moves
//  nothing either way; Network Off withdraws the magic and still lets the
//  chip finish a transmit; on again republishes; a changed MAC is
//  republished; transmit and receive at once; the magic is only ever set
//  once the rest of its generation has been written.
//
//      make -C tb/verilator tb_mister_enet
//============================================================================
`timescale 1ns/1ps

module tb_mister_enet;

reg clk = 0;
always #5 clk = ~clk;                           // 100 MHz, the mailbox side and DDR3
reg mii_clk = 0;
always #200.3 mii_clk = ~mii_clk;               // 2.5 MHz, near enough, and unrelated
reg rst = 1;

reg        enable = 0;
reg        loopback_n = 1;
reg [47:0] mac = 48'h08_00_20_01_06_E0;

wire [3:0] txd, rxd;
wire       tx_en, rx_dv, crs;

wire        ddr_busy;
wire [7:0]  ddr_burst, ddr_be;
wire [28:0] ddr_addr;
reg  [63:0] ddr_dout = 0;
reg         ddr_dout_ready = 0;
wire        ddr_rd, ddr_we;
wire [63:0] ddr_din;

sun2_mister_enet dut (
    .clk(clk), .rst(rst), .mii_clk(mii_clk), .mii_rst(rst),
    .enable(enable), .loopback_n(loopback_n), .mac(mac),
    .mii_txd(txd), .mii_tx_en(tx_en), .mii_rxd(rxd), .mii_rx_dv(rx_dv), .mii_crs(crs),
    .DDRAM_BUSY(ddr_busy), .DDRAM_BURSTCNT(ddr_burst), .DDRAM_ADDR(ddr_addr),
    .DDRAM_DOUT(ddr_dout), .DDRAM_DOUT_READY(ddr_dout_ready), .DDRAM_RD(ddr_rd),
    .DDRAM_DIN(ddr_din), .DDRAM_BE(ddr_be), .DDRAM_WE(ddr_we));

integer passes = 0, fails = 0;
task check(input bit ok, input string what);
    begin
        if (ok) begin passes++; $display("  ok  %s", what); end
        else begin fails++; $display("FAIL  %s", what); end
    end
endtask

// ---- DDR3: the 64 KiB window, BUSY at random, reads answered late ------------
localparam [28:0] BASE = 29'h03FE0000;
reg  [63:0] mem [0:8191];
reg  [15:0] lfsr = 16'h1234;
always @(posedge clk) lfsr <= {lfsr[14:0], lfsr[15] ^ lfsr[13] ^ lfsr[12] ^ lfsr[10]};
assign ddr_busy = lfsr[1] & lfsr[4];            // a quarter of the time
int   bad_addr = 0, bad_burst = 0;
int   rd_q [$];                                 // word addresses of reads in flight
int   rd_wait = 0;
always @(posedge clk) begin
    ddr_dout_ready <= 0;
    if ((ddr_rd || ddr_we) && !ddr_busy) begin
        if (ddr_addr < BASE || ddr_addr >= BASE + 8192) bad_addr++;
        else if (ddr_we) mem[ddr_addr - BASE] <= ddr_din;
        else rd_q.push_back(ddr_addr - BASE);
        if (ddr_burst != 1 || ddr_be != 8'hFF) bad_burst++;
        if (ddr_rd && ddr_we) bad_burst++;
    end
    if (rd_q.size() != 0) begin
        if (rd_wait < 3 + lfsr[2:0] % 4) rd_wait <= rd_wait + 1;
        else begin
            ddr_dout       <= mem[rd_q[0]];
            ddr_dout_ready <= 1;
            rd_q.pop_front();
            rd_wait <= 0;
        end
    end
end

// The order a generation is published in: since the magic was last cleared,
// TX_WPTR, RX_WPTR, RX_RPTR and the MAC must all have been written before the
// magic is set again.
reg [3:0] since_clear = 0;
int       early_magic = 0, publishes = 0;
always @(posedge clk) if (ddr_we && !ddr_busy) begin
    case (ddr_addr - BASE)
        0: if (ddr_din == 0) since_clear <= 0;
           else begin publishes++; if (since_clear != 4'hF) early_magic++; end
        1: since_clear[0] <= 1;
        2: since_clear[1] <= 1;
        3: since_clear[2] <= 1;
        4: since_clear[3] <= 1;
        default: ;
    endcase
end

function automatic [63:0] w(input int off); w = mem[off / 8]; endfunction
task automatic wset(input int off, input [63:0] v); mem[off / 8] = v; endtask
function automatic [7:0] slot_byte(input int slot_off, input int i);
    slot_byte = mem[(slot_off + 8 + i) / 8][((slot_off + 8 + i) % 8) * 8 +: 8];
endfunction

localparam int MAGIC_OFF = 'h0, TXW = 'h8, RXW = 'h10, RXR = 'h18, MACO = 'h20;
localparam int TXS = 'h800, RXS = 'h2800, SLOT = 'h800;
localparam [63:0] MAGIC = 64'h53554E3245544831;

// ---- the 82586's transmitter -------------------------------------------------
reg         go = 0;
reg  [15:0] len = 0;
wire        done, ok, xcoll, defer_o, no_crs;
wire [3:0]  ncoll;
wire [10:0] tram_addr;
reg  [7:0]  tram [0:2047];
reg  [7:0]  tram_q = 0;
always @(posedge mii_clk) tram_q <= tram[tram_addr];
reg  [1:0]  crs_s = 0;
always @(posedge mii_clk) crs_s <= {crs_s[0], crs};   // as sun2_ethernet.sv does

mii_tx #(.DATA_W(4)) tx (
    .tx_clk(mii_clk), .rst(rst),
    .go_i(go), .len_i(len), .done_o(done), .ok_o(ok), .ncoll_o(ncoll), .xcoll_o(xcoll),
    .defer_o(defer_o), .no_crs_o(no_crs),
    .retry_limit_i(4'd15), .ifs_i(8'd96), .slot_time_i(11'd512), .min_len_i(8'd64), .no_crc_i(1'b0),
    .ram_addr_o(tram_addr), .ram_data_i(tram_q),
    .txd(txd), .tx_en(tx_en), .tx_er(), .crs(crs_s[1]), .col(1'b0));

int tx_bad = 0;                                 // transmits the chip gave up on
task automatic send(input byte unsigned f [], input bit wait_done = 1);
    begin
        foreach (f[i]) tram[i] = f[i];
        @(negedge mii_clk); len = f.size(); go = 1;
        if (wait_done) begin
            wait (done);
            if (!ok) tx_bad++;
            @(negedge mii_clk); go = 0;
            wait (!done);
        end
    end
endtask

// ---- the 82586's receiver ----------------------------------------------------
wire        rfifo_wr;
wire [11:0] rfifo_data;
mii_rx #(.DATA_W(4)) rx (
    .rx_clk(mii_clk), .rst(rst), .rxd(rxd), .rx_dv(rx_dv), .rx_er(1'b0),
    .fifo_wr_o(rfifo_wr), .fifo_data_o(rfifo_data), .fifo_full_i(1'b0),
    .active_o(), .byte_count_o());

typedef byte unsigned frame_t [$];
frame_t got [$];                                // frames received, in order
bit     got_err [$];                            // FCS or framing error on each
frame_t cur;
always @(posedge mii_clk) if (rfifo_wr) begin
    if (rfifo_data[11]) begin
        got.push_back(cur);
        got_err.push_back(|rfifo_data[10:8]);
        cur = {};
    end else cur.push_back(rfifo_data[7:0]);
end

// the shortest quiet spell between two received frames, in clocks
int gap = 0, min_gap = 1 << 30, seen_dv = 0;
reg rx_dv_d = 0;
always @(posedge mii_clk) begin
    rx_dv_d <= rx_dv;
    if (rx_dv && !rx_dv_d) begin                // a frame starts
        if (seen_dv && gap < min_gap) min_gap = gap;
        seen_dv = 1;
    end
    gap = rx_dv ? 0 : gap + 1;
end

// CRS while nothing at all is happening, with the cable out: the chip has
// not transmitted for a few clocks (CRS is registered, and follows the chip's
// own transmit enable a clock or two late).
int crs_in_loopback = 0;
reg [3:0] tx_hist = 0;
always @(posedge mii_clk) begin
    tx_hist <= {tx_hist[2:0], tx_en};
    if (!loopback_n && crs && tx_hist == 0 && !tx_en) crs_in_loopback++;
end

// ---- the daemon's half --------------------------------------------------------
// The queues are cleared by hand: Verilator keeps a function's local queue
// from one call to the next when the call sits inside a loop.
function automatic frame_t mkframe(input int n, input int seed);
    frame_t f;
    f = {};
    for (int i = 0; i < n; i++) f.push_back(8'((i * 7 + seed * 31 + (i >> 3)) ^ (seed << 4)));
    // a destination, a source and a type, as a real frame has
    for (int i = 0; i < 6 && i < n; i++) f[i] = 8'hFF;
    return f;
endfunction

function automatic frame_t tx_slot_frame(input int k);
    frame_t f;
    int off = TXS + SLOT * (k % 4);
    int n = int'(w(off) & 64'h7FF);
    f = {};
    for (int i = 0; i < n; i++) f.push_back(slot_byte(off, i));
    return f;
endfunction

task automatic deliver(input frame_t f);
    int k;
    begin
        k = int'(w(RXW));
        wait (int'(w(RXW)) - int'(w(RXR)) < 16);
        for (int i = 0; i < f.size(); i++) begin
            int o = RXS + SLOT * (k % 16) + 8 + i;
            mem[o / 8][(o % 8) * 8 +: 8] = f[i];
        end
        wset(RXS + SLOT * (k % 16), 64'(f.size()));
        wset(RXW, 64'(k + 1));
    end
endtask

function automatic bit same(input frame_t a, input frame_t b);
    if (a.size() != b.size()) return 0;
    foreach (a[i]) if (a[i] != b[i]) return 0;
    return 1;
endfunction

function automatic frame_t padded(input frame_t f);
    frame_t p;
    p = f;
    while (p.size() < 60) p.push_back(8'h00);
    return p;
endfunction

task automatic settle(input int clocks); repeat (clocks) @(posedge mii_clk); endtask   // MII clocks

// debugging: +trace prints what the shim and the engine do
bit trace = 0;
initial trace = $test$plusargs("trace");
reg [1:0] tst_d = 0;
reg [4:0] est_d = 0;
always @(posedge clk) if (trace) begin
    tst_d <= dut.tst;
    est_d <= dut.est;
    if (dut.tst != tst_d) $display("[%0t] tx fsm %0d -> %0d  tn %0d tx_en %b crs %b", $time, tst_d, dut.tst, dut.tn, tx_en, crs);
    if (go && tx.state == 2 && $past(tx.state) != 2) $display("[%0t] mii_tx starts preamble, len %0d", $time, len);
    if (done && !$past(done)) $display("[%0t] mii_tx done ok %b", $time, ok);
end

initial begin
    frame_t f, g;
    for (int i = 0; i < 8192; i++) mem[i] = 64'hDEADBEEF_00000000 | i;
    mem[0] = 64'h1122334455667788;              // a previous core's magic
    $display("tb_mister_enet: sun2_mister_enet between wish82586's MII and a DDR3 mailbox");
    settle(10);
    rst = 0;
    settle(200);
    check(w(MAGIC_OFF) == 64'h1122334455667788, "nothing is written while Network is Off");

    enable = 1;
    settle(400);
    check(w(MAGIC_OFF) == MAGIC, $sformatf("on: the magic is published (%h)", w(MAGIC_OFF)));
    check(w(MACO) == {1'b1, 15'd0, mac}, $sformatf("... with the MAC beside it (%h)", w(MACO)));
    check(w(TXW) == 0 && w(RXW) == 0 && w(RXR) == 0, "... and every pointer at zero");

    // ---- transmit ----
    f = mkframe(100, 1);
    send(f);
    settle(3000);
    check(w(TXW) == 1, $sformatf("a frame transmitted moves TX_WPTR to 1 (%0d)", w(TXW)));
    g = tx_slot_frame(0);
    check(same(g, f), $sformatf("... and slot 0 holds its 100 bytes, no preamble, no FCS (%0d bytes)", g.size()));

    f = mkframe(20, 2);
    send(f);
    settle(3000);
    g = tx_slot_frame(1);
    check(same(g, padded(f)), $sformatf("a 20-byte frame goes out as the chip pads it, 60 bytes (%0d)", g.size()));

    f = mkframe(1514, 3);
    send(f);
    settle(8000);
    g = tx_slot_frame(2);
    check(same(g, f) && w(TXW) == 3, $sformatf("a 1514-byte frame whole (%0d bytes)", g.size()));

    // Six back to back, more than the ring holds: the chip defers on CRS while
    // each is copied out, and never gives up.
    for (int k = 0; k < 6; k++) send(mkframe(200 + 100 * k, 10 + k));
    settle(8000);
    check(w(TXW) == 9, $sformatf("six back to back: TX_WPTR 9 (%0d)", w(TXW)));
    begin
        bit all = 1;
        for (int k = 5; k < 9; k++) if (!same(tx_slot_frame(k), mkframe(200 + 100 * (k - 3), 10 + k - 3))) all = 0;
        check(all, "... the ring holds the last four, each whole");
    end
    check(tx_bad == 0, $sformatf("... and the chip never gave up on the medium (%0d failed)", tx_bad));

    // ---- receive ----
    f = mkframe(64, 20);
    deliver(f);
    wait (got.size() == 1);
    settle(200);
    check(same(got[0], f) && !got_err[0], $sformatf("a 64-byte frame delivered reaches the chip whole, FCS good (%0d bytes, err %0d)",
          got[0].size(), got_err[0]));
    check(w(RXR) == 1, $sformatf("... and RX_RPTR follows (%0d)", w(RXR)));

    f = mkframe(42, 21);                         // an ARP, as a host sends it: no padding
    deliver(f);
    wait (got.size() == 2);
    check(same(got[1], padded(f)) && !got_err[1], $sformatf("a 42-byte frame arrives padded to 60, FCS good (%0d bytes)", got[1].size()));

    f = mkframe(1514, 22);
    deliver(f);
    wait (got.size() == 3);
    check(same(got[2], f) && !got_err[2], "a 1514-byte frame whole, FCS good");

    min_gap = 1 << 30;
    for (int k = 0; k < 4; k++) deliver(mkframe(100 + 300 * k, 30 + k));
    wait (got.size() == 7);
    begin
        bit all = 1;
        for (int k = 0; k < 4; k++) if (!same(got[3 + k], mkframe(100 + 300 * k, 30 + k)) || got_err[3 + k]) all = 0;
        check(all, "four delivered at once arrive whole and in order");
    end
    check(min_gap >= 48, $sformatf("... with at least 48 nibbles between them (%0d)", min_gap));

    // A burst of full-size frames, as a host delivers the fragments of an
    // 8 KiB NFS read and more: all queued at once, all arrive.
    for (int k = 0; k < 12; k++) deliver(mkframe(1514, 100 + k));
    wait (got.size() == 19);
    begin
        bit all = 1;
        for (int k = 0; k < 12; k++) if (!same(got[7 + k], mkframe(1514, 100 + k)) || got_err[7 + k]) all = 0;
        check(all, "twelve full-size frames delivered at once arrive whole and in order");
    end
    got = got[0:6];
    got_err = got_err[0:6];

    // nonsense lengths: taken off the ring, never put on the wire
    wset(RXS + SLOT * (int'(w(RXW)) % 16), 64'd5);    wset(RXW, w(RXW) + 1);
    wset(RXS + SLOT * (int'(w(RXW)) % 16), 64'd2000); wset(RXW, w(RXW) + 1);
    settle(20000);
    check(w(RXR) == w(RXW) && got.size() == 7, $sformatf("lengths 5 and 2000 are taken and dropped (RXR %0d of %0d, %0d frames)",
          w(RXR), w(RXW), got.size()));

    // ---- both at once ----
    fork
        for (int k = 0; k < 3; k++) send(mkframe(300, 40 + k));
        for (int k = 0; k < 3; k++) deliver(mkframe(300, 50 + k));
    join
    wait (got.size() == 10);
    settle(8000);
    begin
        bit all = 1;
        for (int k = 0; k < 3; k++) if (!same(got[7 + k], mkframe(300, 50 + k)) || got_err[7 + k]) all = 0;
        for (int k = 0; k < 3; k++) if (!same(tx_slot_frame(9 + k), mkframe(300, 40 + k))) all = 0;
        check(all && w(TXW) == 12 && tx_bad == 0, $sformatf("three each way at once: all whole (TXW %0d, %0d failed)", w(TXW), tx_bad));
    end

    // ---- the cable out ----
    loopback_n = 0;
    settle(100);
    send(mkframe(100, 60));
    deliver(mkframe(100, 61));
    settle(20000);
    check(w(TXW) == 12, $sformatf("LOOPB-: a transmit goes nowhere (TXW %0d)", w(TXW)));
    check(got.size() == 10 && w(RXR) == w(RXW), $sformatf("... a delivery is taken and dropped (%0d frames, RXR %0d of %0d)",
          got.size(), w(RXR), w(RXW)));
    check(crs_in_loopback == 0, $sformatf("... and CRS stays low while the chip is quiet (%0d clocks high)", crs_in_loopback));
    loopback_n = 1;
    settle(100);

    // ---- Network Off ----
    enable = 0;
    settle(400);
    check(w(MAGIC_OFF) == 0, "Off: the magic is withdrawn");
    send(mkframe(100, 70));
    settle(3000);
    check(w(TXW) == 12 && tx_bad == 0, "... a transmit completes into nothing");

    mac = 48'h08_00_20_AB_CD_EF;
    enable = 1;
    settle(400);
    check(w(MAGIC_OFF) == MAGIC && w(TXW) == 0 && w(RXR) == 0 && w(RXW) == 0,
          "on again: republished, pointers back to zero");
    check(w(MACO) == {1'b1, 15'd0, mac}, $sformatf("... with the MAC as it is now (%h)", w(MACO)));
    mac = 48'h08_00_20_12_34_56;
    settle(400);
    check(w(MACO) == {1'b1, 15'd0, mac}, $sformatf("a changed MAC is republished (%h)", w(MACO)));
    f = mkframe(80, 80);
    send(f);
    settle(3000);
    check(same(tx_slot_frame(0), f) && w(TXW) == 1, "and frames flow again from slot 0");

    // Full-size frames back to back take longer to copy out than the
    // interframe gap: only CRS held over the copy keeps the next one off the
    // wire until the buffer is free.
    for (int k = 0; k < 3; k++) send(mkframe(1514, 90 + k));
    settle(8000);
    begin
        bit all = 1;
        for (int k = 0; k < 3; k++) if (!same(tx_slot_frame(1 + k), mkframe(1514, 90 + k))) all = 0;
        check(all && w(TXW) == 4 && tx_bad == 0,
              $sformatf("three 1514-byte frames back to back, all whole (TXW %0d, %0d failed)", w(TXW), tx_bad));
    end

    check(publishes == 2 && early_magic == 0,
          $sformatf("the magic is set only after the pointers and the MAC (%0d of %0d too early)", early_magic, publishes));
    check(bad_addr == 0 && bad_burst == 0,
          $sformatf("every DDR3 access was one whole word inside the window (%0d outside, %0d malformed)", bad_addr, bad_burst));

    $display("");
    $display("tb_mister_enet: %0d checks, %0d failed", passes + fails, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

initial begin
    #2_000_000_000;
    $display("timeout");
    $display("FAIL");
    $finish;
end

endmodule
