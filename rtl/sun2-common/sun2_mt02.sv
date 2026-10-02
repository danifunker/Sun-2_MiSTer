//
// sun2_mt02.sv
//
// The tape: an Emulex MT-02 SCSI-to-QIC controller and its cartridge drive,
// on the Sun-2 SCSI board's bus beside the disk.  It is what SunOS 4.0.3 is
// installed from -- the PROM boots `b st()', and the miniroot, root and /usr
// come off the same cartridge -- and it reads a tape image through the same
// block seam the disk uses (Wish5380's blk_req_t / blk_rsp_t), so on MiSTer it
// is simply a second virtual disk.
//
// What it has to satisfy is three pieces of Sun software, which disagree:
//
//   * The PROM's st driver (sunos-34-src sun/prom_monitor/msun/sys/sunstand/
//     st.c) was written for the Sysgen SC4000.  It reads 32 KiB at a time
//     until a read returns nothing, asks for SENSE_LENGTH = 16 bytes of sense
//     after any CHECK CONDITION, calls it "sense error" unless exactly 16
//     arrive, and takes end-of-file from the Sysgen's file_mark bit -- bit 0
//     of sense byte 4.
//   * The kernel's st driver (sun/sys/sundev/st.c, streg.h) tells an Emulex
//     from a Sysgen by asking for ST_EMULEX_SENSE_LEN = 11 bytes and seeing
//     whether all of them come back, then reads the Emulex error code in sense
//     byte 8: 0x1C file mark, 0x34 end of media, 0x17 write protected, 0x09 no
//     cartridge.  It sends MODE SELECT with a 13-byte list, never spaces
//     backwards ("backspace file - can't"), and counts on the DMA residue
//     rather than the sense information bytes for a short read.
//   * The SCSI-1 rules for a sequential device, which settle the rest: a READ
//     that meets a file mark moves the blocks before it, ends CHECK CONDITION
//     with the Filemark bit, and leaves the tape positioned after the mark.
//
// So the sense is extended sense with eight additional bytes -- sixteen in
// all, the most the PROM takes and more than the kernel's eleven -- and bit 0
// of byte 4 is always set, which is what makes the PROM see a file mark.
// That is exactly what TME's Emulex MT-02 does (phabrics/tme
// scsi/emulexmt02.c: "the sun2 PROM insists that the fifth byte of the sense
// have its least significant bit set"), and TME is known to install SunOS 4
// on a Sun-2 from tape.  The kernel never reads byte 4: it is the second byte
// of the information field, a residue it takes from the DMA counter instead.
//
// The cartridge is read only.  Writes, file marks and erase answer DATA
// PROTECT, MODE SENSE says write protected, and the image is never written.
//
// ---- The tape image ---------------------------------------------------------
//
// A QIC cartridge is fixed 512-byte blocks in files separated by file marks,
// so an image is the blocks plus a table of where each file starts.  Block 0
// of the image is the table (tools/mktape writes it); everything is
// big-endian 32-bit words:
//
//   word 0, 1     "SUN2", "TAPE"
//   word 2        version, 1
//   word 3        number of volumes, 1..3
//   word 4+32*v   volume v: number of files N, 0..30
//   then          N+1 block numbers in the image: where each file starts,
//                 and where the last one ends
//
// One image can hold every volume of a distribution; `volume_i' (the OSD)
// picks the one in the drive, and changing it is changing the cartridge.  An
// image without the header is taken as a single file -- a raw dump of one
// tape file -- as volume 1.
//
// ---- What is not modelled ---------------------------------------------------
//
// Time: rewinds and spaces are instant.  UNIT ATTENTION: a real MT-02 reports
// one after power-on or a cartridge change; both drivers cope with its
// absence, and the PROM's retry-the-rewind loop exists only for it.
// Disconnection, like scsi_targ: the target keeps the bus for the whole
// command.
//
`timescale 1ns / 1ps

module sun2_mt02 #(
    parameter int CLK_PERIOD_PS = 50000,    // the bus settle delay is counted in clocks
    parameter int TARGET_ID     = 4         // sundev/st.c and the PROM's TAPE_TARGET
) (
    input  wire       clk_i,
    input  wire       rst_i,

    output scsi_t     drive_o,
    // A target never reads back REQ or the phase lines, and parity is not
    // checked, so part of the bus arrives unused.
    /* verilator lint_off UNUSEDSIGNAL */
    input  scsi_t     bus_i,
    /* verilator lint_on UNUSEDSIGNAL */

    output blk_req_t  blk_o,
    input  blk_rsp_t  blk_i,

    input  wire       media_changed_i,      // one clock: an image was mounted or removed
    input  wire [1:0] volume_i              // 0 = volume 1; steady in this clock
);

    // ---------------------------------------------------------------------
    // Codes
    // ---------------------------------------------------------------------
    localparam logic [7:0] C_TEST_UNIT_READY = 8'h00;
    localparam logic [7:0] C_REWIND          = 8'h01;
    localparam logic [7:0] C_REQUEST_SENSE   = 8'h03;
    localparam logic [7:0] C_READ_LIMITS     = 8'h05;
    localparam logic [7:0] C_READ            = 8'h08;
    localparam logic [7:0] C_WRITE           = 8'h0a;
    localparam logic [7:0] C_QIC02           = 8'h0d;   // Emulex: pass a QIC-02 command
    localparam logic [7:0] C_WRITE_FILEMARK  = 8'h10;
    localparam logic [7:0] C_SPACE           = 8'h11;
    localparam logic [7:0] C_INQUIRY         = 8'h12;
    localparam logic [7:0] C_MODE_SELECT     = 8'h15;
    localparam logic [7:0] C_ERASE           = 8'h19;
    localparam logic [7:0] C_MODE_SENSE      = 8'h1a;
    localparam logic [7:0] C_LOAD            = 8'h1b;   // load/unload, retension

    localparam logic [7:0] ST_GOOD  = 8'h00;
    localparam logic [7:0] ST_CHECK = 8'h02;

    localparam logic [3:0] SK_NO_SENSE  = 4'h0;
    localparam logic [3:0] SK_NOT_READY = 4'h2;
    localparam logic [3:0] SK_MEDIUM    = 4'h3;
    localparam logic [3:0] SK_ILLEGAL   = 4'h5;
    localparam logic [3:0] SK_PROTECT   = 4'h7;

    // The Emulex error codes the kernel tests (streg.h).
    localparam logic [7:0] EM_NO_SENSE      = 8'h00;
    localparam logic [7:0] EM_NOT_LOADED    = 8'h09;
    localparam logic [7:0] EM_UNCORRECTABLE = 8'h11;
    localparam logic [7:0] EM_PROTECTED     = 8'h17;
    localparam logic [7:0] EM_FILE_MARK     = 8'h1c;
    localparam logic [7:0] EM_INVALID       = 8'h20;
    localparam logic [7:0] EM_END_OF_MEDIA  = 8'h34;

    localparam logic [7:0] M_COMMAND_COMPLETE = 8'h00;
    localparam logic [7:0] M_ABORT            = 8'h06;
    localparam logic [7:0] M_BUS_DEVICE_RESET = 8'h0c;

    localparam int T_SETTLE = (400_000 + CLK_PERIOD_PS - 1) / CLK_PERIOD_PS;
    localparam int SCNT_W   = $clog2(T_SETTLE + 1);
    localparam logic [SCNT_W-1:0] N_SETTLE = T_SETTLE[SCNT_W-1:0];
    localparam logic [7:0] ID_MASK = 8'(1 << TARGET_ID);

    localparam int MAX_FILES = 30;

    // ---------------------------------------------------------------------
    // The block buffer: one 512-byte block, the back end on one port and the
    // bus (and the header parser) on the other.  Nothing here writes the
    // media, so the bus side only reads.
    // ---------------------------------------------------------------------
    logic [7:0] mem [0:511];
    logic [8:0] a_addr;
    logic [7:0] a_rdata, b_rdata;

    always_ff @(posedge clk_i)
        a_rdata <= mem[a_addr];

    always_ff @(posedge clk_i) begin
        if (blk_i.buf_we) mem[blk_i.buf_addr] <= blk_i.buf_wdata;
        b_rdata <= mem[blk_i.buf_addr];
    end

    // ---------------------------------------------------------------------
    // The file table of the volume in the drive: ftab[f] is where file f
    // starts, ftab[nfiles] where the last one ends.
    // ---------------------------------------------------------------------
    logic [31:0] ftab [0:31];
    logic [4:0]  ftab_ra, ftab_wa;
    logic [31:0] ftab_q, ftab_wd;
    logic        ftab_we;

    always_ff @(posedge clk_i) begin
        if (ftab_we) ftab[ftab_wa] <= ftab_wd;
        ftab_q <= ftab[ftab_ra];
    end

    // ---------------------------------------------------------------------
    // State
    // ---------------------------------------------------------------------
    typedef enum logic [4:0] {
        S_IDLE, S_SELWAIT, S_MSGOUT, S_CMD, S_EXEC,
        S_RDNEXT, S_RDWAIT, S_DATAIN, S_DATAOUT, S_STATUS, S_MSGIN, S_FREE,
        S_HDRWAIT, S_HDRPARSE, S_HDRDONE, S_RAW1,
        S_SEEK0, S_SEEK1, S_SEEK2, S_SEEK3
    } state_t;

    localparam logic [1:0] H_SETUP = 2'd0, H_REQ = 2'd1, H_REL = 2'd2;

    state_t      st;
    logic [1:0]  hs;
    logic [2:0]  phase;              // MSG, C/D, I/O
    logic [SCNT_W-1:0] sel_cnt;

    logic [9:0]  idx, xfer_len;
    // Every command this device knows is six bytes.  A longer one is still
    // taken off the bus whole -- its length is in the opcode's group code --
    // so that the initiator is not cut off half way through sending it; it is
    // then refused.
    logic [47:0] cdb;
    logic [3:0]  cdb_len;
    logic [2:0]  lun;
    logic        atn_seen;
    logic [7:0]  status, msg_rx;

    // The cartridge.
    logic        need_load;          // re-read the table before anything else
    logic        t_valid;            // a volume is in the drive
    logic [1:0]  t_vol;              // ... and which one
    logic [4:0]  t_nfiles;
    logic [4:0]  pos_file;           // the file the tape is in; t_nfiles = past the last mark
    logic [31:0] pos_blk;            // the next block, as a block of the image
    logic [31:0] cur_end;            // where file pos_file ends
    logic        need_seek;          // pos_file moved: refresh pos_blk and cur_end

    // The header, as it streams past.
    logic [31:0] hw;                 // the word being assembled
    logic        h_magic_ok, h_ver_ok, h_vol_ok;
    logic [4:0]  h_nfiles;
    logic        h_nfiles_ok;

    // A READ in progress.
    logic [23:0] blk_left;

    // Sense, for the last command that ended CHECK CONDITION.
    logic        s_valid, s_fm, s_eom;
    logic [3:0]  s_key;
    logic [31:0] s_info;
    logic [7:0]  s_err;

    logic        blk_start;
    logic [31:0] blk_lba;
    // A request is outstanding.  A bus reset can abandon a READ with its block
    // still in flight, and the back end ignores a start while it is busy, so
    // nothing new is asked for until the old one has answered -- otherwise the
    // next wait for `done' would be for a request that was never taken.
    logic        blk_busy;

    always_comb begin
        blk_o.start     = blk_start;
        blk_o.we        = 1'b0;          // read only
        blk_o.lba       = blk_lba;
        blk_o.buf_rdata = b_rdata;
    end

    // ---------------------------------------------------------------------
    // The bus
    // ---------------------------------------------------------------------
    logic connected, drive_bus;
    logic [7:0] data_out;

    // BSY is ours from selection to the end of MESSAGE IN.  Reading the table
    // and seeking happen only while the bus is free.
    assign connected = (st == S_SELWAIT) || (st == S_MSGOUT) || (st == S_CMD) ||
                       (st == S_EXEC)    || (st == S_RDNEXT) || (st == S_RDWAIT) ||
                       (st == S_DATAIN)  || (st == S_DATAOUT) ||
                       (st == S_STATUS)  || (st == S_MSGIN);
    assign drive_bus = connected && phase[0];

    always_comb begin
        drive_o      = '0;
        drive_o.bsy  = connected;
        drive_o.msg  = connected && phase[2];
        drive_o.cd   = connected && phase[1];
        drive_o.io   = connected && phase[0];
        drive_o.req  = connected && (hs == H_REQ);
        drive_o.data = drive_bus ? data_out : 8'h00;
        drive_o.dbp  = drive_bus ? ~(^data_out) : 1'b0;
    end

    // ---------------------------------------------------------------------
    // Generated responses, functions of the byte index
    // ---------------------------------------------------------------------
    localparam logic [2:0] R_NONE = 3'd0, R_MEDIA = 3'd1, R_INQUIRY = 3'd2,
                           R_SENSE = 3'd3, R_MODE = 3'd4, R_LIMITS = 3'd5;
    logic [2:0] resp_kind;


    logic [7:0] resp;
    always_comb begin
        resp = 8'h00;
        case (resp_kind)
            R_INQUIRY:
                // Five bytes: a sequential-access device, and zeroes.  That is
                // TME's MT-02, and it has to be: SunOS 4.0's st driver asks at
                // attach and looks the vendor up in a table whose Emulex entry
                // matches two *zero* bytes (st.c 1.73's drive table, in the
                // MUNIX kernel at 0x8db3a) -- a real MT-02 does not implement
                // INQUIRY and leaves the field empty.  Answering with a vendor
                // name makes it "st0: warning, unknown tape drive found" and
                // the driver falls back to its generic entry.  The device type
                // is still given, because the SunOS 4.1.1 tape bootblock will
                // not boot from a SCSI device that does not say it is a tape.
                resp = (idx == 10'd0) ? ((lun == 3'd0) ? 8'h01 : 8'h7f) : 8'h00;

            R_SENSE:
                case (idx[3:0])
                    4'd0:  resp = {s_valid, 7'h70};
                    4'd2:  resp = {s_fm, s_eom, 2'b00, s_key};
                    4'd3:  resp = s_info[31:24];
                    4'd4:  resp = s_info[23:16] | 8'h01;    // the PROM's file mark bit
                    4'd5:  resp = s_info[15:8];
                    4'd6:  resp = s_info[7:0];
                    4'd7:  resp = 8'd8;                     // eight more: sixteen in all
                    4'd8:  resp = s_err;
                    default: resp = 8'h00;                  // retry counts, reserved
                endcase

            R_MODE:
                // Header and one block descriptor: write protected, buffered,
                // QIC-24, 512-byte blocks.
                case (idx[3:0])
                    4'd0:  resp = 8'd11;
                    4'd2:  resp = 8'h90;
                    4'd3:  resp = 8'd8;
                    4'd4:  resp = 8'h05;
                    4'd10: resp = 8'h02;
                    default: resp = 8'h00;
                endcase

            R_LIMITS:
                // READ BLOCK LIMITS: 512 bytes, no more and no less.
                case (idx[2:0])
                    3'd2: resp = 8'h02;
                    3'd4: resp = 8'h02;
                    default: resp = 8'h00;
                endcase

            default: resp = 8'h00;
        endcase
    end

    always_comb begin
        case (st)
            S_STATUS: data_out = status;
            S_MSGIN:  data_out = M_COMMAND_COMPLETE;
            default:  data_out = (resp_kind == R_MEDIA) ? a_rdata : resp;
        endcase
    end

    assign a_addr = idx[8:0];

    // ---------------------------------------------------------------------
    // Command decode
    // ---------------------------------------------------------------------
    logic [7:0]  op;
    logic [9:0]  alloc_len;
    logic [23:0] cdb_count;          // bytes 2..4: blocks, or a signed space count
    logic [1:0]  space_code;
    assign op         = cdb[7:0];
    assign alloc_len  = {2'd0, cdb[39:32]};
    assign cdb_count  = {cdb[23:16], cdb[31:24], cdb[39:32]};
    assign space_code = cdb[9:8];

    // Spacing: how far file marks can go before the end of the recorded
    // tape, and how far blocks can go before the end of this file.
    logic [24:0] files_ahead;
    logic [31:0] blocks_ahead;
    assign files_ahead  = {20'd0, t_nfiles} - {20'd0, pos_file};
    assign blocks_ahead = cur_end - pos_blk;

    logic [3:0] len_of_op;
    always_comb
        case (bus_i.data[7:5])
            3'd1, 3'd2: len_of_op = 4'd10;
            3'd5:       len_of_op = 4'd12;
            default:    len_of_op = 4'd6;
        endcase

    logic sel_match;
    assign sel_match = bus_i.sel && !bus_i.bsy && !bus_i.io &&
                       ((bus_i.data & ID_MASK) != 8'h00);

    // The table as it streams past: the byte arriving now is idx-1's, and
    // every fourth one completes a big-endian word.  Volume v's entries are
    // words 4+32v .. 4+32v+31.
    logic [8:0]  h_p;
    logic [31:0] h_w;
    logic [6:0]  h_wi, h_base;
    assign h_p    = idx[8:0] - 9'd1;
    assign h_w    = {hw[23:0], a_rdata};
    assign h_wi   = h_p[8:2];
    assign h_base = 7'd4 + {t_vol, 5'd0};

    // ---------------------------------------------------------------------
    // The sequencer
    // ---------------------------------------------------------------------
    task automatic check_cond(input logic [3:0] key, input logic [7:0] err);
        status  <= ST_CHECK;
        s_key   <= key;
        s_err   <= err;
        s_valid <= 1'b0;
        s_fm    <= 1'b0;
        s_eom   <= 1'b0;
        s_info  <= 32'd0;
    endtask


    always_ff @(posedge clk_i) begin
        if (rst_i) begin
            st        <= S_IDLE;
            hs        <= H_SETUP;
            phase     <= 3'b000;
            sel_cnt   <= '0;
            idx       <= '0;
            xfer_len  <= '0;
            cdb       <= '0;
            lun       <= '0;
            atn_seen  <= 1'b0;
            status    <= ST_GOOD;
            msg_rx    <= '0;
            resp_kind <= R_NONE;
            need_load <= 1'b1;
            t_valid   <= 1'b0;
            t_vol     <= 2'd0;
            t_nfiles  <= '0;
            pos_file  <= '0;
            pos_blk   <= '0;
            cur_end   <= '0;
            need_seek <= 1'b0;
            blk_left  <= '0;
            blk_start <= 1'b0;
            blk_lba   <= '0;
            blk_busy  <= 1'b0;
            cdb_len   <= 4'd6;
            ftab_we   <= 1'b0;
            ftab_ra   <= '0;
            ftab_wa   <= '0;
            ftab_wd   <= '0;
            hw        <= '0;
            h_magic_ok <= 1'b0;
            h_ver_ok   <= 1'b0;
            h_vol_ok   <= 1'b0;
            h_nfiles   <= '0;
            h_nfiles_ok <= 1'b0;
            s_valid   <= 1'b0;
            s_fm      <= 1'b0;
            s_eom     <= 1'b0;
            s_key     <= SK_NO_SENSE;
            s_info    <= '0;
            s_err     <= EM_NO_SENSE;
        end else begin
            blk_start <= 1'b0;
            ftab_we   <= 1'b0;
            if (blk_i.done) blk_busy <= 1'b0;

            // A new image, or a different volume asked for, is a different
            // cartridge: read its table again before answering anything.
            if (media_changed_i) need_load <= 1'b1;

            if (bus_i.rst && connected) begin
                // A bus reset ends the command and drops the bus.  The tape
                // stays where it is.
                st    <= S_IDLE;
                hs    <= H_SETUP;
                phase <= 3'b000;
                sel_cnt <= '0;
            end else begin
                case (st)
                    // ---- bus free ----------------------------------------
                    //
                    // Housekeeping first, while nobody owns the bus: loading a
                    // table and finishing a seek both happen here, so no
                    // command ever has to wait on the file table in the
                    // middle of a phase.  A selection meanwhile simply waits.
                    S_IDLE: begin
                        phase <= 3'b000;
                        if (need_load || volume_i != t_vol) begin
                            sel_cnt <= '0;
                            if (!blk_busy) begin
                                need_load <= 1'b0;
                                t_vol     <= volume_i;
                                t_valid   <= 1'b0;
                                pos_file  <= '0;
                                need_seek <= 1'b0;
                                if (blk_i.ready) begin
                                    blk_lba   <= 32'd0;
                                    blk_start <= 1'b1;
                                    blk_busy  <= 1'b1;
                                    st        <= S_HDRWAIT;
                                end
                            end
                        end else if (need_seek) begin
                            need_seek <= 1'b0;
                            sel_cnt   <= '0;
                            st        <= S_SEEK0;
                        end else if (sel_match) begin
                            if (sel_cnt == N_SETTLE) begin
                                st       <= S_SELWAIT;
                                atn_seen <= bus_i.atn;
                                lun      <= '0;
                                status   <= ST_GOOD;
                                idx      <= '0;
                            end else
                                sel_cnt <= sel_cnt + 1'b1;
                        end else
                            sel_cnt <= '0;
                    end

                    // ---- reading the table ---------------------------------
                    S_HDRWAIT:
                        if (blk_i.done) begin
                            if (blk_i.err) st <= S_IDLE;      // no tape, then
                            else begin
                                idx         <= '0;
                                h_magic_ok  <= 1'b1;
                                h_ver_ok    <= 1'b0;
                                h_vol_ok    <= 1'b0;
                                h_nfiles_ok <= 1'b0;
                                st          <= S_HDRPARSE;
                            end
                        end

                    // One byte a clock, the buffer's read a clock behind the
                    // address: the byte in a_rdata is idx-1's.
                    S_HDRPARSE: begin
                        idx <= idx + 10'd1;
                        if (idx != 10'd0) begin
                            hw <= h_w;
                            if (h_p[1:0] == 2'd3) begin
                                case (h_wi)
                                    7'd0: if (h_w != "SUN2") h_magic_ok <= 1'b0;
                                    7'd1: if (h_w != "TAPE") h_magic_ok <= 1'b0;
                                    7'd2: h_ver_ok <= (h_w == 32'd1);
                                    7'd3: h_vol_ok <= (h_w > {30'd0, t_vol}) && (h_w <= 32'd3);
                                    default: ;
                                endcase
                                if (h_wi == h_base) begin
                                    h_nfiles    <= h_w[4:0];
                                    h_nfiles_ok <= (h_w <= MAX_FILES);
                                end else if (h_wi > h_base && {1'b0, h_wi} <= {1'b0, h_base} + 8'd31) begin
                                    ftab_we <= 1'b1;
                                    ftab_wa <= 5'(h_wi - h_base - 7'd1);
                                    ftab_wd <= h_w;
                                end
                            end
                        end
                        if (idx == 10'd512) st <= S_HDRDONE;
                    end

                    S_HDRDONE: begin
                        if (h_magic_ok) begin
                            t_valid  <= h_ver_ok && h_vol_ok && h_nfiles_ok;
                            t_nfiles <= h_nfiles;
                            st       <= S_SEEK0;
                        end else if (t_vol == 2'd0) begin
                            // No table: the whole image is one file.
                            t_valid  <= 1'b1;
                            t_nfiles <= 5'd1;
                            ftab_we  <= 1'b1;
                            ftab_wa  <= 5'd0;
                            ftab_wd  <= 32'd0;
                            st       <= S_RAW1;
                        end else
                            st <= S_IDLE;
                    end

                    S_RAW1: begin
                        ftab_we  <= 1'b1;
                        ftab_wa  <= 5'd1;
                        ftab_wd  <= blk_i.count;
                        st       <= S_SEEK0;
                    end

                    // ---- seek: pos_blk and cur_end from pos_file -----------
                    S_SEEK0: begin ftab_ra <= pos_file;        st <= S_SEEK1; end
                    S_SEEK1: begin ftab_ra <= pos_file + 5'd1; st <= S_SEEK2; end
                    S_SEEK2: begin pos_blk <= ftab_q;          st <= S_SEEK3; end
                    S_SEEK3: begin cur_end <= ftab_q;          st <= S_IDLE;   end

                    // ---- selected ------------------------------------------
                    S_SELWAIT: begin
                        if (bus_i.atn) atn_seen <= 1'b1;
                        if (!bus_i.sel) begin
                            hs    <= H_SETUP;
                            idx   <= '0;
                            phase <= (bus_i.atn || atn_seen) ? 3'b110 : 3'b010;
                            st    <= (bus_i.atn || atn_seen) ? S_MSGOUT : S_CMD;
                        end
                    end

                    // ---- message out ---------------------------------------
                    // Sun-2 has no ATN driver, but a target is not allowed to
                    // choke on one.
                    S_MSGOUT:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) begin
                                hs     <= H_REL;
                                msg_rx <= bus_i.data;
                                if (bus_i.data[7]) lun <= bus_i.data[2:0];
                            end
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (msg_rx == M_ABORT || msg_rx == M_BUS_DEVICE_RESET)
                                    st <= S_FREE;
                                else if (!bus_i.atn) begin
                                    idx   <= '0;
                                    phase <= 3'b010;
                                    st    <= S_CMD;
                                end
                            end
                        endcase

                    // ---- command -------------------------------------------
                    S_CMD:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) begin
                                hs <= H_REL;
                                if (idx < 10'd6) cdb[8*idx[2:0] +: 8] <= bus_i.data;
                                if (idx == 10'd0) cdb_len <= len_of_op;
                                if (idx == 10'd1 && !atn_seen) lun <= bus_i.data[7:5];
                            end
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (idx + 10'd1 == {6'd0, cdb_len}) begin
                                    idx <= '0;
                                    st  <= S_EXEC;
                                end else
                                    idx <= idx + 10'd1;
                            end
                        endcase

                    // ---- what the command means ----------------------------
                    S_EXEC: begin
                        hs        <= H_SETUP;
                        idx       <= '0;
                        resp_kind <= R_NONE;
                        status    <= ST_GOOD;
                        st        <= S_STATUS;
                        phase     <= 3'b011;
                        // Sense describes the command before this one; every
                        // command but REQUEST SENSE starts it afresh.
                        if (op != C_REQUEST_SENSE) begin
                            s_valid <= 1'b0; s_fm <= 1'b0; s_eom <= 1'b0;
                            s_key   <= SK_NO_SENSE; s_info <= '0; s_err <= EM_NO_SENSE;
                        end

                        if (cdb_len != 4'd6)
                            check_cond(SK_ILLEGAL, EM_INVALID);
                        else if (lun != 3'd0 && op != C_INQUIRY && op != C_REQUEST_SENSE)
                            check_cond(SK_ILLEGAL, EM_INVALID);
                        else case (op)
                            C_INQUIRY: begin
                                resp_kind <= R_INQUIRY;
                                xfer_len  <= (alloc_len < 10'd5) ? alloc_len : 10'd5;
                                if (alloc_len != 10'd0) begin phase <= 3'b001; st <= S_DATAIN; end
                            end

                            C_REQUEST_SENSE: begin
                                // An allocation of zero means four bytes here,
                                // as SCSI-1 and TME both have it.
                                resp_kind <= R_SENSE;
                                xfer_len  <= (alloc_len == 10'd0) ? 10'd4 :
                                             (alloc_len < 10'd16) ? alloc_len : 10'd16;
                                phase     <= 3'b001;
                                st        <= S_DATAIN;
                            end

                            C_MODE_SENSE: begin
                                resp_kind <= R_MODE;
                                xfer_len  <= (alloc_len < 10'd12) ? alloc_len : 10'd12;
                                if (alloc_len != 10'd0) begin phase <= 3'b001; st <= S_DATAIN; end
                            end

                            C_READ_LIMITS: begin
                                resp_kind <= R_LIMITS;
                                xfer_len  <= 10'd6;
                                phase     <= 3'b001;
                                st        <= S_DATAIN;
                            end

                            // Taken and thrown away: the density and buffering
                            // it sets change nothing about reading an image.
                            C_MODE_SELECT:
                                if (alloc_len != 10'd0) begin
                                    xfer_len <= alloc_len;
                                    phase    <= 3'b000;
                                    st       <= S_DATAOUT;
                                end

                            C_QIC02: ;

                            C_TEST_UNIT_READY:
                                if (!t_valid) check_cond(SK_NOT_READY, EM_NOT_LOADED);

                            C_REWIND, C_LOAD:
                                if (!t_valid) check_cond(SK_NOT_READY, EM_NOT_LOADED);
                                else begin
                                    pos_file  <= '0;
                                    need_seek <= 1'b1;
                                end

                            C_WRITE, C_WRITE_FILEMARK, C_ERASE:
                                if (!t_valid) check_cond(SK_NOT_READY, EM_NOT_LOADED);
                                else          check_cond(SK_PROTECT, EM_PROTECTED);

                            C_READ:
                                if (!t_valid) check_cond(SK_NOT_READY, EM_NOT_LOADED);
                                else if (cdb_count != 24'd0) begin
                                    // The MT-02 treats every READ as fixed-block,
                                    // whatever bit 0 of byte 1 says.
                                    blk_left  <= cdb_count;
                                    resp_kind <= R_MEDIA;
                                    phase     <= 3'b001;
                                    st        <= S_RDNEXT;
                                end

                            C_SPACE:
                                if (!t_valid) check_cond(SK_NOT_READY, EM_NOT_LOADED);
                                else if (cdb_count == 24'd0) ;
                                else if (cdb_count[23] || space_code[1])
                                    // Backwards, or to end of data: a QIC drive
                                    // cannot, and no Sun driver asks.
                                    check_cond(SK_ILLEGAL, EM_INVALID);
                                else if (space_code[0]) begin
                                    // File marks.
                                    if ({1'b0, cdb_count} > files_ahead) begin
                                        pos_file <= t_nfiles;
                                        check_cond(SK_NO_SENSE, EM_END_OF_MEDIA);
                                        s_eom   <= 1'b1;
                                        s_valid <= 1'b1;
                                        s_info  <= 32'({1'b0, cdb_count} - files_ahead);
                                    end else
                                        pos_file <= pos_file + cdb_count[4:0];
                                    need_seek <= 1'b1;
                                end else begin
                                    // Blocks, which stop at a file mark.
                                    if (pos_file >= t_nfiles) begin
                                        check_cond(SK_NO_SENSE, EM_END_OF_MEDIA);
                                        s_eom   <= 1'b1;
                                        s_valid <= 1'b1;
                                        s_info  <= {8'd0, cdb_count};
                                    end else if ({8'd0, cdb_count} <= blocks_ahead)
                                        pos_blk <= pos_blk + {8'd0, cdb_count};
                                    else begin
                                        pos_file  <= pos_file + 5'd1;
                                        need_seek <= 1'b1;
                                        check_cond(SK_NO_SENSE, EM_FILE_MARK);
                                        s_fm    <= 1'b1;
                                        s_valid <= 1'b1;
                                        s_info  <= {8'd0, cdb_count} - blocks_ahead;
                                    end
                                end

                            default: check_cond(SK_ILLEGAL, EM_INVALID);
                        endcase
                    end

                    // ---- READ, a block at a time -----------------------------
                    //
                    // The DATA IN phase is held from here to the last block,
                    // REQ simply stopping while the back end fetches: see
                    // scsi_targ.sv on what a phase change in the middle of a
                    // transfer does to an initiator.
                    S_RDNEXT:
                        if (blk_left == 24'd0) begin
                            phase <= 3'b011;
                            st    <= S_STATUS;
                        end else if (pos_file >= t_nfiles) begin
                            // Past the last file mark: blank tape.
                            check_cond(SK_NO_SENSE, EM_END_OF_MEDIA);
                            s_eom   <= 1'b1;
                            s_valid <= 1'b1;
                            s_info  <= {8'd0, blk_left};
                            phase   <= 3'b011;
                            st      <= S_STATUS;
                        end else if (pos_blk == cur_end) begin
                            // The file mark: the read stops short of it and the
                            // tape is left on the far side.  pos_blk is already
                            // the next file's first block; cur_end follows it
                            // when the bus is free.
                            check_cond(SK_NO_SENSE, EM_FILE_MARK);
                            s_fm      <= 1'b1;
                            s_valid   <= 1'b1;
                            s_info    <= {8'd0, blk_left};
                            pos_file  <= pos_file + 5'd1;
                            need_seek <= 1'b1;
                            phase     <= 3'b011;
                            st        <= S_STATUS;
                        end else if (!blk_busy) begin
                            blk_lba   <= pos_blk;
                            blk_start <= 1'b1;
                            blk_busy  <= 1'b1;
                            st        <= S_RDWAIT;
                        end

                    S_RDWAIT:
                        if (blk_i.done) begin
                            if (blk_i.err) begin
                                check_cond(SK_MEDIUM, EM_UNCORRECTABLE);
                                s_valid <= 1'b1;
                                s_info  <= {8'd0, blk_left};
                                phase   <= 3'b011;
                                st      <= S_STATUS;
                            end else begin
                                idx      <= '0;
                                xfer_len <= 10'd512;
                                hs       <= H_SETUP;
                                st       <= S_DATAIN;
                            end
                        end

                    // ---- data in -------------------------------------------
                    S_DATAIN:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (idx + 10'd1 == xfer_len) begin
                                    idx <= '0;
                                    if (resp_kind == R_MEDIA) begin
                                        pos_blk  <= pos_blk + 32'd1;
                                        blk_left <= blk_left - 24'd1;
                                        st       <= S_RDNEXT;
                                    end else begin
                                        phase <= 3'b011;
                                        st    <= S_STATUS;
                                    end
                                end else
                                    idx <= idx + 10'd1;
                            end
                        endcase

                    // ---- data out: MODE SELECT's list, discarded -------------
                    S_DATAOUT:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                if (idx + 10'd1 == xfer_len) begin
                                    idx   <= '0;
                                    phase <= 3'b011;
                                    st    <= S_STATUS;
                                end else
                                    idx <= idx + 10'd1;
                            end
                        endcase

                    // ---- status, message in, bus free ------------------------
                    S_STATUS:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs    <= H_SETUP;
                                phase <= 3'b111;
                                st    <= S_MSGIN;
                            end
                        endcase

                    S_MSGIN:
                        case (hs)
                            H_SETUP: hs <= H_REQ;
                            H_REQ: if (bus_i.ack) hs <= H_REL;
                            default: if (!bus_i.ack) begin
                                hs <= H_SETUP;
                                st <= S_FREE;
                                // Retrieving the sense is what consumes it.
                                if (op == C_REQUEST_SENSE) begin
                                    s_valid <= 1'b0; s_fm <= 1'b0; s_eom <= 1'b0;
                                    s_key   <= SK_NO_SENSE; s_info <= '0; s_err <= EM_NO_SENSE;
                                end
                            end
                        endcase

                    default: begin          // S_FREE
                        hs      <= H_SETUP;
                        phase   <= 3'b000;
                        sel_cnt <= '0;
                        msg_rx  <= '0;
                        st      <= S_IDLE;
                    end
                endcase
            end
        end
    end

`ifdef SIMULATION
    // +trace_tape: every command, where the tape was, and how it ended.
    bit       trace;
    integer   moved;
    initial trace = $test$plusargs("trace_tape");
    always @(posedge clk_i) if (trace && !rst_i) begin
        if (st == S_CMD && hs == H_REQ && bus_i.ack && idx == 10'd0) moved = 0;
        if ((st == S_DATAIN || st == S_DATAOUT) && hs == H_REQ && bus_i.ack) moved = moved + 1;
        if (st == S_EXEC)
            $display("[%0t] st0: cdb %02x %02x %02x %02x %02x %02x (%0d bytes), file %0d of %0d, block %0d",
                     $time, cdb[7:0], cdb[15:8], cdb[23:16], cdb[31:24], cdb[39:32], cdb[47:40],
                     cdb_len, pos_file, t_nfiles, pos_blk);
        if (st == S_STATUS && hs == H_REQ && bus_i.ack)
            $display("[%0t] st0:   status %02x, %0d data bytes; sense key %h err %02x fm %b eom %b info %0d",
                     $time, status, moved, s_key, s_err, s_fm, s_eom, s_info);
        if (st == S_HDRDONE)
            $display("[%0t] st0: table read: magic %b version %b volume %b, %0d files",
                     $time, h_magic_ok, h_ver_ok, h_vol_ok, h_nfiles);
    end
`endif

endmodule
