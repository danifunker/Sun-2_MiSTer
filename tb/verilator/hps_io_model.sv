// A stand-in for sys/hps_io.sv with exactly the ports Sun-2.sv connects, doing
// what Main_MiSTer does for this core:
//
//   +rom=<file>     downloads it at start-up on ioctl index 0, as Main_MiSTer
//                   sends games/Sun-2/boot0.rom
//   +disk=<file>    mounts it as VD 0 and serves sd_rd / sd_wr with the
//                   sequencing of sys/hps_io.sv (sd_ack up with the address
//                   at 0; a byte per sd_buff_wr, the address stepping two
//                   clocks later; sd_buff_din taken, then the address
//                   stepped; sd_ack down at the end).  Writes land in an
//                   overlay and do not touch the file.
//   +tape=<file>    the same for VD 1, the tape (a .qic from tools/mktape)
//   +keys=<text>    typed from +keys_ms=<ms> (default 2000) on, one key about
//                   every 30 ms: a..z 0..9 space and . / - , = ; and their
//                   shifted ( ) : _ + < > ?, plus
//                   '|' for Return, '!' for the abort (Right Alt+F1, A) and
//                   '~' for a half-second pause
//   +status=<hex>   the OSD's status word
`timescale 1ps/1ps

module hps_io #(
    parameter CONF_STR = "",
    parameter VDNUM    = 1
) (
    input  wire        clk_sys,
    inout  wire [45:0] HPS_BUS,
    inout  wire [35:0] EXT_BUS,

    output reg  [1:0]   buttons = 2'b00,
    output reg  [127:0] status  = 128'd0,
    input  wire [15:0]  status_menumask,

    output reg  [10:0] ps2_key   = 11'd0,
    output reg  [24:0] ps2_mouse = 25'd0,

    input  wire [31:0] sd_lba[VDNUM],
    input  wire [VDNUM-1:0] sd_rd,
    input  wire [VDNUM-1:0] sd_wr,
    output reg  [VDNUM-1:0] sd_ack = '0,
    output reg  [13:0] sd_buff_addr = 14'd0,
    output reg  [7:0]  sd_buff_dout = 8'd0,
    input  wire [7:0]  sd_buff_din[VDNUM],
    output reg         sd_buff_wr = 1'b0,
    output reg  [VDNUM-1:0] img_mounted = '0,
    output reg         img_readonly = 1'b0,
    output reg  [63:0] img_size = 64'd0,

    output reg         ioctl_download = 1'b0,
    output reg  [15:0] ioctl_index = 16'd0,
    output reg         ioctl_wr = 1'b0,
    output reg  [26:0] ioctl_addr = 27'd0,
    output reg  [7:0]  ioctl_dout = 8'd0,
    input  wire        ioctl_wait
);

    // ---- start-up: the PROM, then the drives -----------------------------------
    string  rom_file, img_file;
    integer fd, n, c;
    typedef bit [7:0] block_t [512];
    block_t overlay [longint];          // blocks written by the machine, keyed {drive, block}
    integer img_fd    [VDNUM];
    longint img_bytes [VDNUM];
    initial for (int d = 0; d < VDNUM; d++) begin img_fd[d] = 0; img_bytes[d] = 0; end

    initial begin
        logic [127:0] st;
        if ($value$plusargs("status=%h", st)) status = st;
        repeat (200) @(posedge clk_sys);

        if ($value$plusargs("rom=%s", rom_file)) begin
            fd = $fopen(rom_file, "rb");
            if (fd == 0) begin $display("hps_io: cannot open +rom=%s", rom_file); $finish; end
            @(posedge clk_sys);
            ioctl_index    <= 16'd0;
            ioctl_download <= 1'b1;
            n = 0;
            c = $fgetc(fd);
            while (c >= 0) begin
                repeat (3) @(posedge clk_sys);
                ioctl_addr <= 27'(n);
                ioctl_dout <= 8'(c);
                ioctl_wr   <= 1'b1;
                @(posedge clk_sys);
                ioctl_wr   <= 1'b0;
                n++;
                c = $fgetc(fd);
            end
            $fclose(fd);
            repeat (4) @(posedge clk_sys);
            ioctl_download <= 1'b0;
            $display("[%0t] hps_io: sent %0d bytes of %s as boot0.rom", $time, n, rom_file);
        end else
            $display("hps_io: no +rom -- the machine will stay in reset");

        for (int d = 0; d < VDNUM; d++) begin
            bit got;
            if (d == 0) got = $value$plusargs("disk=%s", img_file);
            else        got = $value$plusargs("tape=%s", img_file);
            if (got) begin
                img_fd[d] = $fopen(img_file, "rb");
                if (img_fd[d] == 0) begin $display("hps_io: cannot open %s", img_file); $finish; end
                void'($fseek(img_fd[d], 0, 2));
                img_bytes[d] = $ftell(img_fd[d]);
                repeat (10) @(posedge clk_sys);
                img_size       <= 64'(img_bytes[d]);
                img_mounted[d] <= 1'b1;
                @(posedge clk_sys);
                img_mounted[d] <= 1'b0;
                $display("[%0t] hps_io: mounted %s as VD %0d, %0d bytes", $time, img_file, d, img_bytes[d]);
            end
        end
    end

    // ---- the virtual drives ------------------------------------------------------------
    // One block at a time across all of them, as the HPS serves them.  What
    // the machine writes is kept a block at a time, keyed by drive and block.
    function automatic void read_block(input int d, input longint lba, output block_t blk);
        integer b;
        longint key;
        key = (longint'(d) << 40) | lba;
        if (overlay.exists(key)) begin blk = overlay[key]; return; end
        for (int i = 0; i < 512; i++) blk[i] = 8'h00;
        if (img_fd[d] == 0 || lba * 512 >= img_bytes[d]) return;
        void'($fseek(img_fd[d], lba * 512, 0));
        for (int i = 0; i < 512; i++) begin
            b = $fgetc(img_fd[d]);
            blk[i] = (b < 0) ? 8'h00 : 8'(b);
        end
    endfunction

    initial begin : vdisk
        block_t blk;
        forever begin
            @(posedge clk_sys);
            for (int d = 0; d < VDNUM; d++) if (sd_rd[d] || sd_wr[d]) begin
                bit rd;
                longint lba;
                rd  = sd_rd[d];
                lba = longint'(sd_lba[d]);
                if (rd) read_block(d, lba, blk);
                repeat (40) @(posedge clk_sys);         // the HPS notices
                sd_ack[d]    <= 1'b1;
                sd_buff_addr <= 14'd0;
                for (int i = 0; i < 512; i++) begin
                    repeat (4) @(posedge clk_sys);
                    if (rd) begin
                        sd_buff_dout <= blk[i];
                        @(posedge clk_sys); sd_buff_wr <= 1'b1;
                        @(posedge clk_sys); sd_buff_wr <= 1'b0;
                        @(posedge clk_sys); if (i != 511) sd_buff_addr <= sd_buff_addr + 14'd1;
                    end else begin
                        blk[i] = sd_buff_din[d];
                        if (i != 511) sd_buff_addr <= sd_buff_addr + 14'd1;
                    end
                end
                if (!rd) overlay[(longint'(d) << 40) | lba] = blk;
                repeat (3) @(posedge clk_sys);
                sd_ack[d] <= 1'b0;
                break;
            end
        end
    end

    // ---- the keyboard ------------------------------------------------------------------
    function automatic [8:0] ps2_of(input byte ch);     // {E0, code}
        case (ch)
            "a": ps2_of = 9'h01C; "b": ps2_of = 9'h032; "c": ps2_of = 9'h021; "d": ps2_of = 9'h023;
            "e": ps2_of = 9'h024; "f": ps2_of = 9'h02B; "g": ps2_of = 9'h034; "h": ps2_of = 9'h033;
            "i": ps2_of = 9'h043; "j": ps2_of = 9'h03B; "k": ps2_of = 9'h042; "l": ps2_of = 9'h04B;
            "m": ps2_of = 9'h03A; "n": ps2_of = 9'h031; "o": ps2_of = 9'h044; "p": ps2_of = 9'h04D;
            "q": ps2_of = 9'h015; "r": ps2_of = 9'h02D; "s": ps2_of = 9'h01B; "t": ps2_of = 9'h02C;
            "u": ps2_of = 9'h03C; "v": ps2_of = 9'h02A; "w": ps2_of = 9'h01D; "x": ps2_of = 9'h022;
            "y": ps2_of = 9'h035; "z": ps2_of = 9'h01A;
            "0": ps2_of = 9'h045; "1": ps2_of = 9'h016; "2": ps2_of = 9'h01E; "3": ps2_of = 9'h026;
            "4": ps2_of = 9'h025; "5": ps2_of = 9'h02E; "6": ps2_of = 9'h036; "7": ps2_of = 9'h03D;
            "8": ps2_of = 9'h03E; "9": ps2_of = 9'h046;
            " ": ps2_of = 9'h029; ".": ps2_of = 9'h049; "/": ps2_of = 9'h04A; "-": ps2_of = 9'h04E;
            ",": ps2_of = 9'h041; "=": ps2_of = 9'h055; ";": ps2_of = 9'h04C;
            "|": ps2_of = 9'h05A;                       // Return
            default: ps2_of = 9'h000;
        endcase
    endfunction

    // The characters typed with Shift held, as the unshifted key that makes them.
    function automatic byte shifted(input byte ch);
        case (ch)
            "(": shifted = "9"; ")": shifted = "0"; ":": shifted = ";";
            "_": shifted = "-"; "+": shifted = "="; "<": shifted = ",";
            ">": shifted = "."; "?": shifted = "/";
            default: shifted = 8'h00;
        endcase
    endfunction

    task automatic key_event(input bit press, input [8:0] k);
        begin
            @(posedge clk_sys);
            ps2_key <= {~ps2_key[10], press, k[8], k[7:0]};
            repeat (100_000 * 15) @(posedge clk_sys);   // 15 ms at 100 MHz
        end
    endtask

    initial begin : typist
        string  keys;
        real    keys_ms;
        if (!$value$plusargs("keys_ms=%f", keys_ms)) keys_ms = 2000.0;
        if ($value$plusargs("keys=%s", keys)) begin
            #(longint'(keys_ms * 1.0e9));
            $display("[%0t] hps_io: typing \"%s\"", $time, keys);
            for (int i = 0; i < keys.len(); i++) begin
                if (keys[i] == "~") begin
                    #(longint'(500.0e9));                                       // half a second
                end else if (keys[i] == "!") begin
                    // L1 held while A goes down -- that is the abort; let go
                    // of L1 first and SunOS just sees an `a'.
                    key_event(1, 9'h111); key_event(1, 9'h005);                         // Right Alt+F1: L1
                    key_event(1, 9'h01C); key_event(0, 9'h01C);                         // A
                    key_event(0, 9'h005); key_event(0, 9'h111);
                end else if (shifted(keys[i]) != 8'h00) begin
                    key_event(1, 9'h012);                                       // Left Shift
                    key_event(1, ps2_of(shifted(keys[i])));
                    key_event(0, ps2_of(shifted(keys[i])));
                    key_event(0, 9'h012);
                end else if (ps2_of(keys[i]) != 9'h000) begin
                    key_event(1, ps2_of(keys[i]));
                    key_event(0, ps2_of(keys[i]));
                end
            end
        end
    end

endmodule
