#!/usr/bin/env bash

OUTPUT=${OUTPUT:-$PWD/output}
XOPT=${XOPT:-V=1}
TARGET_BOARD=$1

for dts in `ls arch/arm/dts/*.dts`
do
    chip_ids=($(grep -m1 -o '"goke,gk7[0-9]\+v[0-9]\+";' $dts | sed 's/[",;]/ /g'))
    test ${#chip_ids[@]} -ne 2 && continue

    # vendor=${chip_ids[0]}
    soc=${chip_ids[1]}

    board=$(grep -m1 'compatible' $dts | awk -F ',' '{print $2}' | sed 's/[",;]//g')
    test -n "$TARGET_BOARD" -a "$TARGET_BOARD" != $board && continue

    for tc in arm-openipc-linux-musleabi- \
        arm-linux-musleabi- \
        arm-linux-gnueabi- \
        arm-linux- \
        arm-none-eabi-
    do
        for out in $PWD/output $(dirname $PWD)/output $OUTPUT
        do
            path=$out/$soc/host/bin
            if test -e $path/${tc}gcc; then
                toolchain=$path/$tc
                break
            fi
        done

        test -n "$toolchain" && break

        if which ${tc}gcc > /dev/null; then
            toolchain=$tc
            break
        fi
    done

    if [ -z "$toolchain" ]; then
        echo "No toolchain found for $soc!"
        echo "Skip to build u-boot for $board!"
        echo
        continue
    fi

    echo "Building u-boot for $board ($soc) ..."

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
    make CROSS_COMPILE="$toolchain" ${soc}_defconfig
    cp reg_info_${soc}.bin .reg
    dtb=$(basename ${dts%.dts})
    # The arm-hisiv300-linux toolchain defaults to gnu90; the
    # source uses C99 idioms (for-loop init declarations). Pass
    # -std=gnu99 through Kbuild's KCFLAGS hook.
    make CROSS_COMPILE="$toolchain" KCFLAGS=-std=gnu99 DEVICE_TREE=$dtb $XOPT || exit 1
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
    make CROSS_COMPILE="$toolchain" KCFLAGS=-std=gnu99 u-boot-z.bin || exit 1
    # cp -v u-boot-${soc}.bin u-boot-${soc}-universal.bin

    mkdir -vp $OUTPUT/$soc
    cp -v u-boot-${soc}.bin $OUTPUT/$soc/u-boot-${board}.bin

    echo
    test -n "$TARGET_BOARD" -a "$TARGET_BOARD" == $board && break
done
