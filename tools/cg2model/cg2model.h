/*
 * cg2model -- the Sun-2 Color board (cgtwo) as SunOS's software assumes it.
 *
 * This is the specification the RTL is tested against.  No manual for the
 * board or its raster-op chips has been found, so every rule here is derived
 * from the software that drives them and cited in cg2model.c and
 * doc/cgtwo.md.  Where the software never exercises a behaviour the model
 * says so instead of guessing quietly.
 *
 * The model is a bus slave: the 4 MiB VME A24 window, addressed by the
 * board-relative byte offset, with the 68010's 16-bit data bus and its two
 * byte strobes.  A byte write carries its byte on both halves of the bus,
 * as the 68010 does.
 */
#ifndef CG2MODEL_H
#define CG2MODEL_H

#include <stdint.h>

#define CG2_W		1152
#define CG2_H		900
#define CG2_PIXELS	(1 << 20)	/* 8 planes x 128 KiB: 910 lines of 1152 */

/* board offsets (cg2reg.h struct cg2memfb / struct cg2fb) */
#define CG2_PLANE_BASE	0x000000	/* 8 x 0x20000, a 16-bit word = 16 pixels */
#define CG2_PIXEL_BASE	0x100000	/* a byte a pixel */
#define CG2_ROP_BASE	0x200000	/* the same memory through the rop units */
#define CG2_ROPC_BASE	0x300000	/* 9 units x 4 KiB, prime copies at +0x800 */
#define CG2_STATUS	0x309000
#define CG2_PPMASK	0x30a000
#define CG2_WORDPAN	0x30b000
#define CG2_ZOOM	0x30c000
#define CG2_PIXPAN	0x30d000
#define CG2_VARZOOM	0x30e000
#define CG2_INTVEC	0x30f000
#define CG2_CMAP	0x310000	/* red, green, blue: 256 halfwords each */
#define CG2_SIZE	0x400000

/* status register bits (struct cg2statusreg, big-endian bitfields) */
#define CG2S_VIDEO_EN	0x0001
#define CG2S_UPDATE_CMAP 0x0002
#define CG2S_INTEN	0x0004
#define CG2S_ROPMODE	0x0038
#define CG2S_INPEND	0x0040	/* read only */
#define CG2S_RETRACE	0x0080	/* read only */
#define CG2S_RES	0x0f00	/* read only: 0 = 1152x900 */
#define CG2S_WRITABLE	(CG2S_VIDEO_EN | CG2S_UPDATE_CMAP | CG2S_INTEN | CG2S_ROPMODE)

/* rop modes (cg2reg.h) */
enum { PRWWRD, SRWPIX, PWWWRD, SWWPIX, PRRWRD, PRWPIX, PWRWRD, PWWPIX };

/* memropc register indices (memreg.h), 16 halfwords per unit */
enum {
	MRC_DEST, MRC_SOURCE1, MRC_SOURCE2, MRC_PATTERN, MRC_MASK1, MRC_MASK2,
	MRC_SHIFT, MRC_OP, MRC_WIDTH, MRC_OPCOUNT, MRC_DECODEROUT,
	MRC_X11, MRC_X12, MRC_X13, MRC_X14, MRC_X15, MRC_NREGS
};

/* bus strobes */
#define CG2_UDS	2	/* D15..D8, the even byte */
#define CG2_LDS	1	/* D7..D0, the odd byte */

struct cg2_unit {			/* one raster-op unit, one bit plane */
	uint16_t r[MRC_NREGS];
};

struct cg2 {
	uint8_t pix[CG2_PIXELS];	/* chunky: pixel n = y * 1152 + x */
	struct cg2_unit u[8];
	uint16_t status;		/* writable bits only; see cg2_read */
	uint8_t ppmask;
	uint16_t wordpan, zoom, pixpan, varzoom, intvec;
	uint8_t shadow[3][256];		/* the TTL map the CPU reaches */
	uint8_t active[3][256];		/* the ECL map the DACs use */
	int retrace;			/* level, from the display */
	int inpend;
	/* statistics, for the harness */
	unsigned long nwarn;
	void (*warn)(struct cg2 *, const char *);
};

void cg2_reset(struct cg2 *);
/* size: 1 or 2 bytes; strobes: CG2_UDS/CG2_LDS.  A word access has both. */
uint16_t cg2_read(struct cg2 *, uint32_t off, int strobes);
void cg2_write(struct cg2 *, uint32_t off, int strobes, uint16_t data);
/* vertical retrace: 1 at its leading edge, 0 at its trailing edge */
void cg2_retrace(struct cg2 *, int level);
/* interrupt request (level 4, vector from CG2_INTVEC) */
int cg2_irq(const struct cg2 *);

#endif
