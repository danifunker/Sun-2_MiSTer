# The cgtwo model and the harness that runs SunOS's libpixrect against it.
#
#   make -C tools/cg2model            build, link the 4.0 library, run
#   make -C tools/cg2model run N=20000 SEED=7
#
# Needs gcc, git and python3 (WSL is fine) and the SunOS 4.0 Sun-2 tape set:
# TAPE40 is the directory holding tape1/ (the per-file dumps); libpixrect.a
# is ./lib/libpixrect.a in tape 1 file 8 (usr, a tar).  Nothing from the tape
# is copied into the tree; it is extracted into $(B).
#
# Musashi (MIT licence) is fetched at a pinned commit into $(B) as well.

TAPE40	?= /mnt/c/Temp/sunos_4.0_sun2
B	:= ../../build/cg2model
MUSASHI_URL := https://github.com/kstenerud/Musashi
MUSASHI_REV := 313ebf1bd9f4d0d93341eb5ce21fd8a119e9dbdd
MU	:= $(B)/musashi
N	?= 2000
SEED	?= 1

CC	?= gcc
CFLAGS	:= -O2 -g -Wall -Wno-unused-function -I$(MU) -I. \
	   -DM68K_ILLG_HAS_CALLBACK=M68K_OPT_ON

# what the harness calls, and what libpixrect must not reach on a bus model
ROOTS	:= _cg2_rop _cg2_stencil _cg2_batchrop _cg2_vector _cg2_get _cg2_put \
	   _cg2_polypoint _cg2_putcolormap _cg2_getcolormap _cg2_region _cg2_ops \
	   _mem_rop _mem_create _mem_destroy _mem_region _mem_stencil \
	   _mem_batchrop _mem_vector _mem_polypoint _mem_get _mem_put _mem_ops
STUBS	:= _gp1_sync _pr_makefromfd _pr_unmakefromfd

all: run

$(MU)/m68k.h:
	rm -rf $(MU)
	git clone -q $(MUSASHI_URL) $(MU)
	git -C $(MU) checkout -q $(MUSASHI_REV)

$(MU)/m68kops.c: $(MU)/m68k.h
	$(CC) -o $(MU)/m68kmake $(MU)/m68kmake.c
	cd $(MU) && ./m68kmake

MUOBJ	:= $(B)/m68kcpu.o $(B)/m68kops.o $(B)/m68kdasm.o $(B)/softfloat.o

$(B)/m68kcpu.o: $(MU)/m68kops.c
	$(CC) $(CFLAGS) -w -c -o $@ $(MU)/m68kcpu.c
$(B)/m68kops.o: $(MU)/m68kops.c
	$(CC) $(CFLAGS) -w -c -o $@ $(MU)/m68kops.c
$(B)/m68kdasm.o: $(MU)/m68kops.c
	$(CC) $(CFLAGS) -w -c -o $@ $(MU)/m68kdasm.c
$(B)/softfloat.o: $(MU)/m68kops.c
	$(CC) $(CFLAGS) -w -c -o $@ $(MU)/softfloat/softfloat.c

$(B)/harness: harness.c cg2model.c cg2model.h $(MUOBJ)
	$(CC) $(CFLAGS) -o $@ harness.c cg2model.c $(MUOBJ) -lm

$(B)/libpixrect40.a:
	mkdir -p $(B)/tape
	tar -xf $(TAPE40)/tape1/08 -C $(B)/tape ./lib/libpixrect.a
	cp $(B)/tape/lib/libpixrect.a $@

$(B)/lp40.bin: $(B)/libpixrect40.a aoutlink.py
	python3 aoutlink.py -o $(B)/lp40 --lib $< \
	    $(addprefix --root ,$(ROOTS)) $(addprefix --stub ,$(STUBS))

# The kernel's own pixrect code and the cgtwo driver, from the Sys tape
# (tape 1 file 9, ./share/sys/sun2/OBJ), with mem_create from the library
# for the harness's test pixrects.
KOBJS	:= cgtwo.o cg2_rop.o cg2_colormap.o mem_rop.o mem_kern.o mem_colormap.o \
	   pr_clip.o pr_reverse.o
KROOTS	:= _cgtwoprobe _cgtwoattach _cg2_rop _cg2_putcolormap _cg2_ops \
	   _mem_rop _mem_create _mem_destroy _mem_ops

$(B)/k40/cgtwo.o:
	mkdir -p $(B)/k40
	tar -xf $(TAPE40)/tape1/09 -C $(B)/k40 $(addprefix ./share/sys/sun2/OBJ/,$(KOBJS))
	cp $(addprefix $(B)/k40/share/sys/sun2/OBJ/,$(KOBJS)) $(B)/k40/

$(B)/kern40.bin: $(B)/k40/cgtwo.o $(B)/libpixrect40.a aoutlink.py
	python3 aoutlink.py -o $(B)/kern40 $(addprefix --obj $(B)/k40/,$(KOBJS)) \
	    --lib $(B)/libpixrect40.a $(addprefix --root ,$(KROOTS)) --stub _gp1_sync

run: $(B)/harness $(B)/lp40.bin $(B)/kern40.bin
	$(B)/harness $(B)/lp40.bin $(B)/lp40.sym -n $(N) -s $(SEED)
	$(B)/harness $(B)/kern40.bin $(B)/kern40.sym -k -n $(N) -s $(SEED)

clean:
	rm -f $(B)/harness $(B)/*.o $(B)/lp40.* $(B)/kern40.*

.PHONY: all run clean
