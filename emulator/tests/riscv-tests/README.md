This container attemps to build a cross compiler and then build the riscv-tests set.

The `.config` for crosstool-NG file was generated this way:
```bash
# Follow this https://gist.github.com/franzflasch/02a8aeb2f6ec8e942b14ee9929db38e9
ct-ng riscv32-unknown-elf
ct-ng menuconfig
# Enable newlib build (C-library section)
# Enable "Build a multilib toolchain" (Target options section)

# Some URL are not up to date here
sed -e 's|CT_ISL_MIRRORS=.*$|CT_ISL_MIRRORS="https://libisl.sourceforge.io"|' \
    -e 's|CT_EXPAT_MIRRORS=.*$|CT_EXPAT_MIRRORS="https://github.com/libexpat/libexpat/releases/download/R_2_2_6"|' \
    -i .config
```

To retrieve the test, build the image, create the container and get the `isa`
folder with all the tests in it:
```bash
docker build . -t riscv/riscv-tests
id=$(docker create riscv/riscv-tests)
docker cp $id:/home/user/riscv-tests/isa .
docker rm -v $id
```

