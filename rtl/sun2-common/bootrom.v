`timescale 1ns / 1ps

`include "sun2_config.vh"
`include "sun2_attr.vh"

`ifdef SUN2_BOOTROM_LOAD
// The PROM as a block RAM that something outside the machine fills -- on
// MiSTer, hps_io from games/Sun-2/boot0.rom at start-up -- so the bitstream
// carries no Sun firmware.  The write port is in the loader's clock; the read
// port is the CPU's and behaves exactly as the compiled-in ROM below does,
// one clock of latency.  The machine is held in reset until the load is done,
// so the two ports are never busy at once.
module bootrom(input CLK,
	       input [13:0] idx,
	       output reg [15:0] dout,
	       input wr_clk,
	       input wr_en,
	       input [13:0] wr_addr,
	       input [15:0] wr_data
	       );

   `SUN2_RAM_BLOCK reg [15:0] mem [0:16383];

   always @(posedge wr_clk)
     if (wr_en) mem[wr_addr] <= wr_data;

   always @(posedge CLK)
     dout <= mem[idx];

endmodule // bootrom

`else
module bootrom(input CLK,
	       input [13:0] idx,
	       output reg [15:0] dout
	       );

  always @(posedge CLK)
    begin
       case(idx)
`include `BOOTROM_FILE
       endcase // case (idx)
    end

endmodule // bootrom
`endif
