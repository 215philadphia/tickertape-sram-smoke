# Host-software tests against the chip RTL (cocotb + Icarus). Reuses the chip testbench and models in ../../test.
# Usage: make -B          (HOST_DIR=<dir containing ttpfst/> to test another copy, as mutate.sh does)
SIM ?= icarus
FST ?= -fst
TOPLEVEL_LANG ?= verilog
SRC_DIR = $(abspath $(CURDIR)/../../src)
TEST_DIR = $(abspath $(CURDIR)/../../test)
HOST_DIR ?= $(abspath $(CURDIR)/..)
PROJECT_SOURCES = tt_um_tickertape_pfst.v pfst_chip.v pfst_core_sram.v

SIM_BUILD = sim_build/rtl
VERILOG_SOURCES += $(addprefix $(SRC_DIR)/,$(PROJECT_SOURCES))
COMPILE_ARGS += -DFUNCTIONAL
VERILOG_SOURCES += $(TEST_DIR)/models/RM_IHPSG13_1P_core_behavioral_bm_bist.v $(TEST_DIR)/models/RM_IHPSG13_1P_256x32_c2_bm_bist.v
COMPILE_ARGS += -I$(SRC_DIR)
VERILOG_SOURCES += $(TEST_DIR)/tb.v
TOPLEVEL = tb

COCOTB_TEST_MODULES = test_host_sim
export PYTHONPATH := $(HOST_DIR):$(CURDIR):$(TEST_DIR):$(PYTHONPATH)

include $(shell cocotb-config --makefiles)/Makefile.sim

# Fast tests without a simulator (protocol model + board-adapter stub)
.PHONY: pure
pure:
	cd $(CURDIR) && PYTHONPATH=$(HOST_DIR):$(TEST_DIR) python3 -m unittest test_pure
