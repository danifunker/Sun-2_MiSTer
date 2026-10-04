//
// sun2_mister_enet.sv
//
// The wire behind the Sun-2's 82586: Ethernet frames between its MII and a
// daemon in Main_MiSTer, through a mailbox in DDR3.
//
// The 82586 (rtl/sun2-vme/sun2_ethernet.sv) is whole in the fabric and talks
// MII.  This module is the PHY it talks to.  What it transmits is taken off
// the MII -- preamble and FCS stripped -- and put in a ring in DDR3; what the
// daemon puts in the other ring comes padded to the minimum length and with
// its FCS, and is played into the MII as given, behind a preamble.  The daemon
// (Main_MiSTer support/sun/sun_enet.cpp, which serves the SPARCstation core
// too) moves frames between the rings and a host interface.
//
// The mailbox is the SPARCstation core's (its rtl/mister/eth_hps.vhd), with
// this core's own magic and a longer receive ring, from which Main knows the
// ring's depth.  All words are 64-bit little-endian; byte i of a frame is byte
// lane i mod 8 of word 1 + i/8 of its slot:
//
//   +0x0000  MAGIC    "S2ETH001" (0x5332455448303031), written here last
//   +0x0008  GEN      a new value at every publish (Main resynchronises)
//   +0x0010  TX_WPTR  ours: frames posted
//   +0x0018  TX_RPTR  Main's: frames taken
//   +0x0020  RX_WPTR  Main's: frames posted
//   +0x0028  RX_RPTR  ours: frames taken
//   +0x0030  MAC      ours: bit 63 valid, 47:40 the first byte .. 7:0 the last
//   +0x1000  TX ring,  8 slots x 2048 bytes: header (10:0 the length), frame
//   +0x5000  RX ring, 16 slots x 2048 bytes: header (10:0 the length with the
//            FCS, 21:16 the destination's multicast hash, unused here), frame
//
// Sixteen receive slots because a host delivers in bursts and this side
// drains at 10 Mb/s: an 8 KiB NFS read is six fragments arriving together,
// and with four slots two of every six were dropped and nothing reassembled --
// measured on the board, 207 fragments in for 50 six-fragment datagrams.
//
// ARM physical 0x1FF00000, 64-bit word 0x03FE0000 on the DDRAM port.  The
// mailbox is published -- every word zeroed bar a new GEN, then the MAC, the
// magic last -- each time the machine leaves reset, and withdrawn when it
// goes into reset again.  Main clears a stale magic when it starts, and then
// sends the boot PROM, which holds the machine in reset; so the core's
// publish always comes after Main's clear.  It stays published with the OSD's
// Network at Off: Main reads that setting from the same status bits, and
// closes the host side only while it sees the magic.
//
// Transmit: while the TX ring is full the frame is held here, and CRS with
// it, so the 82586 defers; after TX_WAIT with no room Main is taken to be
// gone and the frame is dropped.  That is well inside the chip's own give-up,
// 2^16 nibble times (26 ms) of *continuous* carrier (mii_tx's DEFER_LIMIT),
// whose count starts again whenever the line goes quiet.  With Network Off a
// frame goes nowhere at once.  Main never overwrites an RX slot this side has
// not taken; it drops what does not fit.
//
// Two clocks.  The MII side runs on the MII clock, 2.5 MHz: 10 Mb/s, the
// 82586's own speed, and the speed its receive FIFO (256 bytes) and its DVMA
// into main memory keep up with -- at 100 Mb/s a full-size frame overruns the
// FIFO half way through.  The mailbox side runs on `clk', which is also
// DDRAM_CLK and must be a global clock, since DDR3 is at the far end of the
// die; this core gives it clk_mem.  A frame crosses between them in a
// dual-clock buffer, one each way, handed over by a four-phase request and
// acknowledge, so the length beside the buffer is steady whenever the other
// side reads it.
//
// The MII side.  CRS is the medium being busy, and the 82586 defers while it
// is high: during its own transmission, while that frame is being copied out
// to DDR3 or waits for room there (one buffer, so this is the flow control),
// and while a received frame is being played in.  A received frame waits for
// the line to be quiet, and leaves a gap twice the interframe space behind it
// so a waiting transmission always gets the wire.  There are no collisions:
// COL is tied low where this is instantiated.
//
// LOOPB- in the Ethernet control register, at 0, is the cable unplugged:
// nothing goes out, nothing comes in, and CRS stays low.  The drivers put the
// chip in loopback while they configure it and need the line "quiet and
// still" then (sunstand/if_ie.c); they never send through it.
//
`timescale 1ns / 1ps

module sun2_mister_enet #(
    parameter int CLK_HZ = 100_000_000
) (
    input  wire        clk,             // the mailbox side, and DDRAM_CLK
    input  wire        rst,
    input  wire        mii_clk,         // the MII side: the 82586's MII clocks
    input  wire        mii_rst,

    input  wire        restart,         // asynchronous: the machine is in reset
    input  wire        enable,          // asynchronous: the OSD's Network is not Off
    input  wire        loopback_n,      // asynchronous: LOOPB-, 0 = the cable is out
    input  wire [47:0] mac,             // asynchronous, changes only at start-up

    // the PHY side of the 82586's MII, on mii_clk
    input  wire [3:0]  mii_txd,
    input  wire        mii_tx_en,
    output reg  [3:0]  mii_rxd = 4'h0,
    output reg         mii_rx_dv = 1'b0,
    output reg         mii_crs = 1'b0,

    // MiSTer's DDR3 port, one 64-bit word at a time, on clk
    input  wire        DDRAM_BUSY,
    output wire [7:0]  DDRAM_BURSTCNT,
    output reg  [28:0] DDRAM_ADDR = '0,
    input  wire [63:0] DDRAM_DOUT,
    input  wire        DDRAM_DOUT_READY,
    output reg         DDRAM_RD = 1'b0,
    output reg  [63:0] DDRAM_DIN = '0,
    output wire [7:0]  DDRAM_BE,
    output reg         DDRAM_WE = 1'b0
);

    localparam [28:0] BASE     = 29'h03FE0000;      // byte 0x1FF00000
    localparam [28:0] A_MAGIC  = BASE + 29'h000;
    localparam [28:0] A_TXWPTR = BASE + 29'h002;
    localparam [28:0] A_TXRPTR = BASE + 29'h003;
    localparam [28:0] A_RXWPTR = BASE + 29'h004;
    localparam [28:0] A_RXRPTR = BASE + 29'h005;
    localparam [28:0] A_MAC    = BASE + 29'h006;
    localparam [28:0] A_TXSLOT = BASE + 29'h200;    // byte +0x1000
    localparam [28:0] A_RXSLOT = BASE + 29'hA00;    // byte +0x5000
    localparam [63:0] MAGIC    = 64'h5332455448303031;
    localparam [63:0] TX_RING  = 64'd8;

    localparam int    POLL     = CLK_HZ / 5000;     // look for a delivered frame every 200 us
    localparam int    RETRY    = CLK_HZ / 100_000;  // the TX ring full: look again in 10 us
    localparam int    TX_WAIT  = CLK_HZ / 100;      // and give up after 10 ms of it
    localparam int    RX_GAP   = 48;                // nibbles after a received frame: twice 96 bit times
    localparam [10:0] MIN_DATA = 11'd60;            // the shortest frame, FCS not counted
    localparam [10:0] MAX_DATA = 11'd1518;          // the longest, with a VLAN tag
    localparam [10:0] RX_MIN   = MIN_DATA + 11'd4;  // what Main delivers: the FCS counted
    localparam [10:0] RX_MAX   = MAX_DATA + 11'd4;

    assign DDRAM_BURSTCNT = 8'd1;
    assign DDRAM_BE       = 8'hFF;

    // ---- the crossings ---------------------------------------------------------------
    // Into the mailbox side: the machine's reset, the OSD's switch, LOOPB-, the
    // MAC, and the MII side's two handshake signals.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  mrst_s = 2'b11, en_s = 2'b00, cable_s = 2'b00, txreq_s = 2'b00, rxack_s = 2'b00;
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [47:0] mac_s1 = '0;
    reg [47:0] mac_s2 = '0, mac_q = '0;
    reg        tx_req_m = 1'b0, rx_ack_m = 1'b0;        // the MII side's, below
    always @(posedge clk) begin
        mrst_s  <= {mrst_s[0], restart};
        en_s    <= {en_s[0], enable};
        cable_s <= {cable_s[0], loopback_n};
        txreq_s <= {txreq_s[0], tx_req_m};
        rxack_s <= {rxack_s[0], rx_ack_m};
        mac_s1  <= mac;
        mac_s2  <= mac_s1;
        if (mac_s2 == mac_s1) mac_q <= mac_s2;
    end
    wire run    = !mrst_s[1];
    wire on     = en_s[1];
    wire cable  = cable_s[1];
    wire tx_req = txreq_s[1];
    wire rx_ack = rxack_s[1];

    // Into the MII side: the same two switches, and the mailbox side's two.
    (* altera_attribute = "-name SYNCHRONIZER_IDENTIFICATION FORCED_IF_ASYNCHRONOUS" *)
    reg [1:0]  en_m = 2'b00, cable_m = 2'b00, txack_m = 2'b00, rxreq_m = 2'b00;
    reg        tx_ack = 1'b0, rx_req = 1'b0;            // the mailbox side's, below
    always @(posedge mii_clk) begin
        en_m    <= {en_m[0], enable};
        cable_m <= {cable_m[0], loopback_n};
        txack_m <= {txack_m[0], tx_ack};
        rxreq_m <= {rxreq_m[0], rx_req};
    end
    wire on_m     = en_m[1];
    wire cable_mm = cable_m[1];
    wire tx_ack_m = txack_m[1];
    wire rx_req_m = rxreq_m[1];

    // ---- transmit: the MII into a frame buffer -----------------------------------
    // One frame at a time.  It is held from its first nibble until the mailbox
    // side has taken it (or dropped it), and CRS stays high all that while.
    localparam [2:0] T_IDLE = 3'd0, T_PRE = 3'd1, T_DATA = 3'd2, T_HELD = 3'd3, T_DONE = 3'd4;
    reg [2:0]  tst = T_IDLE;
    reg        thalf = 1'b0;
    reg [3:0]  tlo = 4'h0;
    reg [11:0] tn = '0;                 // bytes taken, FCS included
    reg [10:0] tx_len = '0;             // the frame held, FCS removed; steady while tx_req_m

    reg [7:0]  txbuf [0:2047];
    reg        txbuf_we = 1'b0;
    reg [10:0] txbuf_waddr = '0;
    reg [7:0]  txbuf_wdata = 8'h0;
    reg [10:0] txbuf_raddr = '0;
    reg [7:0]  txbuf_q = 8'h0;
    always @(posedge mii_clk)
        if (txbuf_we) txbuf[txbuf_waddr] <= txbuf_wdata;
    always @(posedge clk)
        txbuf_q <= txbuf[txbuf_raddr];

    always @(posedge mii_clk) begin
        txbuf_we <= 1'b0;
        if (mii_rst) begin
            tst      <= T_IDLE;
            tx_req_m <= 1'b0;
        end else case (tst)
            T_IDLE:
                if (mii_tx_en) tst <= T_PRE;
            T_PRE:                              // 5s, then the D that ends the SFD
                if (!mii_tx_en)            tst <= T_IDLE;
                else if (mii_txd == 4'hD) begin
                    tst   <= T_DATA;
                    thalf <= 1'b0;
                    tn    <= '0;
                end
            T_DATA:
                if (mii_tx_en) begin
                    thalf <= ~thalf;
                    if (!thalf) tlo <= mii_txd;
                    else if (!tn[11]) begin
                        txbuf_we    <= 1'b1;
                        txbuf_waddr <= tn[10:0];
                        txbuf_wdata <= {mii_txd, tlo};
                        tn          <= tn + 1'd1;
                    end
                end else begin
                    // Whole bytes, a frame's worth, and somewhere to send it.
                    tx_len <= tn[10:0] - 11'd4;
                    if (!thalf && tn >= MIN_DATA + 12'd4 && tn <= MAX_DATA + 12'd4 && cable_mm && on_m)
                        tst <= T_HELD;
                    else
                        tst <= T_IDLE;
                end
            T_HELD: begin                       // the last byte has been written: offer it
                tx_req_m <= 1'b1;
                if (tx_req_m && tx_ack_m) begin
                    tx_req_m <= 1'b0;
                    tst      <= T_DONE;
                end
            end
            T_DONE:                             // and wait for the other side to let go
                if (!tx_ack_m) tst <= T_IDLE;
            default: tst <= T_IDLE;
        endcase
    end

    // ---- receive: a frame buffer onto the MII ------------------------------------
    // The frame is played as Main delivered it, padding and FCS included.
    localparam [2:0] R_IDLE = 3'd0, R_PRE = 3'd1, R_DATA = 3'd2, R_GAP = 3'd3;
    reg [2:0]  rst_st = R_IDLE;
    reg [10:0] rx_len = '0;             // set by the mailbox side; steady while rx_req
    reg [10:0] ri = '0;                 // byte being sent
    reg        rhalf = 1'b0;
    reg [4:0]  rcnt = '0;
    reg [5:0]  rgap = '0;
    reg [7:0]  rhold = 8'h0;

    reg [7:0]  rxbuf [0:2047];
    reg        rxbuf_we = 1'b0;
    reg [10:0] rxbuf_waddr = '0;
    reg [7:0]  rxbuf_wdata = 8'h0;
    reg [10:0] rxbuf_raddr = '0;
    reg [7:0]  rxbuf_q = 8'h0;
    always @(posedge clk)
        if (rxbuf_we) rxbuf[rxbuf_waddr] <= rxbuf_wdata;
    always @(posedge mii_clk)
        rxbuf_q <= rxbuf[rxbuf_raddr];

    always @(posedge mii_clk) begin
        if (mii_rst) begin
            rst_st    <= R_IDLE;
            mii_rx_dv <= 1'b0;
            mii_rxd   <= 4'h0;
            rx_ack_m  <= 1'b0;
        end else begin
            if (!rx_req_m) rx_ack_m <= 1'b0;    // the other side has seen it: back to zero
            case (rst_st)
                R_IDLE: begin
                    mii_rx_dv <= 1'b0;
                    if (rx_req_m && !rx_ack_m && tst == T_IDLE && !mii_tx_en) begin
                        rst_st      <= R_PRE;
                        rcnt        <= 5'd15;
                        rxbuf_raddr <= '0;      // byte 0 is ready by the end of the preamble
                    end
                end
                R_PRE: begin                    // fifteen 5s and a D
                    mii_rx_dv <= 1'b1;
                    mii_rxd   <= (rcnt == 0) ? 4'hD : 4'h5;
                    rcnt      <= rcnt - 1'd1;
                    if (rcnt == 0) begin
                        rst_st <= R_DATA;
                        ri     <= '0;
                        rhalf  <= 1'b0;
                    end
                end
                R_DATA: begin                   // low nibble first
                    rhalf   <= ~rhalf;
                    mii_rxd <= rhalf ? rhold[7:4] : rxbuf_q[3:0];
                    if (!rhalf) begin
                        rhold       <= rxbuf_q;
                        rxbuf_raddr <= ri + 1'd1;
                    end else begin
                        ri <= ri + 1'd1;
                        if (ri + 1'd1 == rx_len) begin
                            rst_st   <= R_GAP;
                            rgap     <= RX_GAP;
                            rx_ack_m <= 1'b1;   // the buffer is free again
                        end
                    end
                end
                R_GAP: begin
                    mii_rx_dv <= 1'b0;
                    rgap      <= rgap - 1'd1;
                    if (rgap == 0) rst_st <= R_IDLE;
                end
                default: rst_st <= R_IDLE;
            endcase
        end
    end

    // The medium is busy: CRS, registered, as a PHY's own pin would be.
    always @(posedge mii_clk)
        mii_crs <= !mii_rst && (mii_tx_en || tst == T_PRE || tst == T_DATA ||
                                (cable_mm && (tst == T_HELD || tst == T_DONE ||
                                              rst_st == R_PRE || rst_st == R_DATA)));

    // ---- the mailbox ---------------------------------------------------------------
    localparam [4:0] E_OFF      = 5'd0,  E_CLR     = 5'd1,  E_PUB     = 5'd2,  E_UNPUB   = 5'd3,
                     E_IDLE     = 5'd4,
                     E_TX_RPTR  = 5'd5,  E_TX_ADDR = 5'd6,  E_TX_BYTE = 5'd7,  E_TX_HDR  = 5'd8,
                     E_TX_PTR   = 5'd9,
                     E_RX_WPTR  = 5'd10, E_RX_HDR  = 5'd11, E_RX_WORD = 5'd12, E_RX_UNPACK = 5'd13,
                     E_RX_PTR   = 5'd14, E_MAC     = 5'd15,
                     E_MEM      = 5'd16, E_MEM_RD  = 5'd17;

    reg [4:0]  est = E_OFF, eret = E_OFF;
    reg [2:0]  pstep = '0;              // the word being written as the mailbox is published
    reg [31:0] gen = '0;                // runs from power-up, so no two publishes see the same
    reg [63:0] tx_wptr = '0, rx_wptr = '0, rx_rptr = '0;
    reg [63:0] rdata = '0;
    reg [63:0] pack = '0;
    reg [10:0] ei = '0;                 // byte of the frame being moved
    reg [10:0] elen = '0;
    reg [47:0] mac_pub = '0;
    reg        rx_keep = 1'b0;          // this delivered frame goes to the wire; else it is dropped
    reg [$clog2(POLL) - 1:0]    poll = '0;
    reg [$clog2(RETRY + 1) - 1:0]   retry = '0;
    reg [$clog2(TX_WAIT + 1) - 1:0] twait = '0;     // how long the frame offered has waited

    wire [28:0] tx_slot  = A_TXSLOT + {tx_wptr[2:0], 8'h00};
    wire [28:0] rx_slot  = A_RXSLOT + {rx_rptr[3:0], 8'h00};
    wire        tx_ready = tx_req && !tx_ack;           // a frame is offered and not yet taken
    wire        rx_free  = !rx_req && !rx_ack;          // the MII side has nothing of ours
    wire        rx_good  = on && cable && rdata[10:0] >= RX_MIN && rdata[10:0] <= RX_MAX;

    task automatic mem(input bit we, input [28:0] a, input [63:0] d, input [4:0] next);
        begin
            DDRAM_ADDR <= a;
            DDRAM_DIN  <= d;
            DDRAM_WE   <= we;
            DDRAM_RD   <= ~we;
            eret       <= next;
            est        <= E_MEM;
        end
    endtask

    always @(posedge clk) begin
        rxbuf_we <= 1'b0;
        gen  <= gen + 1'd1;
        poll <= (poll == POLL - 1) ? '0 : poll + 1'd1;
        if (retry != 0) retry <= retry - 1'd1;
        if (!tx_ready) twait <= '0;
        else if (twait != TX_WAIT) twait <= twait + 1'd1;
        if (!tx_req) tx_ack <= 1'b0;    // the MII side has seen it: back to zero
        if (rx_ack)  rx_req <= 1'b0;    // the frame has been played in

        if (rst) begin
            est      <= E_OFF;
            DDRAM_RD <= 1'b0;
            DDRAM_WE <= 1'b0;
            tx_ack   <= 1'b0;
            rx_req   <= 1'b0;
        end else case (est)
            E_OFF:
                // A disconnected wire: anything transmitted is gone.
                if (tx_ready) tx_ack <= 1'b1;
                else if (run) begin
                    pstep   <= '0;
                    tx_wptr <= '0;
                    rx_wptr <= '0;
                    rx_rptr <= '0;
                    est     <= E_CLR;
                end

            // Publish: the magic cleared, GEN, the four pointers, the MAC, and
            // the magic last.
            E_CLR: begin
                pstep <= pstep + 1'd1;
                if (pstep == 3'd6) mac_pub <= mac_q;
                mem(1, BASE + pstep,
                    (pstep == 3'd1) ? {32'd0, gen} : (pstep == 3'd6) ? {1'b1, 15'd0, mac_q} : 64'd0,
                    (pstep == 3'd6) ? E_PUB : E_CLR);
            end
            E_PUB:   mem(1, A_MAGIC, MAGIC, E_IDLE);
            E_UNPUB: mem(1, A_MAGIC, 64'd0, E_OFF);

            E_IDLE:
                if (!run)
                    est <= E_UNPUB;
                else if (tx_ready && !on)
                    tx_ack <= 1'b1;             // Network Off: into nothing
                else if (tx_ready && retry == 0)
                    mem(0, A_TXRPTR, 64'd0, E_TX_RPTR);
                else if (mac_q != mac_pub)
                    est <= E_MAC;
                else if (rx_rptr != rx_wptr && rx_free)
                    mem(0, rx_slot, 64'd0, E_RX_HDR);
                else if (poll == 0)
                    mem(0, A_RXWPTR, 64'd0, E_RX_WPTR);

            // transmit: room in the ring, eight bytes into a word, a word into the slot.
            // The pointers are 64 bits in the mailbox, but they are never more
            // than the ring apart, so the low 16 bits say whether there is room;
            // and the buffer's read address is set whatever the answer, so that
            // the comparison does not reach the RAM's address register in the
            // same clock -- that path missed timing at 100 MHz.
            E_TX_RPTR: begin
                txbuf_raddr <= '0;
                if (16'(tx_wptr[15:0] - rdata[15:0]) < 16'(TX_RING)) begin
                    ei          <= '0;
                    elen        <= tx_len;      // steady: the MII side holds it while it asks
                    pack        <= '0;
                    est         <= E_TX_ADDR;
                end else if (twait == TX_WAIT) begin
                    tx_ack <= 1'b1;             // nobody is taking frames: dropped
                    est    <= E_IDLE;
                end else begin
                    retry <= RETRY;             // full: the 82586 defers on CRS meanwhile
                    est   <= E_IDLE;
                end
            end
            E_TX_ADDR:
                est <= E_TX_BYTE;               // the buffer's read latency
            E_TX_BYTE: begin
                pack[ei[2:0]*8 +: 8] <= txbuf_q;
                txbuf_raddr <= ei + 1'd1;
                ei          <= ei + 1'd1;
                if (ei[2:0] == 3'd7 || ei + 1'd1 == elen) begin
                    pack <= '0;
                    mem(1, tx_slot + 29'd1 + ei[10:3], pack | ({56'd0, txbuf_q} << (ei[2:0]*8)),
                        (ei + 1'd1 == elen) ? E_TX_HDR : E_TX_ADDR);
                end else
                    est <= E_TX_ADDR;
            end
            E_TX_HDR:  mem(1, tx_slot, {53'd0, elen}, E_TX_PTR);
            E_TX_PTR: begin
                tx_wptr <= tx_wptr + 1'd1;
                tx_ack  <= 1'b1;
                mem(1, A_TXWPTR, tx_wptr + 1'd1, E_IDLE);
            end

            // receive
            E_RX_WPTR: begin
                rx_wptr <= rdata;
                est     <= E_IDLE;
            end
            E_RX_HDR: begin
                elen    <= rdata[10:0];
                ei      <= '0;
                rx_keep <= rx_good;
                if (rx_good)
                    mem(0, rx_slot + 29'd1, 64'd0, E_RX_UNPACK);
                else
                    est <= E_RX_PTR;            // nonsense, or nowhere to put it: drop it
            end
            E_RX_WORD:
                mem(0, rx_slot + 29'd1 + ei[10:3], 64'd0, E_RX_UNPACK);
            E_RX_UNPACK: begin
                rxbuf_we    <= 1'b1;
                rxbuf_waddr <= ei;
                rxbuf_wdata <= rdata[ei[2:0]*8 +: 8];
                ei          <= ei + 1'd1;
                if (ei + 1'd1 == elen)
                    est <= E_RX_PTR;
                else if (ei[2:0] == 3'd7)
                    est <= E_RX_WORD;
            end
            E_RX_PTR: begin
                rx_rptr <= rx_rptr + 1'd1;
                if (rx_keep) begin
                    rx_len <= elen;             // before the request, and steady under it
                    rx_req <= 1'b1;
                end
                rx_keep <= 1'b0;
                mem(1, A_RXRPTR, rx_rptr + 1'd1, E_IDLE);
            end

            E_MAC: begin
                mac_pub <= mac_q;
                mem(1, A_MAC, {1'b1, 15'd0, mac_q}, E_IDLE);
            end

            // one word: the command is taken on a clock with BUSY low, and a
            // read's answer comes later
            E_MEM:
                if (!DDRAM_BUSY) begin
                    DDRAM_WE <= 1'b0;
                    DDRAM_RD <= 1'b0;
                    est      <= DDRAM_RD ? E_MEM_RD : eret;
                end
            E_MEM_RD:
                if (DDRAM_DOUT_READY) begin
                    rdata <= DDRAM_DOUT;
                    est   <= eret;
                end

            default: est <= E_OFF;
        endcase
    end

endmodule
