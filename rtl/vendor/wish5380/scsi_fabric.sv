// SPDX-License-Identifier: MIT
//
// The wired-OR that joins the devices on the internal SCSI bus.
//
// A real SCSI bus is open collector and active low: every device pulls the
// lines it wants to assert, and everybody - including the device doing the
// pulling - reads the OR of all of them.  There are no pads here, so the
// signals are carried active high and the wired-OR becomes a plain OR, which
// is the same function with the inversion taken out.  `doc/interface.md`
// argues why nothing above this layer can tell the difference.
//
// That a device sees its own contribution is the part of this that matters
// and is easy to lose.  Both reference drivers depend on it: after
// arbitration they read BSY back out of the Current SCSI Bus Status Register
// and it is true because this chip is the one asserting it.
//
// Four ports: the chip, two SD-backed targets, and one spare.  The spare is
// what the testbench drives to stand in for another device, and is tied to
// zero in the real top level - a device driving nothing is a device that is
// not there, which is exactly what an open-collector bus means by it, and it
// is how the second target is switched off when a board carries one drive.

module scsi_fabric (
  input  scsi_t a_i,
  input  scsi_t b_i,
  input  scsi_t c_i,
  input  scsi_t d_i,
  output scsi_t bus_o
);

  // A packed struct is a bit vector, so the whole wired-OR is one operator.
  // Parity comes out of it like everything else rather than being recomputed,
  // which is what lets a test drive deliberately bad parity at a chip with
  // ENABLE PARITY CHECKING set: with one device driving - the only case the
  // protocol allows during an information transfer - the OR is that device's
  // bit unchanged.
  assign bus_o = a_i | b_i | c_i | d_i;

endmodule
