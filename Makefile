.DEFAULT_GOAL := help

.PHONY: help setup doctor smoke smoke-rebuild smoke-clint dts linux firmware rtl-linux rtl-linux-iverilog build run run-iverilog status

help:
	@echo "linuxCPU targets:"
	@echo "  make setup          Fetch pinned sources and local tools"
	@echo "  make doctor         Validate versions and tools"
	@echo "  make smoke          Run the OpenC906 MMU RTL baseline"
	@echo "  make smoke-rebuild  Re-elaborate RTL, then run baseline"
	@echo "  make smoke-clint    Verify C906's 32-bit CLINT mtimecmp path"
	@echo "  make dts            Compile and round-trip check the smart_run DTS"
	@echo "  make linux          Build minimal kernel with embedded PID 1"
	@echo "  make firmware       Build OpenSBI + Linux + embedded DTB"
	@echo "  make rtl-linux      Build Linux-capable OpenC906 RTL with Verilator"
	@echo "  make run            Run Linux on OpenC906 RTL with Verilator"
	@echo "  make *-iverilog     Slow independent Icarus/VVP cross-check"
	@echo "  make status         Show project and upstream status"

setup:
	@./setup.sh

doctor:
	@./scripts/doctor.sh

smoke:
	@./scripts/smoke-c906.sh

smoke-rebuild:
	@./scripts/smoke-c906.sh --rebuild

smoke-clint:
	@./scripts/smoke-clint-mtimecmp.sh

dts:
	@./scripts/build-dtb.sh

build:
	@./build.sh rtl-linux

linux:
	@./build.sh linux

firmware:
	@./build.sh firmware

rtl-linux:
	@./build.sh rtl-linux

rtl-linux-iverilog:
	@./build.sh rtl-linux-iverilog

run:
	@./run.sh linux

run-iverilog:
	@./run.sh linux-iverilog

status:
	@git status --short --branch
	@for repo in openc906 opensbi linux buildroot; do \
		echo "[$$repo] $$(git -C $$repo rev-parse --short HEAD)"; \
		git -C $$repo status --short; \
	done
