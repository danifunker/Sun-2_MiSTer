//============================================================================
//  tb_shifter_equiv -- rtl/patched/rd68011/rd68011_shifter.sv against the
//  upstream rtl/vendor/rd68011/rd68011_shifter.sv it replaces in the build.
//
//  The patched copy changes only how the rotate counts reduce (no `%`), so
//  the two must agree on every output for every input.  The control inputs
//  are covered exhaustively -- every shift kind and direction, every size
//  including the unused fourth, every count, both X -- and the operand by a
//  set of edge patterns plus random values for each.  The Makefile builds the
//  upstream file renamed to rd68011_shifter_ref, so both are in one model.
//
//      make -C tb/verilator tb_shifter_equiv
//============================================================================
`timescale 1ns/1ps

module tb_shifter_equiv;

logic  [2:0] sh;
logic  [1:0] size;
logic  [5:0] count;
logic [31:0] din;
logic        x_in;

logic [31:0] dout_p, dout_r;
logic        c_p, c_r, v_p, v_r, x_p, x_r;

rd68011_shifter     dut (.sh, .size, .count, .din, .x_in,
                         .dout(dout_p), .c_out(c_p), .v_out(v_p), .x_upd(x_p));
rd68011_shifter_ref ref_(.sh, .size, .count, .din, .x_in,
                         .dout(dout_r), .c_out(c_r), .v_out(v_r), .x_upd(x_r));

localparam int NPAT = 10;
localparam logic [31:0] PAT [NPAT] = '{
    32'h0000_0000, 32'hFFFF_FFFF, 32'h8000_0000, 32'h0000_8000, 32'h0000_0080,
    32'h0000_0001, 32'hAAAA_AAAA, 32'h5555_5555, 32'h8000_8080, 32'h7FFF_7F7F};
localparam int NRAND = 24;

int checks = 0, fails = 0;

task automatic check();
    #1;
    checks++;
    if ({dout_p, c_p, v_p, x_p} !== {dout_r, c_r, v_r, x_r}) begin
        fails++;
        if (fails <= 10)
            $display("FAIL  sh=%0d size=%0d count=%0d x=%0d din=%08h: patched %08h c%0d v%0d x%0d, upstream %08h c%0d v%0d x%0d",
                     sh, size, count, x_in, din, dout_p, c_p, v_p, x_p, dout_r, c_r, v_r, x_r);
    end
endtask

initial begin
    for (int s = 0; s < 8; s++)
        for (int z = 0; z < 4; z++)
            for (int n = 0; n < 64; n++)
                for (int x = 0; x < 2; x++) begin
                    sh = s[2:0]; size = z[1:0]; count = n[5:0]; x_in = x[0];
                    for (int p = 0; p < NPAT; p++) begin
                        din = PAT[p];
                        check();
                    end
                    for (int r = 0; r < NRAND; r++) begin
                        din = $urandom;
                        check();
                    end
                end
    $display("tb_shifter_equiv: %0d checks, %0d failed", checks, fails);
    if (fails == 0) $display("PASS"); else $display("FAIL");
    $finish;
end

endmodule
