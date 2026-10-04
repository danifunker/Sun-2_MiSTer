/*
 * cg2model harness: run SunOS's own libpixrect against the board model.
 *
 * The image is the real 4.0 Sun-2 libpixrect object code (tape 1, file 8,
 * ./lib/libpixrect.a), linked flat by aoutlink.py and run on Musashi as a
 * 68010.  RAM is 0..8 MiB; the cgtwo's 4 MiB window sits at 0x800000, and
 * every access libpixrect makes there becomes a 68010 bus cycle on the model:
 * a byte with one strobe, a word with both, a long as two words.  libc is
 * served in C: an undefined symbol is an ILLEGAL; RTS stub (aoutlink.py), and
 * the illegal-instruction hook runs its C body.
 *
 * Each test does the same operation twice, once through the cg2 routines on
 * the model and once through libpixrect's memory-pixrect routines on a
 * 1152x900x8 mirror in RAM, and compares every pixel.  So the reference is
 * Sun's own definition of what a rasterop means, and the thing under test is
 * the hardware model as Sun's cg2 code drives it.
 *
 * usage: harness IMAGE.bin IMAGE.sym [-n iterations] [-s seed] [-v|-vv] [-k] [-S]
 *                [-t trace -I initial -F final]
 *
 * -t writes every bus cycle on the board from the starting image on, as
 * "r<strobes> <offset> <data>" or "w...", strobes 1 LDS, 2 UDS, 3 both; -I
 * and -F write the board's megabyte of pixels before the first and after the
 * last.  tb/verilator/tb_cgtwo replays the three into the RTL.
 *
 * -k runs the kernel's image instead (aoutlink'd from the 4.0 Sys tape's
 * cg2_rop.o, cgtwo.o and friends): the driver's probe and attach, then the
 * rasterop tests through the kernel's own cg2_rop.
 */
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "m68k.h"
#include "cg2model.h"

#define RAM_SIZE	0x800000
#define IMAGE_BASE	0x1000
#define HEAP_BASE	0x100000
#define HEAP_END	0x7e0000
#define STACK_TOP	0x7ff000
#define RET_ADDR	0x0f00		/* ILLEGAL: a call has returned */
#define CRASH_ADDR	0x0f10		/* ILLEGAL: an exception was taken */
#define BOARD		0x800000
#define FB_VA		(BOARD + 0x200000)	/* struct cg2fb: rop memory onward */

#define CG2D_STDRES	1
#define CG2D_ZOOM	256

#define PIX_SRC		(0xC << 1)
#define PIX_DST		(0xA << 1)
#define PIX_DONTCLIP	1
#define PIX_COLOR(c)	((c) << 5)
#define MP_REVERSEVIDEO	1

static uint8_t ram[RAM_SIZE];
static struct cg2 G;
static FILE *trace;
static int tracing;		/* from the starting image on: see -I */
static int verbose;
static int kernel;		/* -k: the 4.0 kernel's cg2 code, not the library's */
static unsigned long nboard, nlong;

static void die(const char *fmt, ...)
{
	va_list ap;

	va_start(ap, fmt);
	vfprintf(stderr, fmt, ap);
	va_end(ap);
	fprintf(stderr, " (pc %06x)\n", m68k_get_reg(NULL, M68K_REG_PPC));
	exit(2);
}

/* ---- RAM, big-endian ---- */
static uint32_t rd8(uint32_t a) { return ram[a]; }
static uint32_t rd16(uint32_t a) { return ram[a] << 8 | ram[a + 1]; }
static uint32_t rd32(uint32_t a) { return rd16(a) << 16 | rd16(a + 2); }
static void wr8(uint32_t a, uint32_t v) { ram[a] = v; }
static void wr16(uint32_t a, uint32_t v) { ram[a] = v >> 8; ram[a + 1] = v; }
static void wr32(uint32_t a, uint32_t v) { wr16(a, v >> 16); wr16(a + 2, v); }

/* ---- the board, as 68010 bus cycles ---- */
/*
 * -S: what each libpixrect routine actually puts on the bus -- rop-memory
 * accesses by ropmode, direction and width, and which raster-op registers
 * (and prime registers) it writes.  The tests name the routine in `cat'.
 */
#define NCAT 24
static char cats[NCAT][24], cat[24];
static unsigned long ropuse[NCAT][8][2][2];	/* [cat][mode][write][word] */
static unsigned reguse[NCAT];			/* bit: prime * 16 + register */
static int stats;

static void setcat(const char *what)
{
	int n = 0;

	while (what[n] && what[n] != ' ' && what[n] != '(' && n < 23)
		n++;
	memcpy(cat, what, n);
	cat[n] = 0;
}

static int catno(void)
{
	for (int i = 0; i < NCAT; i++) {
		if (!cats[i][0])
			strcpy(cats[i], cat);
		if (!strcmp(cats[i], cat))
			return i;
	}
	return NCAT - 1;
}

static void account(uint32_t off, int strobes, int wr)
{
	int c;

	if (!stats || !cat[0])
		return;
	c = catno();
	if (off >= CG2_ROP_BASE && off < CG2_ROPC_BASE)
		ropuse[c][(G.status & CG2S_ROPMODE) >> 3][wr][strobes == (CG2_UDS | CG2_LDS)]++;
	else if (wr && off >= CG2_ROPC_BASE && off < CG2_STATUS)
		reguse[c] |= 1u << ((off & 0x800 ? 16 : 0) + ((off >> 1) & 15));
}

static void print_stats(void)
{
	static const char *mode[] = { "PRWWRD", "SRWPIX", "PWWWRD", "SWWPIX",
				      "PRRWRD", "PRWPIX", "PWRWRD", "PWWPIX" };
	static const char *reg[] = { "dest", "src1", "src2", "pattern", "mask1", "mask2",
				     "shift", "op", "width", "opcount", "decoderout",
				     "x11", "x12", "x13", "x14", "x15" };

	for (int c = 0; c < NCAT && cats[c][0]; c++) {
		printf("%-10s", cats[c]);
		for (int m = 0; m < 8; m++)
			for (int w = 0; w < 2; w++)
				for (int z = 0; z < 2; z++)
					if (ropuse[c][m][w][z])
						printf(" %s %s.%c", mode[m], w ? "w" : "r", z ? 'w' : 'b');
		printf("\n%10s regs:", "");
		for (int b = 0; b < 32; b++)
			if (reguse[c] >> b & 1)
				printf(" %s%s", b >= 16 ? "prime." : "", reg[b & 15]);
		printf("\n");
	}
}

static unsigned long npoll;

static uint16_t bus_read(uint32_t a, int strobes)
{
	uint16_t v;

	/*
	 * A display, as code spinning on the status register sees it: the
	 * retrace bit moves every few polls, so waits for an edge terminate.
	 */
	if (((a - BOARD) & ~0xfffu) == CG2_STATUS && ++npoll % 7 == 0)
		cg2_retrace(&G, !G.retrace);
	account(a - BOARD, strobes, 0);
	v = cg2_read(&G, a - BOARD, strobes);

	nboard++;
	if (trace && tracing)
		fprintf(trace, "r%d %06x %04x\n", strobes, a - BOARD, v);
	return v;
}

static void bus_write(uint32_t a, int strobes, uint16_t v)
{
	account(a - BOARD, strobes, 1);
	nboard++;
	if (trace && tracing)
		fprintf(trace, "w%d %06x %04x\n", strobes, a - BOARD, v);
	cg2_write(&G, a - BOARD, strobes, v);
}

static int board(uint32_t a) { return a >= BOARD && a < BOARD + CG2_SIZE; }

static void check(uint32_t a, int n)
{
	if (a + n > RAM_SIZE)
		die("access to %06x", a);
}

unsigned int m68k_read_memory_8(unsigned int a)
{
	a &= 0xffffff;
	if (board(a)) {
		uint16_t v = bus_read(a, a & 1 ? CG2_LDS : CG2_UDS);
		return a & 1 ? v & 0xff : v >> 8;
	}
	check(a, 1);
	return rd8(a);
}

unsigned int m68k_read_memory_16(unsigned int a)
{
	a &= 0xffffff;
	if (board(a))
		return bus_read(a, CG2_UDS | CG2_LDS);
	check(a, 2);
	return rd16(a);
}

unsigned int m68k_read_memory_32(unsigned int a)
{
	a &= 0xffffff;
	if (board(a)) {
		nlong++;
		uint32_t hi = bus_read(a, CG2_UDS | CG2_LDS);
		return hi << 16 | bus_read(a + 2, CG2_UDS | CG2_LDS);
	}
	check(a, 4);
	return rd32(a);
}

void m68k_write_memory_8(unsigned int a, unsigned int v)
{
	a &= 0xffffff;
	if (board(a)) {
		/* the 68010 drives a byte on both halves of the bus */
		bus_write(a, a & 1 ? CG2_LDS : CG2_UDS, (v & 0xff) * 0x101);
		return;
	}
	check(a, 1);
	wr8(a, v);
}

void m68k_write_memory_16(unsigned int a, unsigned int v)
{
	a &= 0xffffff;
	if (board(a)) {
		bus_write(a, CG2_UDS | CG2_LDS, v);
		return;
	}
	check(a, 2);
	wr16(a, v);
}

void m68k_write_memory_32(unsigned int a, unsigned int v)
{
	a &= 0xffffff;
	if (board(a)) {
		nlong++;
		bus_write(a, CG2_UDS | CG2_LDS, v >> 16);
		bus_write(a + 2, CG2_UDS | CG2_LDS, v);
		return;
	}
	check(a, 4);
	wr32(a, v);
}

unsigned int m68k_read_disassembler_16(unsigned int a) { return rd16(a & 0x7fffff); }
unsigned int m68k_read_disassembler_32(unsigned int a) { return rd32(a & 0x7fffff); }

/* ---- symbols ---- */
struct sym { char name[64]; uint32_t addr; int stub; };
static struct sym syms[512];
static int nsyms;

static void load_syms(const char *path)
{
	FILE *f = fopen(path, "r");
	char line[128], name[64], kind[16];
	unsigned addr;

	if (!f)
		die("can't open %s", path);
	while (fgets(line, sizeof line, f)) {
		kind[0] = 0;
		if (sscanf(line, "%x %63s %15s", &addr, name, kind) < 2)
			continue;
		if (nsyms == 512)
			die("too many symbols");
		snprintf(syms[nsyms].name, sizeof syms[0].name, "%s", name);
		syms[nsyms].addr = addr;
		syms[nsyms].stub = !strcmp(kind, "stub");
		nsyms++;
	}
	fclose(f);
}

static uint32_t sym(const char *name)
{
	for (int i = 0; i < nsyms; i++)
		if (!strcmp(syms[i].name, name))
			return syms[i].addr;
	die("no symbol %s", name);
	return 0;
}

/* ---- a heap in RAM: first fit, 8-byte header holding the size ---- */
struct blk { uint32_t addr, size; int used; };
static struct blk heap[4096];
static int nheap;

static void heap_init(void)
{
	heap[0] = (struct blk){ HEAP_BASE, HEAP_END - HEAP_BASE, 0 };
	nheap = 1;
}

static uint32_t h_alloc(uint32_t n)
{
	n = (n + 15) & ~15u;
	if (!n)
		n = 16;
	for (int i = 0; i < nheap; i++) {
		if (heap[i].used || heap[i].size < n)
			continue;
		if (heap[i].size > n) {
			if (nheap == 4096)
				die("heap fragmented");
			memmove(&heap[i + 2], &heap[i + 1], (nheap - i - 1) * sizeof heap[0]);
			heap[i + 1] = (struct blk){ heap[i].addr + n, heap[i].size - n, 0 };
			heap[i].size = n;
			nheap++;
		}
		heap[i].used = 1;
		return heap[i].addr;
	}
	die("out of heap (%u)", n);
	return 0;
}

static void h_free(uint32_t a)
{
	for (int i = 0; i < nheap; i++) {
		if (heap[i].addr != a)
			continue;
		if (!heap[i].used)
			die("double free %06x", a);
		heap[i].used = 0;
		if (i + 1 < nheap && !heap[i + 1].used) {
			heap[i].size += heap[i + 1].size;
			memmove(&heap[i + 1], &heap[i + 2], (nheap - i - 2) * sizeof heap[0]);
			nheap--;
		}
		if (i > 0 && !heap[i - 1].used) {
			heap[i - 1].size += heap[i].size;
			memmove(&heap[i], &heap[i + 1], (nheap - i - 1) * sizeof heap[0]);
			nheap--;
		}
		return;
	}
	if (a)
		die("free of %06x, never allocated", a);
}

/* ---- libc, and Sun's runtime ---- */
static uint32_t arg(int i)
{
	return rd32(m68k_get_reg(NULL, M68K_REG_SP) + 4 + 4 * i);
}

static void ret(uint32_t v) { m68k_set_reg(M68K_REG_D0, v); }

static int32_t sd(int r) { return (int32_t)m68k_get_reg(NULL, r); }

/* the kernel's printf, enough of it for the driver's messages */
static void kprintf(void)
{
	uint32_t fmt = arg(0);
	int a = 1;

	fprintf(stderr, "kernel: ");
	for (char c; (c = ram[fmt]); fmt++) {
		if (c != '%') {
			fputc(c, stderr);
			continue;
		}
		switch (ram[++fmt]) {
		case 's':
			for (uint32_t p = arg(a++); ram[p]; p++)
				fputc(ram[p], stderr);
			break;
		case 'c':
			fputc(arg(a++), stderr);
			break;
		case 'x': case 'X':
			fprintf(stderr, "%x", arg(a++));
			break;
		default:
			fprintf(stderr, "%d", (int)arg(a++));
		}
	}
}

static void stub(const char *name)
{
	if (!strcmp(name, "_malloc"))
		ret(h_alloc(arg(0)));
	else if (!strcmp(name, "_free"))
		h_free(arg(0));
	else if (!strcmp(name, "_bzero"))
		memset(&ram[arg(0)], 0, arg(1));
	else if (!strcmp(name, "_getpagesize"))
		ret(2048);
	/* Sun's long arithmetic: operands in d0 and d1, result in d0 */
	else if (!strcmp(name, "lmult"))
		ret((uint32_t)(sd(M68K_REG_D0) * sd(M68K_REG_D1)));
	else if (!strcmp(name, "ldivt"))
		ret((uint32_t)(sd(M68K_REG_D0) / sd(M68K_REG_D1)));
	else if (!strcmp(name, "lmodt"))
		ret((uint32_t)(sd(M68K_REG_D0) % sd(M68K_REG_D1)));
	/* the kernel's protected probes: no bus errors on a model */
	else if (!strcmp(name, "_peek"))
		ret(m68k_read_memory_16(arg(0)));
	else if (!strcmp(name, "_peekc"))
		ret(m68k_read_memory_8(arg(0)));
	else if (!strcmp(name, "_poke"))
		m68k_write_memory_16(arg(0), arg(1)), ret(0);
	else if (!strcmp(name, "_pokec"))
		m68k_write_memory_8(arg(0), arg(1)), ret(0);
	else if (!strcmp(name, "_fbgetpage"))
		ret(0x400000 >> 11);		/* VME A24 0x400000 */
	else if (!strcmp(name, "_fbmapin") || !strcmp(name, "_splx"))
		ret(0);
	else if (!strcmp(name, "_printf"))
		kprintf();
	else
		die("unexpected call to %s", name);
}

static volatile int returned;

static int illegal(int opcode)
{
	uint32_t pc = m68k_get_reg(NULL, M68K_REG_PPC);

	(void)opcode;
	if (pc == RET_ADDR) {
		returned = 1;
		m68k_end_timeslice();
		return 1;
	}
	if (pc == CRASH_ADDR)
		die("exception taken");
	for (int i = 0; i < nsyms; i++)
		if (syms[i].stub && syms[i].addr == pc) {
			stub(syms[i].name);
			return 1;
		}
	return 0;
}

static uint32_t call(const char *fn, int n, ...)
{
	uint32_t a[16], sp = STACK_TOP;
	va_list ap;

	va_start(ap, n);
	for (int i = 0; i < n; i++)
		a[i] = va_arg(ap, uint32_t);
	va_end(ap);
	for (int i = n - 1; i >= 0; i--)
		wr32(sp -= 4, a[i]);
	wr32(sp -= 4, RET_ADDR);
	m68k_set_reg(M68K_REG_SR, 0x2700);
	m68k_set_reg(M68K_REG_A7, sp);
	m68k_set_reg(M68K_REG_PC, sym(fn));
	returned = 0;
	for (long i = 0; !returned; i++) {
		if (i > 200000)
			die("%s does not return", fn);
		m68k_execute(100000);
	}
	return m68k_get_reg(NULL, M68K_REG_D0);
}

/* ---- pixrects in RAM ---- */
#define PR_OPS	0
#define PR_W	4
#define PR_H	8
#define PR_DEPTH 12
#define PR_DATA	16
/* struct mpr_data */
#define MD_LINEBYTES 0
#define MD_IMAGE 4
#define MD_OFFX	8
#define MD_OFFY	12
#define MD_FLAGS 18
/* struct cg2pr (cg2var.h; checked against FBIOGPIXRECT in the 4.0 cgtwo.o) */
#define CG_VA	0
#define CG_PLANES 12
#define CG_OFFX	16
#define CG_OFFY	20
#define CG_FLAGS 44
#define CG_LINEBYTES 48

static uint32_t cg2pr(int planes, int ox, int oy, int w, int h)
{
	uint32_t pr = h_alloc(20), d = h_alloc(52);

	memset(&ram[d], 0, 52);
	wr32(pr + PR_OPS, sym("_cg2_ops"));
	wr32(pr + PR_W, w);
	wr32(pr + PR_H, h);
	wr32(pr + PR_DEPTH, 8);
	wr32(pr + PR_DATA, d);
	wr32(d + CG_VA, FB_VA);
	wr32(d + CG_PLANES, planes);
	wr32(d + CG_OFFX, ox);
	wr32(d + CG_OFFY, oy);
	wr32(d + CG_FLAGS, CG2D_STDRES | CG2D_ZOOM);
	wr32(d + CG_LINEBYTES, CG2_W);
	return pr;
}

static void cg2pr_free(uint32_t pr)
{
	h_free(rd32(pr + PR_DATA));
	h_free(pr);
}

static uint32_t mem_create(int w, int h, int depth)
{
	uint32_t pr = call("_mem_create", 3, w, h, depth);

	if (!pr)
		die("mem_create(%d, %d, %d) failed", w, h, depth);
	return pr;
}

static uint32_t md(uint32_t pr) { return rd32(pr + PR_DATA); }
static uint8_t *image(uint32_t pr) { return &ram[rd32(md(pr) + MD_IMAGE)]; }
static int linebytes(uint32_t pr) { return rd32(md(pr) + MD_LINEBYTES); }

/* ---- randomness ---- */
static uint64_t rs = 88172645463325252ull;
static uint32_t rnd(void) { rs ^= rs << 13; rs ^= rs >> 7; rs ^= rs << 17; return rs; }
static int rn(int n) { return n > 0 ? (int)(rnd() % (unsigned)n) : 0; }

static void fill_random(uint8_t *p, size_t n)
{
	for (size_t i = 0; i < n; i++)
		p[i] = rnd();
}

/* ---- the comparisons ---- */
static uint32_t M;		/* the 1152x900x8 memory mirror */
static unsigned long ntests, nfail, nmemdis;
static uint8_t before[CG2_W * CG2_H], ref[CG2_W * CG2_H];

static void sync_mirror(void)
{
	memcpy(image(M), G.pix, CG2_W * CG2_H);
}

static void result(const char *what, int bad)
{
	ntests++;
	if (bad) {
		nfail++;
		fprintf(stderr, "FAIL %s: %d pixels differ\n", what, bad);
	} else if (verbose)
		fprintf(stderr, "ok   %s\n", what);
}

/*
 * The model against Sun's memory-pixrect code, for the operations whose
 * pixel choice is the library's own (vectors): mem_vector is the definition.
 */
static int compare_mem(const char *what)
{
	uint8_t *m = image(M);
	int bad = 0;

	for (int i = 0; i < CG2_W * CG2_H; i++)
		if (G.pix[i] != m[i] && bad++ < 8)
			fprintf(stderr, "  %s: (%d,%d) model %02x, mem %02x, was %02x\n",
				what, i % CG2_W, i / CG2_W, G.pix[i], m[i], before[i]);
	result(what, bad);
	sync_mirror();
	return bad;
}

/*
 * The model against pixrect semantics written out a pixel at a time (ref[],
 * below).  mem_rop is not infallible -- a one-pixel column from a 1-bit
 * source at some bit offsets comes out wrong -- so the model is judged
 * against this, and the mirror, which Sun's mem_* code drew, is checked
 * against it too: its disagreements are counted, not failed.
 */
static int compare_ref(const char *what, uint8_t planes)
{
	uint8_t *m = image(M);
	int bad = 0, mbad = 0;

	for (int i = 0; i < CG2_W * CG2_H; i++) {
		/* the memory pixrects have no plane mask: apply it here */
		if (((m[i] & planes) | (before[i] & ~planes)) != ref[i] &&
		    mbad++ < 3 && verbose > 1)
			fprintf(stderr, "  mem: (%d,%d) mem %02x, want %02x, was %02x\n",
				i % CG2_W, i / CG2_W, m[i], ref[i], before[i]);
		if (G.pix[i] != ref[i] && bad++ < 8)
			fprintf(stderr, "  %s: (%d,%d) model %02x, want %02x, was %02x, mem %02x\n",
				what, i % CG2_W, i / CG2_W, G.pix[i], ref[i], before[i], m[i]);
	}
	if (mbad) {
		nmemdis++;
		if (verbose)
			fprintf(stderr, "note %s: Sun's mem code disagrees in %d pixels\n",
				what, mbad);
	}
	result(what, bad);
	sync_mirror();
	return bad;
}

/* ---- pixrect semantics, a pixel at a time ---- */

/* a pixrect on the screen: a region of the frame buffer */
struct region { int ox, oy, w, h; };
static const struct region SCREEN = { 0, 0, CG2_W, CG2_H };

/* a source: depth 8 or 1, `rv' its MP_REVERSEVIDEO */
struct refsrc { const uint8_t *img; int lb, w, h, depth, rv; };

static int bit1(const struct refsrc *s, int x, int y)
{
	return (s->img[y * s->lb + (x >> 3)] >> (7 - (x & 7)) & 1) ^ s->rv;
}

static uint8_t pixop(int op4, uint8_t s, uint8_t d)
{
	return (op4 & 8 ? s & d : 0) | (op4 & 4 ? s & ~d : 0) |
	       (op4 & 2 ? ~s & d : 0) | (op4 & 1 ? ~s & ~d : 0);
}

/* the source pixel as an 8-bit value: a 1-bit pixel is the op's colour
   (or all ones for colour 0) or zero, and reverse video inverts that */
static uint8_t src_pixel(const struct refsrc *s, int x, int y, int color)
{
	uint8_t v;
	int b;

	if (!s)
		return color;
	if (s->depth == 8)
		return s->img[y * s->lb + x];
	b = s->img[y * s->lb + (x >> 3)] >> (7 - (x & 7)) & 1;
	/*
	 * The library's cg2_rop turns a 1x1 source into a fill with the value
	 * pr_get returns, and mem_get applies MP_REVERSEVIDEO to the bit, before
	 * the colour: so there reverse video picks colour or zero, where
	 * everywhere else it inverts the expanded pixel.  The kernel's cg2_rop
	 * has no such path.
	 */
	if (s->w == 1 && s->h == 1 && !kernel)
		return b ^ s->rv ? (color ? color : 0xff) : 0;
	v = b ? (color ? color : 0xff) : 0;
	return s->rv ? ~v : v;
}

/*
 * pr_clip, generalised: the destination (p[0], bounded by its pixrect)
 * and each source move together, and every one of them must stay inside
 * its own bounds.  One pass is enough: a left clip only moves the others
 * right, and a right clip only shortens.
 */
struct cp { int x, y, bw, bh; };

static int clip(int *w, int *h, struct cp *p, int n)
{
	for (int i = 0; i < n; i++) {
		if (p[i].x < 0) {
			int d = -p[i].x;
			*w -= d;
			for (int j = 0; j < n; j++)
				p[j].x += d;
		}
		if (p[i].y < 0) {
			int d = -p[i].y;
			*h -= d;
			for (int j = 0; j < n; j++)
				p[j].y += d;
		}
		if (p[i].x + *w > p[i].bw)
			*w = p[i].bw - p[i].x;
		if (p[i].y + *h > p[i].bh)
			*h = p[i].bh - p[i].y;
	}
	return *w > 0 && *h > 0;
}

/* apply one rasterop (or stencil op) to ref[], in place */
static void ref_op(const struct region *r, int x, int y, int w, int h, int op,
		   const struct refsrc *s, int sx, int sy,
		   const struct refsrc *st, int stx, int sty, uint8_t planes)
{
	struct cp p[3] = { { x, y, r->w, r->h } };
	int n = 1, color = op >> 5, op4 = op >> 1 & 15, is = 0, ist = 0;

	if (s) {
		p[is = n++] = (struct cp){ sx, sy, s->w, s->h };
	}
	if (st) {
		p[ist = n++] = (struct cp){ stx, sty, st->w, st->h };
	}
	if (!clip(&w, &h, p, n))
		return;
	for (int j = 0; j < h; j++)
		for (int i = 0; i < w; i++) {
			uint8_t *d = &ref[(r->oy + p[0].y + j) * CG2_W + r->ox + p[0].x + i];
			uint8_t sv;

			if (st && !bit1(st, p[ist].x + i, p[ist].y + j))
				continue;
			sv = src_pixel(s, s ? p[is].x + i : 0, s ? p[is].y + j : 0, color);
			*d = (pixop(op4, sv, *d) & planes) | (*d & ~planes);
		}
}

/* the screen, or a region of it, as it was before the operation */
static struct refsrc screen_src(const struct region *r)
{
	return (struct refsrc){ before + r->oy * CG2_W + r->ox, CG2_W, r->w, r->h, 8, 0 };
}

/* ---- the tests ---- */

/* SunOS 4.0's cgtwo probe, from the 4.0 tape's cgtwo.o (probeit) */
static void test_probe(void)
{
	uint32_t fb = 0x200000;
	uint16_t s;
	int ok;

	cg2_reset(&G);
	s = cg2_read(&G, fb + 0x109000, CG2_UDS | CG2_LDS);
	s = (s & ~0x38) | (SWWPIX << 3);
	cg2_write(&G, fb + 0x109000, CG2_UDS | CG2_LDS, s);
	cg2_write(&G, fb + 0x10a000, CG2_UDS | CG2_LDS, 0xff);
	cg2_write(&G, fb + 0x10800e, CG2_UDS | CG2_LDS, 0xcc);
	cg2_write(&G, fb + 0x108008, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb + 0x10800a, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb + 0x10800c, CG2_UDS | CG2_LDS, 0x100);
	cg2_write(&G, fb, CG2_UDS, 0xa5a5);
	cg2_write(&G, fb, CG2_UDS, 0);
	ok = (cg2_read(&G, fb, CG2_UDS) >> 8) == 0xa5;
	cg2_write(&G, fb + 0x10a000, CG2_UDS | CG2_LDS, 0xcc);
	cg2_write(&G, fb + 0x10800e, CG2_UDS | CG2_LDS, 0xff55);
	cg2_write(&G, fb, CG2_UDS, 0);
	cg2_write(&G, fb + 0x10a000, CG2_UDS | CG2_LDS, 0xff);
	ok = ok && (cg2_read(&G, fb, CG2_UDS) >> 8) == 0x69;
	result("4.0 kernel probe (0xa5, then 0x69)", !ok);

	/*
	 * 3.4's probe (sun/sys/sundev/cgtwo.c): prime source2 with 0 through
	 * the pixel-format prime register, write 0xff, then 0 through ppmask
	 * 0xaa, and expect 0xaa.  It reads back (U & 0x55) | 0xaa, where U is
	 * whatever source1 held before: right from reset, as here, that is 0.
	 */
	cg2_reset(&G);
	cg2_write(&G, fb + 0x10a000, CG2_UDS | CG2_LDS, 0xff);
	cg2_write(&G, fb + 0x10800e, CG2_UDS | CG2_LDS, 0xcc);
	s = cg2_read(&G, fb + 0x109000, CG2_UDS | CG2_LDS);
	cg2_write(&G, fb + 0x109000, CG2_UDS | CG2_LDS, (s & ~0x38) | (SWWPIX << 3));
	cg2_write(&G, fb + 0x108008, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb + 0x10800a, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb + 0x108010, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb + 0x108012, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb + 0x10800c, CG2_UDS | CG2_LDS, 0x100);
	cg2_write(&G, fb + 0x108804, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, fb, CG2_UDS, 0xffff);
	cg2_write(&G, fb + 0x10a000, CG2_UDS | CG2_LDS, 0xaa);
	cg2_write(&G, fb, CG2_UDS, 0);
	result("3.4 kernel probe from reset (0xaa)", (cg2_read(&G, fb, CG2_UDS) >> 8) != 0xaa);
	cg2_reset(&G);
}

/* byte access as the 68010 makes it: one strobe, the byte on both halves */
static uint8_t brd(uint32_t off)
{
	uint16_t v = cg2_read(&G, off, off & 1 ? CG2_LDS : CG2_UDS);

	return off & 1 ? v : v >> 8;
}

static void bwr(uint32_t off, uint8_t v)
{
	cg2_write(&G, off, off & 1 ? CG2_LDS : CG2_UDS, v * 0x101);
}

/* a display: the retrace bit moves every few reads, as a spin loop sees it */
static unsigned long nstatus;
static uint8_t status_lo(void)
{
	if (++nstatus % 7 == 0)
		cg2_retrace(&G, !G.retrace);
	return brd(CG2_STATUS + 1);
}

/*
 * The Rev Q PROM's init_scolor (0xEF3D34, doc/prom/README.md), cycle for
 * cycle in what it touches, then the console's first character in plane 0;
 * and cgtwoattach's Sun-2/Sun-3 test from the 4.0 cgtwo.o.
 */
static void test_prom(void)
{
	int bad = 0;

	cg2_reset(&G);
	fill_random(G.pix, sizeof G.pix);		/* power-up contents */
	cg2_write(&G, CG2_STATUS, CG2_UDS | CG2_LDS, 0);	/* poke(): probe */
	for (int i = 0; i < 0x600; i += 4) {		/* even entries white */
		cg2_write(&G, CG2_CMAP + i, CG2_UDS | CG2_LDS, 0xffff);
		cg2_write(&G, CG2_CMAP + i + 2, CG2_UDS | CG2_LDS, 0);
	}
	bwr(CG2_STATUS + 1, brd(CG2_STATUS + 1) | 0x02);	/* bset #1: update_cmap */
	while (status_lo() & 0x80)			/* btst #7 three times */
		;
	while (!(status_lo() & 0x80))
		;
	while (status_lo() & 0x80)
		;
	bwr(CG2_STATUS + 1, brd(CG2_STATUS + 1) & ~0x02);	/* bclr #1 */
	cg2_write(&G, CG2_ZOOM, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, CG2_WORDPAN, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, CG2_PIXPAN, CG2_UDS | CG2_LDS, 0);
	cg2_write(&G, CG2_VARZOOM, CG2_UDS | CG2_LDS, 0xff);
	cg2_write(&G, CG2_STATUS, CG2_UDS | CG2_LDS, 0);	/* the word at 0xEF75DC */
	bwr(CG2_STATUS + 1, brd(CG2_STATUS + 1) | 0x01);	/* bset #0: video on */
	bad += (brd(CG2_STATUS) & 15) != 0;			/* resolution: 1152x900 */
	bad += !(cg2_read(&G, CG2_STATUS, CG2_UDS | CG2_LDS) & CG2S_VIDEO_EN);
	for (int c = 0; c < 3; c++)
		for (int i = 0; i < 256; i++)
			bad += G.active[c][i] != (i & 1 ? 0 : 0xff);
	/* a console glyph row into plane 0 at (16,2): black where set */
	cg2_write(&G, CG2_PLANE_BASE + 2 * 144 + 2, CG2_UDS | CG2_LDS, 0x3c66);
	for (int j = 0; j < 16; j++) {
		uint8_t px = G.pix[2 * CG2_W + 16 + j];

		bad += (px & 1) != (0x3c66 >> (15 - j) & 1);
		bad += G.active[0][px] != ((0x3c66 >> (15 - j) & 1) ? 0 : 0xff);
	}
	result("PROM init_scolor and a console row in plane 0", bad);

	/* cgtwoattach: clrw dblbuf; bset #1 (wait); a retrace; btst #1 */
	bad = 0;
	cg2_write(&G, CG2_WORDPAN, CG2_UDS | CG2_LDS, 0);
	bwr(CG2_WORDPAN, brd(CG2_WORDPAN) | 0x02);
	while (status_lo() & 0x80)
		;
	while (!(status_lo() & 0x80))
		;
	while (status_lo() & 0x80)
		;
	bad += !(brd(CG2_WORDPAN) & 0x02);	/* still set: a Sun-2 board */
	bad += (brd(CG2_STATUS) & 0x30) != 0;	/* no fastread, no id */
	result("cgtwoattach finds a Sun-2 colour board", bad);
	cg2_reset(&G);
}

/* a random rectangle in a w x h pixrect, sometimes reaching outside it */
static void rect(int bw, int bh, int *x, int *y, int *w, int *h)
{
	int big = rn(8) == 0;

	*w = 1 + rn(big ? bw : rn(4) ? 40 : 200);
	*h = 1 + rn(big ? bh : rn(4) ? 20 : 100);
	*x = rn(bw + 40) - 20;
	*y = rn(bh + 40) - 20;
}

static int random_op(void)
{
	return rn(16) << 1 | PIX_COLOR(rn(4) ? rn(256) : 0);
}

static int random_planes(void)
{
	return rn(4) ? 255 : rn(256);
}

/* the destination: the whole screen, or now and then a region of it */
static struct region random_region(void)
{
	struct region r = SCREEN;

	if (!kernel && rn(4) == 0) {
		r.ox = rn(CG2_W - 1);
		r.oy = rn(CG2_H - 1);
		r.w = 1 + rn(CG2_W - r.ox);
		r.h = 1 + rn(CG2_H - r.oy);
	}
	return r;
}

/* the same region of the mirror, as a mem_region (the kernel has none) */
static uint32_t mirror_region(const struct region *r)
{
	return kernel ? M : call("_mem_region", 5, M, r->ox, r->oy, r->w, r->h);
}

static void mirror_region_free(uint32_t mr)
{
	if (mr != M)
		call("_mem_destroy", 1, mr);
}

/* a 1-bit or 8-bit memory pixrect of random content */
static uint32_t random_mpr(int w, int h, int depth, int rv)
{
	uint32_t pr = mem_create(w, h, depth);

	fill_random(image(pr), linebytes(pr) * h);
	if (rv)
		wr16(md(pr) + MD_FLAGS, MP_REVERSEVIDEO);
	return pr;
}

static struct refsrc mpr_src(uint32_t pr)
{
	return (struct refsrc){ image(pr), linebytes(pr), rd32(pr + PR_W), rd32(pr + PR_H),
				rd32(pr + PR_DEPTH), rd16(md(pr) + MD_FLAGS) & MP_REVERSEVIDEO };
}

/*
 * The directed pass sets these: a kind of source, an op that needs no
 * destination, and a rectangle wide and short.  That is the combination
 * that takes cg2_rop down its ropmode-swapping paths (PWRWRD/PRRWRD,
 * PWWWRD/PRWWRD, SWWPIX/SRWPIX), which random rectangles reach rarely.
 */
static int force_kind = -1, force_op = -1;

static void test_rop(void)
{
	struct region r = force_kind >= 0 ? SCREEN : random_region();
	int x, y, w, h, sx = 0, sy = 0, op = random_op(), planes = random_planes();
	int kind = force_kind >= 0 ? force_kind : rn(7);
	uint32_t dpr = cg2pr(planes, r.ox, r.oy, r.w, r.h), mr = mirror_region(&r), spr = 0;
	struct refsrc rs;
	char what[200];

	rect(r.w, r.h, &x, &y, &w, &h);
	if (force_op >= 0) {
		op = force_op << 1 | PIX_COLOR(rn(256));
		w = 100 + rn(600);
		h = 1 + rn(6);
		x = rn(CG2_W - w);
		y = rn(CG2_H - 30);
	}
	memcpy(before, G.pix, sizeof before);
	memcpy(ref, before, sizeof ref);
	switch (kind) {
	case 0:		/* fill */
		snprintf(what, sizeof what, "fill");
		setcat(what);
		call("_cg2_rop", 9, dpr, x, y, w, h, op, 0, 0, 0);
		call("_mem_rop", 9, mr, x, y, w, h, op, 0, 0, 0);
		ref_op(&r, x, y, w, h, op, NULL, 0, 0, NULL, 0, 0, planes);
		break;
	case 1:		/* screen to screen, overlapping as often as not */
		sx = rn(2) ? x + rn(41) - 20 : rn(r.w);
		sy = rn(2) ? y + rn(21) - 10 : rn(r.h);
		snprintf(what, sizeof what, "copy");
		setcat(what);
		call("_cg2_rop", 9, dpr, x, y, w, h, op, dpr, sx, sy);
		call("_mem_rop", 9, mr, x, y, w, h, op, mr, sx, sy);
		rs = screen_src(&r);
		ref_op(&r, x, y, w, h, op, &rs, sx, sy, NULL, 0, 0, planes);
		break;
	case 2:		/* 8-bit memory to screen */
	case 3:		/* 1-bit memory to screen */
	case 4:		/* 1-bit, reverse video */
	case 5: {	/* a 1x1 source: cg2_rop turns it into a fill */
		int depth = kind == 2 ? 8 : kind == 5 ? (rn(2) ? 8 : 1) : 1;
		int sw = kind == 5 ? 1 : w + rn(40), shh = kind == 5 ? 1 : h + rn(20);

		spr = random_mpr(sw, shh, depth, kind == 4);
		sx = kind == 5 ? 0 : rn(sw - w + 1);
		sy = kind == 5 ? 0 : rn(shh - h + 1);
		snprintf(what, sizeof what, "%s", kind == 5 ? (depth == 8 ? "1x1 mem8" : "1x1 mem1") :
			 depth == 8 ? "mem8" : kind == 4 ? "mem1rv" : "mem1");
		setcat(what);
		call("_cg2_rop", 9, dpr, x, y, w, h, op, spr, sx, sy);
		call("_mem_rop", 9, mr, x, y, w, h, op, spr, sx, sy);
		rs = mpr_src(spr);
		ref_op(&r, x, y, w, h, op, &rs, sx, sy, NULL, 0, 0, planes);
		break;
	}
	case 6: {	/* screen to memory: the board read back */
		int dw = w + rn(40), dh = h + rn(20);
		uint32_t a = random_mpr(dw, dh, 8, 0), b = mem_create(dw, dh, 8);
		int bad = 0;

		/*
		 * PIX_SRC only.  Any other op takes cg2_rop's detour through
		 * a temporary, and the 4.0 library's copy of that path is
		 * broken: the copy loop keeps the caller's mpr_data (in a2,
		 * fetched before mem_create), so the raw pixels land at (0,0)
		 * of the caller's pixrect and the op is applied from a zeroed
		 * temporary.  4.1.4's source has the missing reassignment.
		 */
		op = PIX_SRC | (op & ~0x1f);
		memcpy(image(b), image(a), linebytes(a) * dh);
		sx = rn(dw - w + 1);
		sy = rn(dh - h + 1);
		snprintf(what, sizeof what, "readback");
		setcat(what);
		call("_cg2_rop", 9, a, sx, sy, w, h, op, dpr, x, y);
		{
			/* the reference: b, with the screen's pixels copied in */
			struct cp p[2] = { { sx, sy, dw, dh }, { x, y, r.w, r.h } };
			int cw = w, ch = h;

			if (clip(&cw, &ch, p, 2))
				for (int j = 0; j < ch; j++)
					memcpy(image(b) + (p[0].y + j) * linebytes(b) + p[0].x,
					       before + (r.oy + p[1].y + j) * CG2_W + r.ox + p[1].x, cw);
		}
		for (int i = 0; i < linebytes(a) * dh; i++)
			bad += image(a)[i] != image(b)[i];
		{
			char full[260];

			snprintf(full, sizeof full, "readback op %x dst (%d,%d) %dx%d src (%d,%d) region %d,%d %dx%d",
				 op >> 1 & 15, sx, sy, w, h, x, y, r.ox, r.oy, r.w, r.h);
			result(full, bad);
		}
		call("_mem_destroy", 1, a);
		call("_mem_destroy", 1, b);
		snprintf(what, sizeof what, "readback left the screen alone");
		planes = 0xff;
		break;
	}
	}
	{
		char full[300];

		snprintf(full, sizeof full, "%s op %x color %02x dst (%d,%d) %dx%d src (%d,%d) "
			 "planes %02x region %d,%d %dx%d", what, op >> 1 & 15, op >> 5,
			 x, y, w, h, sx, sy, planes, r.ox, r.oy, r.w, r.h);
		compare_ref(full, planes);
	}
	if (spr)
		call("_mem_destroy", 1, spr);
	mirror_region_free(mr);
	cg2pr_free(dpr);
}

/* pr_stencil: op where the stencil is set, with or without a source */
static void test_stencil(void)
{
	struct region r = random_region();
	int x, y, w, h, op = random_op(), planes = random_planes();
	int kind = rn(5), sx = 0, sy = 0, stx, sty;
	uint32_t dpr = cg2pr(planes, r.ox, r.oy, r.w, r.h), mr = mirror_region(&r), spr = 0, st;
	struct refsrc rs, rst;
	char what[300];

	rect(r.w, r.h, &x, &y, &w, &h);
	memcpy(before, G.pix, sizeof before);
	memcpy(ref, before, sizeof ref);
	{
		int sw = w + rn(40), shh = h + rn(20);

		st = random_mpr(sw, shh, 1, rn(4) == 0);
		stx = rn(sw - w + 1);
		sty = rn(shh - h + 1);
		rst = mpr_src(st);
	}
	if (kind) {	/* 1: 8-bit, 2: 1-bit, 3: 1-bit reverse, 4: 1x1 */
		int depth = kind == 1 ? 8 : kind == 4 ? (rn(2) ? 8 : 1) : 1;
		int sw = kind == 4 ? 1 : w + rn(40), shh = kind == 4 ? 1 : h + rn(20);

		spr = random_mpr(sw, shh, depth, kind == 3);
		sx = kind == 4 ? 0 : rn(sw - w + 1);
		sy = kind == 4 ? 0 : rn(shh - h + 1);
		rs = mpr_src(spr);
	}
	snprintf(what, sizeof what, "stencil%s %s op %x color %02x dst (%d,%d) %dx%d st (%d,%d) "
		 "src (%d,%d) planes %02x region %d,%d %dx%d", rst.rv ? "(rv)" : "",
		 (const char *[]){ "fill", "mem8", "mem1", "mem1rv", "1x1" }[kind],
		 op >> 1 & 15, op >> 5, x, y, w, h, stx, sty, sx, sy, planes, r.ox, r.oy, r.w, r.h);
	setcat(what);
		call("_cg2_stencil", 12, dpr, x, y, w, h, op, st, stx, sty, spr, sx, sy);
	call("_mem_stencil", 12, mr, x, y, w, h, op, st, stx, sty, spr, sx, sy);
	ref_op(&r, x, y, w, h, op, spr ? &rs : NULL, sx, sy, &rst, stx, sty, planes);
	compare_ref(what, planes);
	if (spr)
		call("_mem_destroy", 1, spr);
	call("_mem_destroy", 1, st);
	mirror_region_free(mr);
	cg2pr_free(dpr);
}

/* pr_batchrop: a line of glyphs, as text is drawn */
static void test_batch(void)
{
	struct region r = random_region();
	int n = 1 + rn(12), op = random_op(), planes = random_planes();
	int x = rn(r.w + 40) - 20, y = rn(r.h + 40) - 20;
	uint32_t dpr = cg2pr(planes, r.ox, r.oy, r.w, r.h), mr = mirror_region(&r);
	uint32_t list = h_alloc(12 * n), glyph[16];
	struct refsrc rs[16];
	char what[200];
	int cx = x, cy = y;

	memcpy(before, G.pix, sizeof before);
	memcpy(ref, before, sizeof ref);
	for (int i = 0; i < n; i++) {
		/* mostly the 16-wide glyphs the fast path takes, some it doesn't */
		int gw = rn(8) ? 1 + rn(16) : 17 + rn(20), gh = 1 + rn(24);
		int dx = rn(20) - 2, dy = rn(4) ? 0 : rn(9) - 4;

		/*
		 * No NULL entries: cg2_batchrop (4.0 and 4.1.4 alike) `continue's
		 * on one before advancing the list pointer, so the same entry is
		 * re-read for every remaining count and nothing after it is drawn.
		 */
		glyph[i] = random_mpr(gw, gh, 1, rn(10) == 0);
		wr32(list + 12 * i, glyph[i]);
		wr32(list + 12 * i + 4, dx);
		wr32(list + 12 * i + 8, dy);
		cx += dx;
		cy += dy;
		if (glyph[i]) {
			rs[i] = mpr_src(glyph[i]);
			ref_op(&r, cx, cy, gw, gh, op, &rs[i], 0, 0, NULL, 0, 0, planes);
		}
	}
	snprintf(what, sizeof what, "batch of %d op %x color %02x at (%d,%d) planes %02x "
		 "region %d,%d %dx%d", n, op >> 1 & 15, op >> 5, x, y, planes, r.ox, r.oy, r.w, r.h);
	setcat(what);
		call("_cg2_batchrop", 6, dpr, x, y, op, list, n);
	call("_mem_batchrop", 6, mr, x, y, op, list, n);
	if (compare_ref(what, planes) && verbose > 1) {
		cx = x;
		cy = y;
		for (int i = 0; i < n; i++) {
			cx += (int32_t)rd32(list + 12 * i + 4);
			cy += (int32_t)rd32(list + 12 * i + 8);
			fprintf(stderr, "  glyph %d at (%d,%d) %dx%d lb %d%s\n", i, cx, cy,
				rs[i].w, rs[i].h, rs[i].lb, rs[i].rv ? " rv" : "");
		}
	}
	for (int i = 0; i < n; i++)
		if (glyph[i])
			call("_mem_destroy", 1, glyph[i]);
	h_free(list);
	mirror_region_free(mr);
	cg2pr_free(dpr);
}

/* pr_vector: which pixels a line covers is the library's own business,
   so mem_vector is the reference here */
static void test_vector(void)
{
	int op = random_op(), color = rn(256), planes = 255;
	int x0 = rn(CG2_W + 200) - 100, y0 = rn(CG2_H + 200) - 100, x1, y1;
	uint32_t dpr = cg2pr(planes, 0, 0, CG2_W, CG2_H);
	char what[200];

	switch (rn(4)) {
	case 0: x1 = x0; y1 = rn(CG2_H + 200) - 100; break;		/* vertical */
	case 1: y1 = y0; x1 = rn(CG2_W + 200) - 100; break;		/* horizontal */
	case 2: x1 = x0 + rn(3) - 1; y1 = y0 + rn(3) - 1; break;	/* a point or two */
	default: x1 = rn(CG2_W + 200) - 100; y1 = rn(CG2_H + 200) - 100;
	}
	memcpy(before, G.pix, sizeof before);
	snprintf(what, sizeof what, "vector op %x color %02x/%02x (%d,%d)-(%d,%d)",
		 op >> 1 & 15, op >> 5, color, x0, y0, x1, y1);
	setcat(what);
		call("_cg2_vector", 7, dpr, x0, y0, x1, y1, op, color);
	call("_mem_vector", 7, M, x0, y0, x1, y1, op, color);
	compare_mem(what);
	cg2pr_free(dpr);
}

/* pr_get, pr_put and pr_polypoint */
static void test_points(void)
{
	struct region r = random_region();
	int planes = random_planes();
	uint32_t dpr = cg2pr(planes, r.ox, r.oy, r.w, r.h), mr = mirror_region(&r);
	char what[200];
	int bad = 0;

	memcpy(before, G.pix, sizeof before);
	memcpy(ref, before, sizeof ref);
	if (rn(2)) {
		for (int i = 0; i < 20; i++) {
			int x = rn(r.w + 4) - 2, y = rn(r.h + 4) - 2, v = rn(256);
			int inside = x >= 0 && y >= 0 && x < r.w && y < r.h;
			uint8_t *d = &ref[(r.oy + y) * CG2_W + r.ox + x];
			uint32_t got;

			if (rn(2)) {
				setcat("put");
				call("_cg2_put", 4, dpr, x, y, v);
				call("_mem_put", 4, mr, x, y, v);
				if (inside)
					*d = (v & planes) | (*d & ~planes);
			} else {
				setcat("get");
				got = call("_cg2_get", 3, dpr, x, y);
				if (got != (inside ? *d : 0xffffffffu))
					bad++, fprintf(stderr, "  get (%d,%d): %x, want %x\n",
						       x, y, got, inside ? *d : 0xffffffffu);
			}
		}
		snprintf(what, sizeof what, "get/put planes %02x region %d,%d %dx%d",
			 planes, r.ox, r.oy, r.w, r.h);
		result(what, bad);
	} else {
		int n = 1 + rn(30), op = random_op(), ox = rn(40) - 20, oy = rn(40) - 20;
		uint32_t pts = h_alloc(8 * n);

		for (int i = 0; i < n; i++) {
			int px = rn(r.w + 40) - 20, py = rn(r.h + 40) - 20;

			wr32(pts + 8 * i, px);
			wr32(pts + 8 * i + 4, py);
			ref_op(&r, ox + px, oy + py, 1, 1, op, NULL, 0, 0, NULL, 0, 0, planes);
		}
		snprintf(what, sizeof what, "polypoint of %d op %x color %02x planes %02x "
			 "region %d,%d %dx%d", n, op >> 1 & 15, op >> 5, planes, r.ox, r.oy, r.w, r.h);
		setcat(what);
		call("_cg2_polypoint", 6, dpr, ox, oy, n, pts, op);
		call("_mem_polypoint", 6, mr, ox, oy, n, pts, op);
		h_free(pts);
	}
	compare_ref(what, planes);
	mirror_region_free(mr);
	cg2pr_free(dpr);
}

/* the colour map: written through the shadow, live at the next retrace */
static void test_colormap(void)
{
	uint32_t dpr = cg2pr(255, 0, 0, CG2_W, CG2_H), rgb = h_alloc(3 * 256), out = h_alloc(3 * 256);
	int index = rn(256), count = 1 + rn(256 - index), bad = 0;
	uint8_t want[3][256], old[3][256];
	char what[100];

	memcpy(old, G.active, sizeof old);
	memcpy(want, G.active, sizeof want);
	fill_random(&ram[rgb], 3 * 256);
	setcat("putcolormap");
	call("_cg2_putcolormap", 6, dpr, index, count, rgb, rgb + 256, rgb + 512);
	for (int c = 0; c < 3; c++)
		for (int i = 0; i < count; i++)
			want[c][index + i] = ram[rgb + 256 * c + i];
	/* nothing reaches the DACs until a retrace begins */
	bad += memcmp(G.active, old, sizeof old) != 0;
	/* a whole retrace: the polling display may have left the bit high */
	cg2_retrace(&G, 0);
	cg2_retrace(&G, 1);
	cg2_retrace(&G, 0);
	bad += memcmp(G.active, want, sizeof want) != 0;
	if (!kernel) {		/* the kernel has no cg2_getcolormap */
		setcat("getcolormap");
		call("_cg2_getcolormap", 6, dpr, index, count, out, out + 256, out + 512);
		for (int c = 0; c < 3; c++)
			bad += memcmp(&ram[out + 256 * c], &ram[rgb + 256 * c], count) != 0;
	}
	snprintf(what, sizeof what, "colour map %d..%d", index, index + count - 1);
	result(what, bad);
	h_free(rgb);
	h_free(out);
	cg2pr_free(dpr);
}

/*
 * -k: the 4.0 kernel's own cgtwoprobe and cgtwoattach (cgtwo.o from the Sys
 * tape), run on the model: the probe must accept the board and the attach
 * must find a Sun-2 board and program the interrupt vector.
 */
static void test_driver(void)
{
	uint32_t vec = h_alloc(16), drv = h_alloc(64), mdev = h_alloc(64), name = h_alloc(8);
	int bad = 0;
	uint32_t r;

	/*
	 * No cg2_reset here: this runs inside the traced region, so the RTL
	 * replay sees the real probe and attach, and the RTL cannot follow a
	 * reset of the model's pixels.
	 */
	memcpy(&ram[name], "cgtwo", 6);
	memset(&ram[drv], 0, 64);
	memset(&ram[mdev], 0, 64);
	memset(&ram[vec], 0, 16);
	wr32(drv + 28, name);		/* mdr_dname */
	wr32(mdev + 0, drv);		/* md_driver */
	wr16(mdev + 4, 0);		/* md_unit */
	wr32(mdev + 24, vec);		/* md_intr */
	wr32(vec + 4, 0xa8);		/* v_vec */
	setcat("cgtwoprobe");
	r = call("_cgtwoprobe", 2, FB_VA, 0);
	setcat("cgtwoattach");
	if (r != 0x110600)
		bad++, fprintf(stderr, "  cgtwoprobe returned %x\n", r);
	call("_cgtwoattach", 1, mdev);
	if ((G.intvec & 0xff) != 0xa8)
		bad++, fprintf(stderr, "  interrupt vector %x\n", G.intvec);
	if ((rd32(sym("_cg2_softc")) & 0x301) != 0x101)	/* STDRES | ZOOM, not NOZOOM */
		bad++, fprintf(stderr, "  softc flags %x\n", rd32(sym("_cg2_softc")));
	result("4.0 kernel cgtwoprobe and cgtwoattach", bad);
}

static const char *initf, *finalf;

static void dump_pixels(const char *path)
{
	FILE *f = fopen(path, "wb");

	if (!f || fwrite(G.pix, 1, sizeof G.pix, f) != sizeof G.pix)
		die("can't write %s", path);
	fclose(f);
}

int main(int argc, char **argv)
{
	long iters = 2000;
	const char *img = NULL, *symf = NULL;
	FILE *f;
	size_t n;

	for (int i = 1; i < argc; i++) {
		if (!strcmp(argv[i], "-n") && i + 1 < argc)
			iters = atol(argv[++i]);
		else if (!strcmp(argv[i], "-s") && i + 1 < argc)
			rs = strtoull(argv[++i], NULL, 0) * 2654435761ull + 1;
		else if (!strcmp(argv[i], "-t") && i + 1 < argc)
			trace = fopen(argv[++i], "w");
		else if (!strcmp(argv[i], "-I") && i + 1 < argc)
			initf = argv[++i];
		else if (!strcmp(argv[i], "-F") && i + 1 < argc)
			finalf = argv[++i];
		else if (!strcmp(argv[i], "-S"))
			stats = 1;
		else if (!strcmp(argv[i], "-k"))
			kernel = 1;
		else if (!strcmp(argv[i], "-vv"))
			verbose = 2;
		else if (!strcmp(argv[i], "-v"))
			verbose = 1;
		else if (!img)
			img = argv[i];
		else
			symf = argv[i];
	}
	if (!img || !symf) {
		fprintf(stderr, "usage: harness IMAGE.bin IMAGE.sym [-n N] [-s SEED] [-t TRACE] [-v]\n");
		return 2;
	}
	if (!(f = fopen(img, "rb")))
		die("can't open %s", img);
	n = fread(&ram[IMAGE_BASE], 1, HEAP_BASE - IMAGE_BASE, f);
	fclose(f);
	if (n == HEAP_BASE - IMAGE_BASE)
		die("image too big");
	load_syms(symf);

	/* vectors: every exception lands on CRASH_ADDR */
	wr32(0, STACK_TOP);
	wr32(4, RET_ADDR);
	for (uint32_t v = 8; v < 0x400; v += 4)
		wr32(v, CRASH_ADDR);
	wr16(RET_ADDR, 0x4afc);
	wr16(CRASH_ADDR, 0x4afc);

	m68k_init();
	m68k_set_cpu_type(M68K_CPU_TYPE_68010);
	m68k_set_illg_instr_callback(illegal);
	m68k_pulse_reset();
	heap_init();

	test_probe();
	test_prom();

	cg2_reset(&G);
	fill_random(G.pix, sizeof G.pix);
	M = mem_create(CG2_W, CG2_H, 8);
	sync_mirror();

	/*
	 * -t with -I and -F is what the RTL bench replays: every bus cycle from
	 * here on, the board's whole megabyte now, and the same at the end.
	 */
	if (initf)
		dump_pixels(initf);
	tracing = 1;
	if (kernel)
		test_driver();
	sync_mirror();

	/* the directed pass: every source kind with each op that needs no
	   destination (clear, ~src, src, set), wide and short */
	for (force_kind = 0; force_kind < 7; force_kind++)
		for (int o = 0; o < 4; o++)
			for (int i = 0; i < 12; i++) {
				force_op = (int[]){ 0x0, 0x3, 0xc, 0xf }[o];
				test_rop();
			}
	force_kind = force_op = -1;
	for (long i = 0; i < iters; i++)
		switch (kernel ? rn(10) ? 0 : 19 : rn(20)) {
		case 0: case 1: case 2: case 3: case 4: case 5: case 6: case 7:
			test_rop(); break;
		case 8: case 9: case 10: case 11:
			test_stencil(); break;
		case 12: case 13: case 14:
			test_batch(); break;
		case 15: case 16:
			test_vector(); break;
		case 17: case 18:
			test_points(); break;
		default:
			test_colormap(); break;
		}

	printf("%lu tests, %lu failed; %lu board cycles (%lu longs), %lu model warnings; "
	       "mem_rop disagreed with pixrect semantics %lu times\n",
	       ntests, nfail, nboard, nlong, G.nwarn, nmemdis);
	if (stats)
		print_stats();
	if (finalf)
		dump_pixels(finalf);
	return nfail != 0;
}
