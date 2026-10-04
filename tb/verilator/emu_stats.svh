// emu_stats.svh -- where the SDRAM's time goes, and what that costs the CPU.
//
// Included by tb_emu.sv.  It reads the design by hierarchical name and drives
// nothing, so a run with it is the run without it.
//
//   The SDRAM (clk_mem, sun2_mister_sdram).  Every clock is charged to whoever
//   holds the adapter: nobody, a CPU read or write, the colour scan-out, the
//   colour board's engine, or the mono scan-out.  A CPU request is timed from
//   the clock its wb_cyc rises to the clock the adapter takes it (its wait)
//   and to its acknowledge (its service), and every clock it waits is charged
//   to whoever held the adapter.  The engine's requests are timed the same way.
//
//   The colour scan-out.  The clocks it asks for a line, the clocks it asks
//   urgently, the bursts it is given and how many of those urgently, and, as
//   each displayed line begins, how many lines the fetch is ahead of it.  A
//   line is late if the line whose display begins is not complete (lead 0).
//
//   The CPU (cpu_clk, sun2_cached_fifo_bridge).  Data phases, read hits and
//   misses, the clocks a CPU phase waits for memory or for the colour board,
//   and each read's latency from being queued to its answer, in CPU clocks.
//
// Reported every +stats_ms (default 100) as the interval's figures, and in
// full at the end.  Two optional outputs:
//
//   +pc_watch=FILE   lines "<hex address> <name>": the first supervisor
//                    instruction fetch from each address is logged with its
//                    time -- milestones in a kernel boot that do not depend on
//                    how fast the console draws
//   +mem_trace=FILE  every memory data phase through the bridge, as 4 bytes,
//                    big-endian: bit 31 a write, bit 30 cacheable, bit 29 DVMA,
//                    bits 23..1 the physical address (tools/cachesim reads it)

localparam int ST_NO = 6;                       // owners of the adapter
localparam int O_IDLE = 0, O_CPU_RD = 1, O_CPU_WR = 2, O_CS = 3, O_CG = 4, O_FB = 5;
localparam int ST_HB = 256;                     // histogram buckets; the last is "or more"
localparam int ST_NH = 7;
localparam int H_SD_RD_WAIT = 0, H_SD_RD_TOT = 1, H_SD_WR_TOT = 2, H_CG_TOT = 3,
               H_CPU_MISS = 4, H_CPU_UNC = 5, H_LEAD = 6;

longint st_hist [ST_NH][ST_HB];
longint st_hn   [ST_NH];
longint st_hsum [ST_NH];
longint st_hmax [ST_NH];

function automatic void st_hadd(int h, longint v);
    longint b = (v < 0) ? 0 : (v >= ST_HB ? ST_HB - 1 : v);
    st_hist[h][b] += 1;
    st_hn[h]      += 1;
    st_hsum[h]    += v;
    if (v > st_hmax[h]) st_hmax[h] = v;
endfunction

// the smallest bucket at or below which a fraction p of the samples fall
function automatic longint st_pct(int h, real p);
    longint acc = 0;
    real    want = p * real'(st_hn[h]);
    for (int i = 0; i < ST_HB; i++) begin
        acc += st_hist[h][i];
        if (real'(acc) >= want) return i;
    end
    return ST_HB - 1;
endfunction

function automatic string st_dist(int h);
    if (st_hn[h] == 0) return "none";
    return $sformatf("n %0d mean %0.2f p50 %0d p90 %0d p99 %0d p99.9 %0d max %0d",
                     st_hn[h], real'(st_hsum[h]) / real'(st_hn[h]),
                     st_pct(h, 0.5), st_pct(h, 0.9), st_pct(h, 0.99), st_pct(h, 0.999), st_hmax[h]);
endfunction

// every non-empty bucket, "value:count"
function automatic string st_buckets(int h);
    string s = "";
    for (int i = 0; i < ST_HB; i++)
        if (st_hist[h][i] != 0)
            s = {s, $sformatf(" %0d%s:%0d", i, i == ST_HB - 1 ? "+" : "", st_hist[h][i])};
    return s;
endfunction

function automatic real st_pc(longint a, longint b);
    return b == 0 ? 0.0 : 100.0 * real'(a) / real'(b);
endfunction

// ---- the SDRAM ---------------------------------------------------------------------
longint sd_clk = 0;
longint sd_cyc     [ST_NO];
longint sd_starts  [ST_NO];
longint sd_wait_by [ST_NO];                     // CPU-wait clocks, charged to the holder
longint cg_wait_by [ST_NO];                     // engine-wait clocks, likewise
longint cs_req_cyc = 0, cs_urg_cyc = 0, cs_urg_starts = 0, cs_late = 0, cs_lines = 0;
bit     cs_armed = 0;

bit     cpu_pend = 0, cpu_started = 0, cpu_we = 0, want_d = 0;
longint cpu_t0 = 0;
bit     cg_pend = 0, cg_started = 0, cgreq_d = 0;
longint cg_t0 = 0;

function automatic int st_owner();
    if (dut.sdram.st == 3'd0) return O_IDLE;
    if (dut.sdram.for_fb)     return O_FB;
    if (dut.sdram.for_cs)     return O_CS;
    if (dut.sdram.for_cg)     return O_CG;
    return dut.sdram.wb_we_i ? O_CPU_WR : O_CPU_RD;
endfunction

// whom the adapter takes on this edge, if it is idle and anyone asks; -1 if nobody
function automatic int st_taken();
    if (dut.sdram.st != 3'd0 || dut.sdram.init) return -1;
    if (dut.sdram.fb_c_req)                          return O_FB;
    if (dut.sdram.pick == 2'd0 && dut.sdram.cs_req)  return O_CS;
    if (dut.sdram.pick == 2'd2 && dut.sdram.cg_req)  return O_CG;
    if (dut.sdram.pick == 2'd1 && dut.sdram.wb_want) return dut.sdram.wb_we_i ? O_CPU_WR : O_CPU_RD;
    return -1;
endfunction

always @(posedge dut.clk_mem) begin
    int own, tk;
    own = st_owner();
    tk  = st_taken();
    sd_clk += 1;
    sd_cyc[own] += 1;
    if (tk >= 0) sd_starts[tk] += 1;

    // the CPU's requests
    if (dut.sdram.wb_want && !want_d) begin
        cpu_pend    = 1;
        cpu_started = 0;
        cpu_t0      = sd_clk;
        cpu_we      = dut.sdram.wb_we_i;
    end
    if (cpu_pend && !cpu_started) begin
        if (tk == O_CPU_RD || tk == O_CPU_WR) begin
            cpu_started = 1;
            if (!cpu_we) st_hadd(H_SD_RD_WAIT, sd_clk - cpu_t0);
        end else
            sd_wait_by[tk >= 0 ? tk : own] += 1;
    end
    if (cpu_pend && dut.sdram.wb_ack_o) begin
        st_hadd(cpu_we ? H_SD_WR_TOT : H_SD_RD_TOT, sd_clk - cpu_t0);
        cpu_pend = 0;
    end
    want_d = dut.sdram.wb_want;

    // the engine's
    if (dut.sdram.cg_req && !cgreq_d && !cg_pend) begin
        cg_pend    = 1;
        cg_started = 0;
        cg_t0      = sd_clk;
    end
    if (cg_pend && !cg_started) begin
        if (tk == O_CG) cg_started = 1;
        else            cg_wait_by[tk >= 0 ? tk : own] += 1;
    end
    if (cg_pend && dut.sdram.cg_done) begin
        st_hadd(H_CG_TOT, sd_clk - cg_t0);
        cg_pend = 0;
    end
    cgreq_d = dut.sdram.cg_req & ~dut.sdram.cg_done;

    // the colour scan-out
    if (dut.sdram.cs_req) cs_req_cyc += 1;
    if (dut.sdram.cs_req && dut.sdram.cs_urgent) cs_urg_cyc += 1;
    if (tk == O_CS && dut.sdram.cs_urgent) cs_urg_starts += 1;
    // Lines count from the first frame begun with the SDRAM up: the frame
    // under way while it initialises cannot be fetched.
    if (dut.cg_scanout.fs_pulse && !dut.sdram.init) cs_armed = 1;
    if (cs_armed && dut.cg_scanout.ls_pulse && !dut.cg_scanout.fs_pulse && !dut.cg_scanout.mrst &&
        dut.cg_scanout.enable && dut.cg_scanout.shown < 11'd900) begin
        int lead;
        lead = int'(dut.cg_scanout.fetch_row) - int'(dut.cg_scanout.shown);
        st_hadd(H_LEAD, lead);
        cs_lines += 1;
        if (lead <= 0) begin
            cs_late += 1;
            if (cs_late <= 20)
                $display("[%0t] stats: colour line %0d late, fetch at line %0d beat %0d",
                         $time, dut.cg_scanout.shown, dut.cg_scanout.fetch_row, dut.cg_scanout.beat);
        end
    end
end

// ---- the CPU, at the bridge ------------------------------------------------------------
longint cp_cyc = 0, cp_phase = 0, cp_wait = 0, cp_wait_rd = 0, cp_wait_unc = 0, cp_wait_wr = 0;
longint cp_hits = 0, cp_miss = 0, cp_unc = 0, cp_wr = 0, cp_dvma = 0, cp_cg_wait = 0, cp_cg_phase = 0;
longint cp_t0 = 0;
bit     cp_unc_rd = 0;

int     tr_fd = 0;
string  pcw_name [int unsigned];
bit     as_d = 1'b1;

initial begin
    string f;
    if ($value$plusargs("mem_trace=%s", f)) begin
        tr_fd = $fopen(f, "wb");
        $display("stats: memory trace to %s", f);
    end
    if ($value$plusargs("pc_watch=%s", f)) begin
        int fd, n;
        int unsigned a;
        string nm;
        fd = $fopen(f, "r");
        if (fd == 0) $display("stats: cannot read %s", f);
        else begin
            while ($fscanf(fd, "%h %s\n", a, nm) == 2) pcw_name[a] = nm;
            $fclose(fd);
            $display("stats: watching %0d addresses from %s", pcw_name.num(), f);
        end
    end
end

always @(posedge dut.cpu_clk) begin
    bit ph, ack, rd, cach, dv;
    ph   = dut.machine.sun2.wbridge.PHASE;
    ack  = dut.machine.sun2.wbridge.W_ACK;
    rd   = dut.machine.sun2.wbridge.P_RW_n;
    cach = dut.machine.sun2.wbridge.CACHEABLE;
    dv   = dut.machine.dvma_active;

    if (dut.machine.sun2.wbridge.ENABLE) begin
        cp_cyc += 1;
        if (ph && !dv) begin
            cp_phase += 1;
            if (!ack) begin
                cp_wait += 1;
                if (!rd)       cp_wait_wr  += 1;
                else if (cach) cp_wait_rd  += 1;
                else           cp_wait_unc += 1;
            end
        end
        if (dut.machine.sun2.wbridge.rd_hit) cp_hits += 1;
        if (dut.machine.sun2.wbridge.enq) begin
            if (dv) cp_dvma += 1;
            if (!rd) cp_wr += 1;
            else begin
                cp_t0     = cp_cyc;
                cp_unc_rd = !cach;
                if (cach) cp_miss += 1; else cp_unc += 1;
            end
        end
        if (dut.machine.sun2.wbridge.rs_ours)
            st_hadd(cp_unc_rd ? H_CPU_UNC : H_CPU_MISS, cp_cyc - cp_t0);
        if (tr_fd != 0 && (dut.machine.sun2.wbridge.rd_hit || dut.machine.sun2.wbridge.enq)) begin
            bit [31:0] w;
            w = {!rd, cach, dv, 5'd0, dut.machine.sun2.wbridge.P_ADR_IN, 1'b0};
            $fwrite(tr_fd, "%c%c%c%c", w[31:24], w[23:16], w[15:8], w[7:0]);
        end
    end

    // a CPU phase on the colour board, and the clocks it waits for its answer
    if (dut.cgtwo.hit && dut.cgtwo.strobe && !dv) begin
        cp_cg_phase += 1;
        if (!dut.cgtwo.done) cp_cg_wait += 1;
    end

    // milestones: a supervisor instruction fetch from a watched address
    if (pcw_name.num() != 0 && as_d && !dut.machine.P_AS_n && !dv && dut.machine.P_FC == 3'd6) begin
        int unsigned a;
        a = {8'd0, dut.machine.P_A, 1'b0};
        if (pcw_name.exists(a)) begin
            $display("[%0t] stats: pc %06x %s", $time, a, pcw_name[a]);
            pcw_name.delete(a);
        end
    end
    as_d = dut.machine.P_AS_n;
end

// ---- reporting ----------------------------------------------------------------------------
longint pv_sd_clk = 0, pv_sd_cyc [ST_NO], pv_cs_urg_starts = 0, pv_cs_late = 0;
longint pv_cp_cyc = 0, pv_cp_wait = 0, pv_cp_hits = 0, pv_cp_miss = 0, pv_cp_cg_wait = 0;
longint pv_hn [ST_NH], pv_hsum [ST_NH];

function automatic real st_mean_d(int h);
    longint n = st_hn[h] - pv_hn[h];
    return n == 0 ? 0.0 : real'(st_hsum[h] - pv_hsum[h]) / real'(n);
endfunction

initial begin : stats_tick
    real ms;
    if (!$value$plusargs("stats_ms=%f", ms)) ms = 100.0;
    forever begin
        longint dc, dp;
        #(longint'(ms * 1.0e9));
        dc = sd_clk - pv_sd_clk;
        dp = cp_cyc - pv_cp_cyc;
        $display("[%0t] stats: sdram idle %4.1f%% cpu-r %4.1f%% cpu-w %4.1f%% colour %4.1f%% engine %4.1f%% mono %4.1f%% | cpu read wait %0.1f, service %0.1f clk_mem | colour urgent %0d late %0d | cpu hits %0d misses %0d miss %0.2f clk, waiting %4.1f%%, on colour board %4.1f%%",
                 $time,
                 st_pc(sd_cyc[O_IDLE]   - pv_sd_cyc[O_IDLE],   dc),
                 st_pc(sd_cyc[O_CPU_RD] - pv_sd_cyc[O_CPU_RD], dc),
                 st_pc(sd_cyc[O_CPU_WR] - pv_sd_cyc[O_CPU_WR], dc),
                 st_pc(sd_cyc[O_CS]     - pv_sd_cyc[O_CS],     dc),
                 st_pc(sd_cyc[O_CG]     - pv_sd_cyc[O_CG],     dc),
                 st_pc(sd_cyc[O_FB]     - pv_sd_cyc[O_FB],     dc),
                 st_mean_d(H_SD_RD_WAIT), st_mean_d(H_SD_RD_TOT),
                 cs_urg_starts - pv_cs_urg_starts, cs_late - pv_cs_late,
                 cp_hits - pv_cp_hits, cp_miss - pv_cp_miss, st_mean_d(H_CPU_MISS),
                 st_pc(cp_wait - pv_cp_wait, dp), st_pc(cp_cg_wait - pv_cp_cg_wait, dp));
        $fflush;
        pv_sd_clk = sd_clk;
        for (int i = 0; i < ST_NO; i++) pv_sd_cyc[i] = sd_cyc[i];
        pv_cs_urg_starts = cs_urg_starts;
        pv_cs_late       = cs_late;
        pv_cp_cyc     = cp_cyc;
        pv_cp_wait    = cp_wait;
        pv_cp_hits    = cp_hits;
        pv_cp_miss    = cp_miss;
        pv_cp_cg_wait = cp_cg_wait;
        for (int i = 0; i < ST_NH; i++) begin pv_hn[i] = st_hn[i]; pv_hsum[i] = st_hsum[i]; end
    end
end

final begin
    string nm [ST_NO] = '{"idle", "cpu read", "cpu write", "colour scan-out", "colour engine", "mono scan-out"};
    if (tr_fd != 0) $fclose(tr_fd);
    $display("stats: ---- the whole run ----");
    $display("stats: sdram, %0d clk_mem clocks:", sd_clk);
    for (int i = 0; i < ST_NO; i++)
        $display("stats:   %-16s %5.1f%%  %0d accesses", nm[i], st_pc(sd_cyc[i], sd_clk), sd_starts[i]);
    $display("stats: cpu reads at the sdram, wait (clk_mem): %s", st_dist(H_SD_RD_WAIT));
    $display("stats: cpu reads at the sdram, service:        %s", st_dist(H_SD_RD_TOT));
    $display("stats: cpu writes at the sdram, service:       %s", st_dist(H_SD_WR_TOT));
    $display("stats: cpu waiting clocks charged to:");
    for (int i = 0; i < ST_NO; i++)
        if (sd_wait_by[i] != 0) $display("stats:   %-16s %0d", nm[i], sd_wait_by[i]);
    $display("stats: engine requests, service (clk_mem):     %s", st_dist(H_CG_TOT));
    $display("stats: engine waiting clocks charged to:");
    for (int i = 0; i < ST_NO; i++)
        if (cg_wait_by[i] != 0) $display("stats:   %-16s %0d", nm[i], cg_wait_by[i]);
    $display("stats: colour scan-out asked %0d clocks (%0.1f%%), urgently %0d (%0.1f%%); %0d bursts, %0d of them urgent",
             cs_req_cyc, st_pc(cs_req_cyc, sd_clk), cs_urg_cyc, st_pc(cs_urg_cyc, sd_clk),
             sd_starts[O_CS], cs_urg_starts);
    $display("stats: colour lines shown %0d, late %0d; lines ahead at each line's start:%s",
             cs_lines, cs_late, st_buckets(H_LEAD));
    $display("stats: cpu, %0d cpu_clk clocks with the bridge enabled: %0d memory phases, waiting %0d (%0.2f%% of clocks): read misses %0d, uncached reads %0d, writes %0d",
             cp_cyc, cp_phase, cp_wait, st_pc(cp_wait, cp_cyc), cp_wait_rd, cp_wait_unc, cp_wait_wr);
    $display("stats: cpu, read hits %0d, misses %0d (hit rate %0.2f%%), uncached reads %0d, writes %0d, DVMA phases %0d",
             cp_hits, cp_miss, st_pc(cp_hits, cp_hits + cp_miss), cp_unc, cp_wr, cp_dvma);
    $display("stats: cpu, read miss latency (cpu_clk):  %s", st_dist(H_CPU_MISS));
    $display("stats:   %s", st_buckets(H_CPU_MISS));
    $display("stats: cpu, uncached read latency:        %s", st_dist(H_CPU_UNC));
    $display("stats: cpu, colour board phases %0d clocks, waiting %0d (%0.2f%% of clocks)",
             cp_cg_phase, cp_cg_wait, st_pc(cp_cg_wait, cp_cyc));
    $display("stats: sdram read wait buckets:%s", st_buckets(H_SD_RD_WAIT));
end
