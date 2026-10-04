`timescale 1ns / 1ps

`include "sun2_config.vh"

//
// The 32-byte ID PROM: machine type, Ethernet address, manufacturing date,
// serial number and a checksum, one byte per 2 KiB page of the control space.
//
// Layout and checksum rule from the Architecture Manual section 4.2:
//
//     0       format, 1 for now
//     1       machine type -- 1 = MultiBus, 2 = VME (the 2/50 board is
//             "Machine Type 2", see the manual's chapter 9)
//     2-7     Ethernet address
//     8-11    date, seconds since 1 January 1970
//     12-14   serial number
//     15      checksum, "defined such that the longitudinal XOR of the first
//             16 bytes of the PROM including the checksum yields 0"
//     16-31   reserved
//
// The checksum is computed here rather than written down.  It was previously a
// literal, which is a trap: changing the machine type alone leaves the PROM
// self-inconsistent, and the boot PROM answers with "ID PROM INVALID" -- the
// same complaint whether the type is wrong or the checksum is.
//
// With SUN2_IDPROM_LOAD the 32 bytes are a memory that starts out holding
// exactly these and that something outside the machine may overwrite: on
// MiSTer, hps_io with games/Sun-2/boot1.rom, or with the image Main_MiSTer's
// Sun-2 support makes from the host's own Ethernet address.  That is how two
// machines on one network get two addresses -- and two serial numbers, which
// is SunOS's hostid.  Whatever is written is taken as it is, checksum
// included.  The write port is in the loader's clock and the read port the
// CPU's; nothing is written once the machine is running, and the boot PROM
// first reads the ID PROM after its memory test, seconds after reset, so the
// two never meet.
//
module idprom(input CLK,
	      input [4:0]	 idx,
	      output reg [7:0] dout
`ifdef SUN2_IDPROM_LOAD
	      , input wr_clk,
	      input 		 wr_en,
	      input [4:0] 	 wr_addr,
	      input [7:0] 	 wr_data
`endif
	      );

   localparam [7:0] FORMAT  = 8'h01;
   localparam [7:0] MACHINE = `IDPROM_MACHINE_TYPE;

   // 8:0:20:1:6:e0, from sun2_config.vh, which is where it lives now that the
   // 3C400's address ROM wants the same six bytes.  Nothing else has to change
   // -- CKSUM below is computed, not written down, which is exactly the trap
   // the comment above warns about.
   localparam [39:0] ETH_HI = `SUN2_IDPROM_ETH_HI;
   localparam [7:0] ETH0 = ETH_HI[39:32], ETH1 = ETH_HI[31:24];
   localparam [7:0] ETH2 = ETH_HI[23:16], ETH3 = ETH_HI[15:8];
   localparam [7:0] ETH4 = ETH_HI[7:0];
   localparam [7:0] ETH5 = `SUN2_IDPROM_ETH5;

   localparam [7:0] DATE0 = 8'h1a, DATE1 = 8'he4, DATE2 = 8'h23, DATE3 = 8'h3b;

   // serial #3442
   localparam [7:0] SER0 = 8'h00, SER1 = 8'h0d, SER2 = 8'h72;

   localparam [7:0] CKSUM = FORMAT ^ MACHINE ^
                            ETH0 ^ ETH1 ^ ETH2 ^ ETH3 ^ ETH4 ^ ETH5 ^
                            DATE0 ^ DATE1 ^ DATE2 ^ DATE3 ^
                            SER0 ^ SER1 ^ SER2;

   function [7:0] contents(input [4:0] i);
     case (i)
       5'h00: contents = FORMAT;
       5'h01: contents = MACHINE;
       5'h02: contents = ETH0;
       5'h03: contents = ETH1;
       5'h04: contents = ETH2;
       5'h05: contents = ETH3;
       5'h06: contents = ETH4;
       5'h07: contents = ETH5;
       5'h08: contents = DATE0;
       5'h09: contents = DATE1;
       5'h0a: contents = DATE2;
       5'h0b: contents = DATE3;
       5'h0c: contents = SER0;
       5'h0d: contents = SER1;
       5'h0e: contents = SER2;
       5'h0f: contents = CKSUM;
       default: contents = 8'hff; // reserved (16 bytes)
     endcase
   endfunction

`ifdef SUN2_IDPROM_LOAD
   reg [7:0] mem [0:31];
   integer   k;
   initial
     for (k = 0; k < 32; k = k + 1) mem[k] = contents(k);

   always @(posedge wr_clk)
     if (wr_en) mem[wr_addr] <= wr_data;

   always @(posedge CLK)
     dout <= mem[idx];
`else
   always @(posedge CLK)
     dout <= contents(idx);
`endif
endmodule
