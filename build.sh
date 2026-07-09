#!/usr/bin/env bash

CROSS_COMPILE=${CROSS_COMPILE:-arm-himix100-linux-}

for soc in gk7205v200 gk7205v300
do
    make distclean

    # The drivers/ddr/goke/default/cmd_bin/ Makefile lists COBJS
    # that include files from sibling directories without VPATH:
    #   ../ddr_training_{impl,ctl,console}.c
    #   ../../${SOC}/ddr_training_custom.c
    # The repo ships a prebuilt ddr_cmd.bin in cmd_bin/, but the
    # parent's `ddr_training_cmd_bin` target always re-invokes
    # the cmd_bin make, which then can't find those .c files.
    # Symlink them in so the rebuild succeeds.
    (
      cd drivers/ddr/goke/default/cmd_bin
      for f in ../ddr_training_impl.c ../ddr_training_ctl.c \
               ../ddr_training_console.c \
               ../../${soc}/ddr_training_custom.c; do
        ln -svf "$f" "$(basename "$f")"
      done
    )
    # cmd_bin's CFLAGS reference a HiSi-internal path
    # `$(TOPDIR)/../../../source/bootloader/u-boot/include` that
    # doesn't exist in this fork — patch it to use $(TOPDIR)/include
    # instead so command.h and friends resolve.
    sed -i 's|/\.\./\.\./\.\./source/bootloader/u-boot/include|/include|' \
      drivers/ddr/goke/default/cmd_bin/Makefile
    make CROSS_COMPILE="$CROSS_COMPILE" ${soc}_defconfig
    cp reg_info_${soc}.bin .reg
    # The arm-hisiv300-linux toolchain defaults to gnu90; the
    # source uses C99 idioms (for-loop init declarations). Pass
    # -std=gnu99 through Kbuild's KCFLAGS hook.
    make CROSS_COMPILE="$CROSS_COMPILE" -j$(nproc) KCFLAGS=-std=gnu99 V=1
    # The HW gzip decompressor on real Goke V4 silicon only
    # parses streams compressed with WSIZE=8 KiB (vs system
    # gzip's 32 KiB) — that's what HiSi's hi_gzip patch sets.
    # System gzip output produces "Uncompress Fail!" on real
    # silicon. Build hi_gzip and stage it where the SoC
    # Makefile expects (./gzip relative to its build dir).
    # tools/hi_gzip's Makefile uses bash builtins (popd); on
    # Ubuntu /bin/sh is dash, so invoke with SHELL=bash.
    if [ ! -f tools/hi_gzip/bin/gzip ]; then
      make -C tools/hi_gzip SHELL=/bin/bash
    fi
    cp -vf tools/hi_gzip/bin/gzip arch/arm/cpu/armv7/${soc}/gzip
    make CROSS_COMPILE="$CROSS_COMPILE" KCFLAGS=-std=gnu99 u-boot-z.bin
    cp -v u-boot-${soc}.bin u-boot-${soc}-universal.bin

    echo
done
