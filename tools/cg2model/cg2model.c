/*
 * cg2model -- the Sun-2 Color board (cgtwo), as a C model.
 *
 * Sources, cited by tag below (all SunOS; nothing here is copied from them):
 *   [reg]   pixrect/cg2reg.h, pixrect/memreg.h -- identical in 4.0 (tape)
 *           and 4.1.4 apart from the SCCS line
 *   [rop]   libpixrect cg2_rop.c          [stn] cg2_stencil.c
 *   [bat]   cg2_batch.c                   [vec] cg2_vec.c
 *   [gp]    cg2_getput.c, cg2_polypoint.c [cm]  cg2_colormap.c
 *   [pl]    the 1985 cg2_polyline.c (Attic in the 4.1.4 tree)
 *   [k34]   sys/sundev/cgtwo.c from 3.4   [k40] cgtwo.o from the 4.0 tape
 *   [prom]  the Rev Q PROM's init_scolor, doc/prom/README.md
 *   [x]     Sprite's X11R4 sunCG2C.c / sunCG2M.c
 * doc/cgtwo.md has the argument for each rule; this file is the rule.
 */
#include <string.h>
#include "cg2model.h"

#define SRC1	MRC_SOURCE1
#define SRC2	MRC_SOURCE2

static void warn(struct cg2 *g, const char *msg)
{
	g->nwarn++;
	if (g->warn)
		g->warn(g, msg);
}

void cg2_reset(struct cg2 *g)
{
	void (*w)(struct cg2 *, const char *) = g->warn;

	memset(g, 0, sizeof *g);
	g->warn = w;
	/*
	 * The PROM draws its console into plane 0 without touching the plane
	 * mask [prom], and the mask gates plain writes too (see cg2_write), so
	 * it has to come up enabled.
	 */
	g->ppmask = 0xff;
}

/* ---- the memory, seen as bit planes --------------------------------- */

/* plane p's 16-bit word w: pixels 16w..16w+15, the leftmost in bit 15 */
static uint16_t pword(const struct cg2 *g, int p, uint32_t w)
{
	const uint8_t *px = &g->pix[(w * 16) & (CG2_PIXELS - 1)];
	uint16_t v = 0;

	for (int j = 0; j < 16; j++)
		if (px[j] >> p & 1)
			v |= 0x8000 >> j;
	return v;
}

/* write the bits of plane p's word w that `we` enables */
static void pword_write(struct cg2 *g, int p, uint32_t w, uint16_t we, uint16_t v)
{
	uint8_t *px = &g->pix[(w * 16) & (CG2_PIXELS - 1)];

	for (int j = 0; j < 16; j++)
		if (we & (0x8000 >> j))
			px[j] = (px[j] & ~(1 << p)) | ((v >> (15 - j) & 1) << p);
}

/*
 * A pixel-format word as one unit's source: the even byte's (pixel n's)
 * bit p in every even bit position, the odd byte's in every odd one.
 *
 * Replication is what lets an aligned pixel copy run with a shift of zero
 * whatever bit position the destination pair sits at [rop: SWWPIX with
 * cg2_setshift(.., 0, 1)], and it makes the misaligned case come out exactly
 * as [stn]'s comment describes: "the LSB of the left source register and
 * the MSB of the right source register are written to the two destination
 * pixels", with the shift set to the pair's bit position + 1.
 */
static uint16_t pixsrc(uint16_t data, int p)
{
	return (data >> (8 + p) & 1 ? 0xaaaa : 0) | (data >> p & 1 ? 0x5555 : 0);
}

/* ---- one raster-op unit ----------------------------------------------- */

/*
 * The source FIFO.  [k34]: "set fifo direction to one, ie. bus -> src1 ->
 * src2 -> ROPC function unit".  Left to right (shift bit 8 set), new data
 * enters source1 and the older word moves to source2; right to left the
 * other way round.  [rop]'s priming confirms it: it reads the first source
 * word and writes the register about to be shifted out (source2 left to
 * right, source1 right to left), which only makes sense if that write is
 * overwritten by the next load.
 */
static void src_load(struct cg2_unit *u, uint16_t d)
{
	if (u->r[MRC_SHIFT] & 0x100) {
		u->r[SRC2] = u->r[SRC1];
		u->r[SRC1] = d;
	} else {
		u->r[SRC1] = u->r[SRC2];
		u->r[SRC2] = d;
	}
}

/*
 * The aligner: a 16-bit window on source2:source1 shifted right by the
 * count, except that a count of zero selects the older word whole --
 * source2 left to right, source1 right to left.
 *
 * Every priming decision in [rop], [stn] and [bat] agrees: left to right
 * they prime exactly when the source bit offset is >= the destination's,
 * equality included, and right to left when it is <=.  A shift of zero
 * with a primed FIFO must therefore hand the function the first word, not
 * the second.  [bat]'s unshifted glyph path primes source1 and ends each
 * line with a dummy write for the same reason, and [pl] loads a colour
 * into source2 and never loads the FIFO again ("never load src").
 */
static uint16_t aligned(const struct cg2_unit *u)
{
	int s = u->r[MRC_SHIFT] & 15;

	if (s == 0)
		return u->r[MRC_SHIFT] & 0x100 ? u->r[SRC2] : u->r[SRC1];
	return (uint16_t)(((uint32_t)u->r[SRC2] << 16 | u->r[SRC1]) >> s);
}

/*
 * The function: an 8-bit truth table over pattern, source and destination,
 * indexed P*4 + S*2 + D [reg: CG_MASK 0xf0, CG_SRC 0xcc, CG_DEST 0xaa].
 * Pixrect's 4-bit op is its low nibble when the pattern is zero; [stn]
 * puts a stencil in the pattern register and builds (op << 4 | CG_DEST &
 * CG_NOTMASK), "op where the stencil is set, else leave the destination".
 */
static uint16_t func(uint16_t op, uint16_t p, uint16_t s, uint16_t d)
{
	uint16_t r = 0;

	for (int i = 0; i < 8; i++)
		if (op >> i & 1)
			r |= (i & 4 ? p : ~p) & (i & 2 ? s : ~s) & (i & 1 ? d : ~d);
	return r;
}

/*
 * The word counter.  setwidth(w, w) loads width and opcount with the line's
 * word count - 1; a destination load is the first word while opcount equals
 * width (mask1 applies) and the last while it is zero (mask2 applies, and
 * the count reloads).  It counts destination *loads*, not writes: [rop]'s
 * ropmode swap writes the middle of a fill in PRRWRD, which loads nothing
 * on a write, and finds opcount still at zero for the line's last word.
 */
static void count(struct cg2_unit *u, int *first, int *last)
{
	uint16_t oc = u->r[MRC_OPCOUNT], wd = u->r[MRC_WIDTH];

	*first = oc == wd;
	*last = oc == 0;
	u->r[MRC_OPCOUNT] = *last ? wd : (uint16_t)(oc - 1);
}

/*
 * An access to rop-mode memory.  The ropmode's three bits [reg]:
 *   bit 0  pixel mode (the address is a byte a pixel) or word mode (a
 *          16-pixel word, all eight planes in parallel)
 *   bit 1  the destination is loaded on a write (else on a read)
 *   bit 2  word modes: the source is loaded on a read (else on a write);
 *          pixel modes: "parallel16", which nothing in SunOS uses
 */
static uint16_t rop_access(struct cg2 *g, uint32_t off, int strobes,
			   int wr, uint16_t data)
{
	int mode = (g->status & CG2S_ROPMODE) >> 3;
	int pixmode = mode & 1;
	int ld_dst = wr ? (mode & 2) != 0 : (mode & 2) == 0;
	int ld_src = pixmode ? wr : (wr ? (mode & 4) == 0 : (mode & 4) != 0);
	uint32_t n, w;
	uint16_t we, ret = 0;

	if (pixmode && (mode & 4))
		warn(g, "parallel16 pixel mode (PRWPIX/PWWPIX) is not modelled");

	if (pixmode) {
		n = off & 0xfffff;
		if (strobes == (CG2_UDS | CG2_LDS)) {
			n &= ~1u;
			we = 0xc000 >> (n & 15);
			ret = g->pix[n] << 8 | g->pix[n + 1];
		} else {
			we = 0x8000 >> (n & 15);
			ret = g->pix[n] * 0x101;
		}
		w = n >> 4;
	} else {
		/* the plane-select bits are ignored: all planes take part */
		w = (off & 0x1ffff) >> 1;
		we = (strobes & CG2_UDS ? 0xff00 : 0) | (strobes & CG2_LDS ? 0x00ff : 0);
		/* what a word-mode read returns is not known; nothing uses it */
		ret = pword(g, 0, w);
	}

	for (int p = 0; p < 8; p++) {
		struct cg2_unit *u = &g->u[p];
		int first = 0, last = 0;

		if (ld_src)
			src_load(u, pixmode ? pixsrc(data, p)
					     : wr ? data : pword(g, p, w));
		if (ld_dst) {
			u->r[MRC_DEST] = pword(g, p, w);
			count(u, &first, &last);
		}
		if (wr && (g->ppmask >> p & 1)) {
			uint16_t res = func(u->r[MRC_OP], u->r[MRC_PATTERN],
					    aligned(u), u->r[MRC_DEST]);
			uint16_t m = 0;

			/*
			 * The end masks protect bits of a destination loaded
			 * in this cycle ([pl]: "ld dst for mask").  A write
			 * that loads nothing applies neither: that is what
			 * makes [rop]'s PRRWRD/SRWPIX middle-of-line writes
			 * safe with opcount sitting at the last word.
			 */
			if (ld_dst)
				m = (first ? u->r[MRC_MASK1] : 0) |
				    (last ? u->r[MRC_MASK2] : 0);
			pword_write(g, p, w, we & ~m, res);
		}
	}
	return ret;
}

/* ---- the bus ---------------------------------------------------------- */

static uint16_t merge(uint16_t old, int strobes, uint16_t data)
{
	uint16_t m = (strobes & CG2_UDS ? 0xff00 : 0) | (strobes & CG2_LDS ? 0x00ff : 0);

	return (old & ~m) | (data & m);
}

static uint16_t status_read(const struct cg2 *g)
{
	return (g->status & CG2S_WRITABLE) |
	       (g->retrace ? CG2S_RETRACE : 0) | (g->inpend ? CG2S_INPEND : 0);
	/* resolution 0: 1152x900; fastread and id 0: a Sun-2 board */
}

uint16_t cg2_read(struct cg2 *g, uint32_t off, int strobes)
{
	off &= CG2_SIZE - 1;

	if (off < CG2_PIXEL_BASE) {
		/* plane mode: plane = A19..A17 */
		return pword(g, off >> 17, (off & 0x1ffff) >> 1);
	}
	if (off < CG2_ROP_BASE) {
		uint32_t n = off & 0xfffff;

		if (strobes == (CG2_UDS | CG2_LDS))
			return g->pix[n & ~1u] << 8 | g->pix[n | 1];
		return g->pix[n] * 0x101;
	}
	if (off < CG2_ROPC_BASE)
		return rop_access(g, off, strobes, 0, 0);
	if (off < CG2_STATUS) {
		int unit = (off - CG2_ROPC_BASE) >> 12;

		if (off & 0x800)
			warn(g, "read of a prime register");
		/* "CG2_ALLROP ... reads from plane zero" [reg] */
		return g->u[unit == 8 ? 0 : unit].r[(off >> 1) & 15];
	}
	switch (off & ~0xfffu) {
	case CG2_STATUS:	return status_read(g);
	case CG2_PPMASK:	return g->ppmask;
	case CG2_WORDPAN:	return g->wordpan;
	case CG2_ZOOM:		return g->zoom;
	case CG2_PIXPAN:	return g->pixpan;
	case CG2_VARZOOM:	return g->varzoom;
	case CG2_INTVEC:	return g->intvec;
	}
	if (off >= CG2_CMAP && off < CG2_CMAP + 0x600) {
		int i = (off - CG2_CMAP) >> 1;

		return g->shadow[i >> 8][i & 255];
	}
	warn(g, "read of an undecoded offset");
	return 0xffff;
}

void cg2_write(struct cg2 *g, uint32_t off, int strobes, uint16_t data)
{
	off &= CG2_SIZE - 1;

	if (off < CG2_PIXEL_BASE) {
		int p = off >> 17;

		/*
		 * The plane mask gates plain writes as well as rop ones:
		 * [x] enables plane 0 alone before drawing into plane 0, and
		 * all planes before using the byte-per-pixel memory.
		 */
		if (g->ppmask >> p & 1)
			pword_write(g, p, (off & 0x1ffff) >> 1,
				    (strobes & CG2_UDS ? 0xff00 : 0) |
				    (strobes & CG2_LDS ? 0x00ff : 0), data);
		return;
	}
	if (off < CG2_ROP_BASE) {
		uint32_t n = off & 0xfffff;
		uint8_t m = g->ppmask;

		if (strobes & CG2_UDS) {
			uint32_t e = n & ~1u;
			g->pix[e] = (g->pix[e] & ~m) | (data >> 8 & m);
		}
		if (strobes & CG2_LDS) {
			uint32_t o = n | 1;
			g->pix[o] = (g->pix[o] & ~m) | (data & m);
		}
		return;
	}
	if (off < CG2_ROPC_BASE) {
		rop_access(g, off, strobes, 1, data);
		return;
	}
	if (off < CG2_STATUS) {
		int unit = (off - CG2_ROPC_BASE) >> 12;
		int reg = (off >> 1) & 15;
		int prime = (off & 0x800) != 0;

		if (prime && reg != SRC1 && reg != SRC2)
			warn(g, "write to a prime register other than a source");
		for (int p = 0; p < 8; p++) {
			struct cg2_unit *u = &g->u[p];

			/* "CG2_ALLROP ... writes to all units enabled by PPMASK" */
			if (unit == 8 ? !(g->ppmask >> p & 1) : unit != p)
				continue;
			/*
			 * The prime copy of a source register takes the
			 * value in pixel format: "for pixmode src reg prime,
			 * byte xfer loads alternate src register bits" [reg];
			 * [pl] loads a colour as `color | color << 8'.
			 */
			if (prime && (reg == SRC1 || reg == SRC2))
				u->r[reg] = pixsrc(data, p);
			else
				u->r[reg] = merge(u->r[reg], strobes, data);
		}
		return;
	}
	switch (off & ~0xfffu) {
	case CG2_STATUS: {
		uint16_t v = merge(status_read(g), strobes, data);

		g->status = v & CG2S_WRITABLE;
		/* [k34] cgtwointr: "inten = 0; clear pending interrupt" */
		if (!(v & CG2S_INTEN))
			g->inpend = 0;
		return;
	}
	case CG2_PPMASK:
		if (strobes & CG2_LDS)
			g->ppmask = data & 0xff;
		return;
	case CG2_WORDPAN:	g->wordpan = merge(g->wordpan, strobes, data); return;
	case CG2_ZOOM:		g->zoom = merge(g->zoom, strobes, data); return;
	case CG2_PIXPAN:	g->pixpan = merge(g->pixpan, strobes, data); return;
	case CG2_VARZOOM:	g->varzoom = merge(g->varzoom, strobes, data); return;
	case CG2_INTVEC:	g->intvec = merge(g->intvec, strobes, data); return;
	}
	if (off >= CG2_CMAP && off < CG2_CMAP + 0x600) {
		int i = (off - CG2_CMAP) >> 1;

		/*
		 * update_cmap "silently disables writing to TTL cmap" [reg];
		 * both writers clear it first [cm] [prom] [x].
		 */
		if (g->status & CG2S_UPDATE_CMAP) {
			warn(g, "colour map write while update_cmap is set");
			return;
		}
		if (strobes & CG2_LDS)
			g->shadow[i >> 8][i & 255] = data & 0xff;
		return;
	}
	warn(g, "write to an undecoded offset");
}

void cg2_retrace(struct cg2 *g, int level)
{
	if (level && !g->retrace && (g->status & CG2S_UPDATE_CMAP))
		/* "copy TTL cmap to ECL cmap next vert retrace" [reg] */
		memcpy(g->active, g->shadow, sizeof g->active);
	if (!level && g->retrace && (g->status & CG2S_INTEN))
		/* "enab interrupt at end of retrace" [reg] */
		g->inpend = 1;
	g->retrace = level;
}

int cg2_irq(const struct cg2 *g)
{
	return g->inpend && (g->status & CG2S_INTEN);
}
