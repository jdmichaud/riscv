FROM ubuntu:latest

RUN apt-get update && apt-get -y install cron curl git gzip vim
RUN apt-get install -y autoconf automake autotools-dev curl libmpc-dev \
  libmpfr-dev libgmp-dev libusb-1.0-0-dev gawk build-essential bison flex \
  texinfo gperf libtool patchutils bc zlib1g-dev device-tree-compiler \
  pkg-config libexpat-dev

RUN apt install -y unzip help2man libtool-bin libncurses-dev

# Install crosstool-NG to create the cross compiler.
RUN curl -sOL http://crosstool-ng.org/download/crosstool-ng/crosstool-ng-1.24.0.tar.xz
RUN tar -xf crosstool-ng-1.24.0.tar.xz && \
  cd crosstool-ng-1.24.0 && \
  ./configure && \
  make && \
  make install

RUN useradd -ms /bin/bash user
USER user
WORKDIR /home/user

# Build the riscv cross compiler
ADD .config .
RUN ct-ng build

ENV PATH=$PATH:/home/user/x-tools/riscv32-unknown-elf/bin

RUN git clone https://github.com/riscv-software-src/riscv-tests.git && \
  cd riscv-tests && \
  git submodule update --init --recursive && \
  autoconf && \
  ./configure --with-xlen=32 && \
  make

CMD bash

