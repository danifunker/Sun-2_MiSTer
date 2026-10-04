//============================================================================
//  tb_mister_enet -- rtl/sun2_mister_enet.sv between the 82586's own MII
//  blocks and a DDR3 mailbox, with the daemon's half of the protocol played
//  by the bench as Main_MiSTer's support/sun/sun_enet.cpp plays it.
//
//  The transmitter is wish82586's mii_tx and the receiver its mii_rx -- the
//  very blocks behind the Sun's 82586 -- so the frames on the MII are the
//  ones the chip makes and the ones it accepts, FCS included.  The MII runs at
//  2.5 MHz and the mailbox side at 100 MHz, unrelated, as in the core.  The
//  DDR3 port is an Avalon slave that holds BUSY at random and answers reads
//  late.  The daemon takes transmitted frames every 2 us (when it is let to),
//  advancing TX_RPTR; it delivers frames padded to 60 with their FCS and the
//  destination's hash in the header, as Main does.
//
//  Checked: nothing is written while the machine is in reset; leaving it
//  publishes the mailbox (magic last, GEN, every pointer zeroed, the MAC); a
//  frame transmitted reaches the daemon without preamble or FCS, its length
//  in its header; short frames as the chip pads them; more frames than the
//  ring holds, back to back; a frame delivered reaches the chip whole with a
//  good FCS, a short one padded, a VLAN-sized one, four at once in order with
//  a gap after each, twelve full-size ones queued together (the sixteen-slot
//  ring); nonsense lengths are taken and dropped; the cable out (LOOPB-) keeps
//  the line quiet and moves nothing either way; Network Off keeps the mailbox
//  published but sends and delivers nothing; with the daemon stopped, eight
//  frames fill the TX ring, a ninth is held with CRS high and dropped after
//  10 ms while the frame behind it defers and is sent (the chip never gives
//  up), and that one goes into the ring as soon as TX_RPTR moves, while one
//  held there when Network is switched Off goes at once; a machine
//  reset withdraws the magic and leaving it republishes with a new GEN and
//  the MAC as it is then; a changed MAC is republished; transmit and receive
//  at once; the magic is only ever set once the rest of its generation has
//  been written.
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

reg        restart = 1;                         // the machine's reset: until boot0.rom is in
reg        enable = 1;                          // the OSD's Network: eth0, the default
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
    .restart(restart), .enable(enable), .loopback_n(loopback_n), .mac(mac),
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
// GEN, the four pointers and the MAC must all have been written before the
// magic is set again.
reg [5:0] since_clear = 0;
int       early_magic = 0, publishes = 0;
always @(posedge clk) if (ddr_we && !ddr_busy) begin
    case (ddr_addr - BASE)
        0: if (ddr_din == 0) since_clear <= 0;
           else begin publishes++; if (since_clear != 6'h3F) early_magic++; end
        1: since_clear[0] <= 1;
        2: since_clear[1] <= 1;
        3: since_clear[2] <= 1;
        4: since_clear[3] <= 1;
        5: since_clear[4] <= 1;
        6: since_clear[5] <= 1;
        default: ;
    endcase
end

function automatic [63:0] w(input int off); w = mem[off / 8]; endfunction
task automatic wset(input int off, input [63:0] v); mem[off / 8] = v; endtask
function automatic [7:0] slot_byte(input int slot_off, input int i);
    slot_byte = mem[(slot_off + 8 + i) / 8][((slot_off + 8 + i) % 8) * 8 +: 8];
endfunction

localparam int MAGIC_OFF = 'h0, GEN = 'h8, TXW = 'h10, TXR = 'h18, RXW = 'h20, RXR = 'h28, MACO = 'h30;
localparam int TXS = 'h1000, RXS = 'h5000, SLOT = 'h800, TX_RING = 8, RX_RING = 16;
localparam [63:0] MAGIC = 64'h5332455448303031;
localparam time MS = 1_000_000;

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

function automatic frame_t tx_slot_frame(input longint k);
    frame_t f;
    int off = TXS + SLOT * int'(k % TX_RING);
    int n = int'(w(off) & 64'h7FF);
    f = {};
    for (int i = 0; i < n; i++) f.push_back(slot_byte(off, i));
    return f;
endfunction

function automatic [31:0] crc32_le(input frame_t f, input int n);   // as on the wire, not inverted
    reg [31:0] c;
    c = 32'hFFFFFFFF;
    for (int i = 0; i < n; i++) begin
        c = c ^ {24'd0, f[i]};
        for (int k = 0; k < 8; k++) c = (c >> 1) ^ (32'hEDB88320 & {32{c[0]}});
    end
    return c;
endfunction

// Transmit: every 2 us, while let to, take every posted frame and advance
// TX_RPTR, as sun_enet_poll() does.
frame_t sent [$];
bit     daemon = 1;
longint unsigned d_txw, d_txr;                  // unsigned, as Main's: out of step resynchronises
initial forever begin
    repeat (200) @(posedge clk);
    if (daemon && w(MAGIC_OFF) == MAGIC) begin
        d_txw = longint'(w(TXW));
        d_txr = longint'(w(TXR));
        if (d_txw - d_txr > TX_RING) d_txr = d_txw;
        while (d_txr != d_txw) begin
            sent.push_back(tx_slot_frame(d_txr));
            d_txr++;
        end
        wset(TXR, 64'(d_txr));
    end
end

// Receive: padded to 60, the FCS appended, the destination's hash beside the
// length, as Main delivers.  (Main drops a frame the ring has no room for;
// the bench waits, so every check knows what it sent.)
int hashed = 0;                                 // deliveries whose hash bits were not zero
task automatic deliver(input frame_t f);
    frame_t p;
    int k, n;
    reg [31:0] fcs, hash;
    begin
        p = f;
        while (p.size() < 60) p.push_back(8'h00);
        fcs = ~crc32_le(p, p.size());
        for (int i = 0; i < 4; i++) p.push_back(fcs[8 * i +: 8]);
        hash = crc32_le(p, 6) >> 26;
        if (hash != 0) hashed++;
        n = p.size();
        k = int'(w(RXW));
        wait (int'(w(RXW)) - int'(w(RXR)) < RX_RING);
        for (int i = 0; i < n; i++) begin
            int o = RXS + SLOT * (k % RX_RING) + 8 + i;
            mem[o / 8][(o % 8) * 8 +: 8] = p[i];
        end
        wset(RXS + SLOT * (k % RX_RING), 64'(n) | (64'(hash) << 16));
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
reg [2:0] tst_d = 0;
always @(posedge clk) if (trace) begin
    tst_d <= dut.tst;
    if (dut.tst != tst_d) $display("[%0t] tx fsm %0d -> %0d  tn %0d tx_en %b crs %b", $time, tst_d, dut.tst, dut.tn, tx_en, crs);
    if (done && !$past(done)) $display("[%0t] mii_tx done ok %b", $time, ok);
end

initial begin
    frame_t f, g;
    longint txw0;
    reg [63:0] gen1;
    time t_x, t_y;
    for (int i = 0; i < 8192; i++) mem[i] = 64'hDEADBEEF_00000000 | i;
    mem[0] = 64'h1122334455667788;              // a previous core's magic
    $display("tb_mister_enet: sun2_mister_enet between wish82586's MII and a DDR3 mailbox");
    settle(10);
    rst = 0;
    settle(200);
    check(w(MAGIC_OFF) == 64'h1122334455667788, "nothing is written while the machine is in reset");

    restart = 0;
    settle(400);
    check(w(MAGIC_OFF) == MAGIC, $sformatf("out of reset: the magic is published (%h)", w(MAGIC_OFF)));
    check(w(MACO) == {1'b1, 15'd0, mac}, $sformatf("... with the MAC beside it (%h)", w(MACO)));
    check(w(TXW) == 0 && w(TXR) == 0 && w(RXW) == 0 && w(RXR) == 0, "... and every pointer at zero, Main's too");
    gen1 = w(GEN);
    check(gen1[63:32] == 0 && gen1 != 64'hDEADBEEF_00000001, $sformatf("... and GEN written (%h)", gen1));

    // ---- transmit ----
    f = mkframe(100, 1);
    send(f);
    settle(3000);
    check(w(TXW) == 1 && w(TXR) == 1, $sformatf("a frame transmitted moves TX_WPTR to 1, and the daemon takes it (%0d, %0d)",
          w(TXW), w(TXR)));
    check(sent.size() == 1 && same(sent[0], f), $sformatf("... its 100 bytes, no preamble, no FCS (%0d bytes)",
          sent.size() ? sent[0].size() : -1));

    f = mkframe(20, 2);
    send(f);
    settle(3000);
    check(sent.size() == 2 && same(sent[1], padded(f)),
          $sformatf("a 20-byte frame goes out as the chip pads it, 60 bytes (%0d)", sent.size() > 1 ? sent[1].size() : -1));

    f = mkframe(1514, 3);
    send(f);
    settle(8000);
    check(sent.size() == 3 && same(sent[2], f) && w(TXW) == 3, "a 1514-byte frame whole");

    // Ten back to back, more than the ring holds: the chip defers on CRS while
    // each is copied out, and never gives up.
    for (int k = 0; k < 10; k++) send(mkframe(200 + 100 * k, 10 + k));
    settle(8000);
    check(w(TXW) == 13 && sent.size() == 13, $sformatf("ten back to back: TX_WPTR 13 (%0d), all taken (%0d)", w(TXW), sent.size()));
    begin
        bit all = 1;
        for (int k = 0; k < 10; k++) if (!same(sent[3 + k], mkframe(200 + 100 * k, 10 + k))) all = 0;
        check(all, "... each whole, in order");
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

    f = mkframe(42, 21);                         // an ARP, as a host sends it, padded by Main
    deliver(f);
    wait (got.size() == 2);
    check(same(got[1], padded(f)) && !got_err[1], $sformatf("a 42-byte frame arrives padded to 60, FCS good (%0d bytes)", got[1].size()));

    f = mkframe(1514, 22);
    deliver(f);
    wait (got.size() == 3);
    check(same(got[2], f) && !got_err[2], "a 1514-byte frame whole, FCS good");

    f = mkframe(1518, 23);                       // with a VLAN tag: 1522 with the FCS
    deliver(f);
    wait (got.size() == 4);
    check(same(got[3], f) && !got_err[3], "a 1518-byte frame whole, FCS good");

    min_gap = 1 << 30;
    for (int k = 0; k < 4; k++) deliver(mkframe(100 + 300 * k, 30 + k));
    wait (got.size() == 8);
    begin
        bit all = 1;
        for (int k = 0; k < 4; k++) if (!same(got[4 + k], mkframe(100 + 300 * k, 30 + k)) || got_err[4 + k]) all = 0;
        check(all, "four delivered at once arrive whole and in order");
    end
    check(min_gap >= 48, $sformatf("... with at least 48 nibbles between them (%0d)", min_gap));

    // A burst of full-size frames, as a host delivers the fragments of an
    // 8 KiB NFS read and more: all queued at once, all arrive.
    for (int k = 0; k < 12; k++) deliver(mkframe(1514, 100 + k));
    wait (got.size() == 20);
    begin
        bit all = 1;
        for (int k = 0; k < 12; k++) if (!same(got[8 + k], mkframe(1514, 100 + k)) || got_err[8 + k]) all = 0;
        check(all, "twelve full-size frames delivered at once arrive whole and in order");
    end
    got = got[0:7];
    got_err = got_err[0:7];
    check(hashed != 0, $sformatf("... with the hash bits beside every length (%0d of them non-zero)", hashed));

    // nonsense lengths: taken off the ring, never put on the wire
    for (int i = 0; i < 4; i++) begin
        wset(RXS + SLOT * (int'(w(RXW)) % RX_RING), (i == 0) ? 64'd5 : (i == 1) ? 64'd63 : (i == 2) ? 64'd1523 : 64'd2000);
        wset(RXW, w(RXW) + 1);
    end
    settle(20000);
    check(w(RXR) == w(RXW) && got.size() == 8, $sformatf("lengths 5, 63, 1523 and 2000 are taken and dropped (RXR %0d of %0d, %0d frames)",
          w(RXR), w(RXW), got.size()));

    // ---- both at once ----
    fork
        for (int k = 0; k < 3; k++) send(mkframe(300, 40 + k));
        for (int k = 0; k < 3; k++) deliver(mkframe(300, 50 + k));
    join
    wait (got.size() == 11);
    settle(8000);
    begin
        bit all = 1;
        for (int k = 0; k < 3; k++) if (!same(got[8 + k], mkframe(300, 50 + k)) || got_err[8 + k]) all = 0;
        for (int k = 0; k < 3; k++) if (!same(sent[13 + k], mkframe(300, 40 + k))) all = 0;
        check(all && w(TXW) == 16 && tx_bad == 0, $sformatf("three each way at once: all whole (TXW %0d, %0d failed)", w(TXW), tx_bad));
    end

    // ---- the cable out ----
    loopback_n = 0;
    settle(100);
    send(mkframe(100, 60));
    deliver(mkframe(100, 61));
    settle(20000);
    check(w(TXW) == 16, $sformatf("LOOPB-: a transmit goes nowhere (TXW %0d)", w(TXW)));
    check(got.size() == 11 && w(RXR) == w(RXW), $sformatf("... a delivery is taken and dropped (%0d frames, RXR %0d of %0d)",
          got.size(), w(RXR), w(RXW)));
    check(crs_in_loopback == 0, $sformatf("... and CRS stays low while the chip is quiet (%0d clocks high)", crs_in_loopback));
    loopback_n = 1;
    settle(100);

    // ---- Network Off ----
    enable = 0;
    settle(400);
    check(w(MAGIC_OFF) == MAGIC, "Off: the mailbox stays published, for Main to read the setting");
    send(mkframe(100, 70));
    deliver(mkframe(100, 71));
    settle(20000);
    check(w(TXW) == 16 && tx_bad == 0, $sformatf("... a transmit completes into nothing (TXW %0d)", w(TXW)));
    check(got.size() == 11 && w(RXR) == w(RXW), $sformatf("... a delivery is taken and dropped (%0d frames, RXR %0d of %0d)",
          got.size(), w(RXR), w(RXW)));
    enable = 1;
    settle(400);
    f = mkframe(90, 72);
    send(f);
    settle(3000);
    check(w(TXW) == 17 && same(sent[sent.size() - 1], f), "on again: frames flow, no republish");

    // ---- back-pressure: the daemon stops taking ----
    daemon = 0;
    txw0 = longint'(w(TXW));
    for (int k = 0; k < 8; k++) send(mkframe(100 + 10 * k, 120 + k));
    settle(3000);
    check(w(TXW) == txw0 + 8 && tx_bad == 0, $sformatf("the daemon stopped: eight frames fill the ring (TXW %0d of %0d)",
          w(TXW), txw0 + 8));
    send(mkframe(200, 130));                    // X: no room
    t_x = $time;
    fork
        send(mkframe(300, 131));                // Y: behind it
        begin
            settle(2500);                        // 1 ms
            check(w(TXW) == txw0 + 8 && crs, $sformatf("a ninth is held while the ring is full, with CRS high (TXW %0d, CRS %b)",
                  w(TXW), crs));
        end
    join
    t_y = $time;
    check(t_y - t_x >= 10 * MS && t_y - t_x <= 10600000,
          $sformatf("... and dropped after 10 ms: the next frame went out %0d us after it", (t_y - t_x) / 1000));
    check(tx_bad == 0 && w(TXW) == txw0 + 8, $sformatf("... which the chip deferred and sent, not gave up on (%0d failed, TXW %0d)",
          tx_bad, w(TXW)));
    settle(2500);
    daemon = 1;                                 // TX_RPTR moves
    settle(500);
    check(w(TXW) == txw0 + 9 && same(tx_slot_frame(txw0 + 8), mkframe(300, 131)),
          $sformatf("a held frame goes into the ring as soon as TX_RPTR moves (TXW %0d of %0d)", w(TXW), txw0 + 9));
    settle(500);
    begin
        bit all = sent.size() == txw0 + 9;
        for (int k = 0; k < 8 && all; k++) if (!same(sent[txw0 + k], mkframe(100 + 10 * k, 120 + k))) all = 0;
        if (all && !same(sent[txw0 + 8], mkframe(300, 131))) all = 0;
        check(all, $sformatf("... the daemon has the eight and that one, and not the one dropped (%0d taken)", sent.size()));
    end

    // Network switched Off while a frame waits on a full ring: it goes at once.
    daemon = 0;
    txw0 = longint'(w(TXW));
    for (int k = 0; k < 8; k++) send(mkframe(100, 140 + k));
    send(mkframe(100, 150));
    settle(2500);
    check(crs && w(TXW) == txw0 + 8, $sformatf("the ring full again, a frame held (CRS %b, TXW %0d of %0d)", crs, w(TXW), txw0 + 8));
    enable = 0;
    settle(100);                                // 40 us
    check(!crs && w(TXW) == txw0 + 8, $sformatf("... Network Off drops it at once (CRS %b, TXW %0d)", crs, w(TXW)));
    enable = 1;
    daemon = 1;
    settle(500);
    check(sent.size() == txw0 + 8 && w(TXR) == txw0 + 8, $sformatf("... and it never reaches the daemon (%0d taken)", sent.size()));

    // ---- a machine reset ----
    restart = 1;
    settle(400);
    check(w(MAGIC_OFF) == 0, "a machine reset withdraws the magic");
    mac = 48'h08_00_20_AB_CD_EF;
    wset(RXW, 64'd5);                           // whatever Main left
    restart = 0;
    settle(400);
    check(w(MAGIC_OFF) == MAGIC && w(TXW) == 0 && w(TXR) == 0 && w(RXR) == 0 && w(RXW) == 0,
          "leaving it republishes, every pointer back to zero");
    check(w(GEN) != gen1 && w(GEN) >> 32 == 0, $sformatf("... with a new GEN (%h, was %h)", w(GEN), gen1));
    check(w(MACO) == {1'b1, 15'd0, mac}, $sformatf("... and the MAC as it is now (%h)", w(MACO)));
    mac = 48'h08_00_20_12_34_56;
    settle(400);
    check(w(MACO) == {1'b1, 15'd0, mac}, $sformatf("a changed MAC is republished (%h)", w(MACO)));
    f = mkframe(80, 80);
    send(f);
    settle(3000);
    check(same(tx_slot_frame(0), f) && w(TXW) == 1 && same(sent[sent.size() - 1], f), "and frames flow again from slot 0");

    // Full-size frames back to back take longer to copy out than the
    // interframe gap: only CRS held over the copy keeps the next one off the
    // wire until the buffer is free.
    for (int k = 0; k < 3; k++) send(mkframe(1514, 90 + k));
    settle(8000);
    begin
        bit all = 1;
        for (int k = 0; k < 3; k++) if (!same(sent[sent.size() - 3 + k], mkframe(1514, 90 + k))) all = 0;
        check(all && w(TXW) == 4 && tx_bad == 0,
              $sformatf("three 1514-byte frames back to back, all whole (TXW %0d, %0d failed)", w(TXW), tx_bad));
    end

    check(publishes == 2 && early_magic == 0,
          $sformatf("the magic is set only after GEN, the pointers and the MAC (%0d of %0d too early)", early_magic, publishes));
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
