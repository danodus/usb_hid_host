# Icarus Verilog. oss-cad-suite must be on PATH (source its environment).
SRC = ../src
IVERILOG ?= iverilog
VVP ?= vvp

.PHONY: basic retry nopull badclass

basic: tb.vvp
	cd $(SRC) && $(VVP) -n ../sim/tb.vvp +TA=16

retry: tb.vvp
	cd $(SRC) && $(VVP) -n ../sim/tb.vvp +TA=16 +RETRY

nopull: tb.vvp
	cd $(SRC) && $(VVP) -n ../sim/tb.vvp +TA=16 +NOPULL

badclass: tb.vvp
	cd $(SRC) && $(VVP) -n ../sim/tb.vvp +TA=16 +BADCLASS

tb.vvp: tb_gamepad.v $(SRC)/usb_hid_host.v $(SRC)/usb_hid_host_rom.v $(SRC)/usb_hid_host_rom.hex
	$(IVERILOG) -g2012 -o tb.vvp tb_gamepad.v $(SRC)/usb_hid_host.v $(SRC)/usb_hid_host_rom.v
