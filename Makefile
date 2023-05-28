all : everything

DTC:=buildroot/output/host/bin/dtc

buildroot :
	git clone https://github.com/jdmichaud/buildroot-riscv --recurse-submodules --depth 1 buildroot

toolchain : buildroot
	cp -a configs/custom_kernel_config buildroot/kernel_config
	cp -a configs/buildroot_config buildroot/.config
	cp -a configs/busybox_config buildroot/busybox_config
	make -C buildroot

configs/minimal.dtb : configs/minimal.dts $(DTC)
	$(DTC) -I dts -O dtb -o $@ $< -S 2048

# Trick for extracting the DTB from
dtbextract : $(DTC)
	# Need 	sudo apt  install device-tree-compiler
	cd buildroot && output/host/bin/qemu-system-riscv32 -cpu rv32,mmu=false -m 128M -machine virt -nographic -kernel output/images/Image -bios none -drive file=output/images/rootfs.ext2,format=raw,id=hd0 -device virtio-blk-device,drive=hd0 -machine dumpdtb=../dtb.dtb && cd ..
	$(DTC) -I dtb -O dts -o dtb.dts dtb.dtb
