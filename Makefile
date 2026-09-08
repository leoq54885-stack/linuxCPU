.DEFAULT_GOAL := help
SIM ?= verilator
ifneq ($(filter $(SIM),verilator cadence),$(SIM))
$(error SIM must be verilator or cadence)
endif

.PHONY: help setup doctor smoke smoke-rebuild smoke-clint perf-smoke dts linux firmware rtl-linux rtl-linux-iverilog build run run-iverilog status
.PHONY: cadence-package build-cadence run-cadence probe-cadence check-cadence test-cadence

help:
	@echo "linuxCPU targets:"
	@echo "  make setup          Fetch pinned sources and local tools"
	@echo "  make doctor         Validate versions and tools"
	@echo "  make smoke          Run the OpenC906 MMU RTL baseline"
	@echo "  make smoke-rebuild  Re-elaborate RTL, then run baseline"
	@echo "  make smoke-clint    Verify C906's 32-bit CLINT mtimecmp path"
	@echo "  make perf-smoke     Run a bounded RTL boot-speed probe and save JSON metrics"
	@echo "  make dts            Compile and round-trip check the smart_run DTS"
	@echo "  make linux          Build minimal kernel with embedded PID 1"
	@echo "  make firmware       Build OpenSBI + Linux + embedded DTB"
	@echo "  make rtl-linux      Build Linux-capable OpenC906 RTL with Verilator"
	@echo "  make run            Run Linux on OpenC906 RTL with Verilator"
	@echo "  make build/run SIM=cadence  Select Cadence (default SIM=verilator)"
	@echo "  make cadence-package  Build software and create an offline Cadence bundle"
	@echo "  make probe-cadence  Run a bounded Cadence probe (default 120 seconds)"
	@echo "  make check-cadence  Verify the selected Cadence bundle"
	@echo "  make test-cadence   Test packaging and launcher without Cadence"
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

perf-smoke:
	@./scripts/smoke-verilator-performance.sh

dts:
	@./scripts/build-dtb.sh

build:
ifeq ($(SIM),cadence)
	@bash ./scripts/cadence.sh build
else
	@./build.sh rtl-linux
endif

cadence-package:
	@bash ./scripts/cadence.sh package

build-cadence:
	@bash ./scripts/cadence.sh build

run-cadence:
	@bash ./scripts/cadence.sh run

probe-cadence:
	@bash ./scripts/cadence.sh probe

check-cadence:
	@bash ./scripts/cadence.sh check

test-cadence:
	@python3 ./scripts/cadence/test_runner.py
	@python3 ./scripts/cadence/test_package.py

linux:
	@./build.sh linux

firmware:
	@./build.sh firmware

rtl-linux:
	@./build.sh rtl-linux

rtl-linux-iverilog:
	@./build.sh rtl-linux-iverilog

run:
ifeq ($(SIM),cadence)
	@bash ./scripts/cadence.sh run
else
	@./run.sh linux
endif

run-iverilog:
	@./run.sh linux-iverilog

status:
	@git status --short --branch
	@for repo in openc906 opensbi linux buildroot; do \
		echo "[$$repo] $$(git -C $$repo rev-parse --short HEAD)"; \
		git -C $$repo status --short; \
	done
