## =============================================================================
## basys3.xdc — Constraint File for Autonomous Car Vision Pipeline
## Basys 3 (Artix-7 XC7A35T)
## =============================================================================

## ── Clock ─────────────────────────────────────────────────────────────────────
set_property PACKAGE_PIN W5 [get_ports clk_100]
set_property IOSTANDARD LVCMOS33 [get_ports clk_100]
create_clock -add -name sys_clk -period 10.00 -waveform {0 5} [get_ports clk_100]

## ── Reset (Center button BTNC) ────────────────────────────────────────────────
set_property PACKAGE_PIN U18 [get_ports rst_btn]
set_property IOSTANDARD LVCMOS33 [get_ports rst_btn]

## ── UART TX (to ESP32 RX) — using onboard USB-UART pin ───────────────────────
## Note: D4 goes to CP2102 USB-UART chip. For ESP32, use a Pmod pin instead.
## Using Pmod JC pin 1 for UART TX to ESP32
set_property PACKAGE_PIN K17 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]

## ── XCLK to Camera (25 MHz output) ───────────────────────────────────────────
## Pmod JC pin 2
set_property PACKAGE_PIN M18 [get_ports xclk]
set_property IOSTANDARD LVCMOS33 [get_ports xclk]

## ── SCCB (I2C-compatible camera config) ──────────────────────────────────────
## SIO_C → Pmod JC pin 3
set_property PACKAGE_PIN N17 [get_ports sio_c]
set_property IOSTANDARD LVCMOS33 [get_ports sio_c]
## SIO_D → Pmod JC pin 4 (bidirectional)
set_property PACKAGE_PIN P18 [get_ports sio_d]
set_property IOSTANDARD LVCMOS33 [get_ports sio_d]

## ── OV7670 VSYNC ──────────────────────────────────────────────────────────────
## Pmod JB pin 1
set_property PACKAGE_PIN A14 [get_ports ov_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports ov_vsync]

## ── AL422B FIFO Control Signals ───────────────────────────────────────────────
## FIFO_WRST_N → Pmod JB pin 2
set_property PACKAGE_PIN A16 [get_ports fifo_wrst_n]
set_property IOSTANDARD LVCMOS33 [get_ports fifo_wrst_n]

## FIFO_RRST_N → Pmod JB pin 3
set_property PACKAGE_PIN B15 [get_ports fifo_rrst_n]
set_property IOSTANDARD LVCMOS33 [get_ports fifo_rrst_n]

## FIFO_OE_N → Pmod JB pin 4
set_property PACKAGE_PIN B16 [get_ports fifo_oe_n]
set_property IOSTANDARD LVCMOS33 [get_ports fifo_oe_n]

## FIFO_RCK → Pmod JB pin 7
set_property PACKAGE_PIN A15 [get_ports fifo_rck]
set_property IOSTANDARD LVCMOS33 [get_ports fifo_rck]

## ── OV7670 / FIFO Data Bus D[7:0] → Pmod JA ──────────────────────────────────
## JA pins: J1(D0), L2(D1), J2(D2), G2(D3), H1(D4), K2(D5), H2(D6), G3(D7)
set_property PACKAGE_PIN J1 [get_ports {fifo_d[0]}]
set_property PACKAGE_PIN L2 [get_ports {fifo_d[1]}]
set_property PACKAGE_PIN J2 [get_ports {fifo_d[2]}]
set_property PACKAGE_PIN G2 [get_ports {fifo_d[3]}]
set_property PACKAGE_PIN H1 [get_ports {fifo_d[4]}]
set_property PACKAGE_PIN K2 [get_ports {fifo_d[5]}]
set_property PACKAGE_PIN H2 [get_ports {fifo_d[6]}]
set_property PACKAGE_PIN G3 [get_ports {fifo_d[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {fifo_d[*]}]

## ── LEDs (Debug) ──────────────────────────────────────────────────────────────
set_property PACKAGE_PIN U16 [get_ports {led[0]}]
set_property PACKAGE_PIN E19 [get_ports {led[1]}]
set_property PACKAGE_PIN U19 [get_ports {led[2]}]
set_property PACKAGE_PIN V19 [get_ports {led[3]}]
set_property PACKAGE_PIN W18 [get_ports {led[4]}]
set_property PACKAGE_PIN U15 [get_ports {led[5]}]
set_property PACKAGE_PIN U14 [get_ports {led[6]}]
set_property PACKAGE_PIN V14 [get_ports {led[7]}]
set_property PACKAGE_PIN V13 [get_ports {led[8]}]
set_property PACKAGE_PIN V3  [get_ports {led[9]}]
set_property PACKAGE_PIN W3  [get_ports {led[10]}]
set_property PACKAGE_PIN U3  [get_ports {led[11]}]
set_property PACKAGE_PIN P3  [get_ports {led[12]}]
set_property PACKAGE_PIN N3  [get_ports {led[13]}]
set_property PACKAGE_PIN P1  [get_ports {led[14]}]
set_property PACKAGE_PIN L1  [get_ports {led[15]}]
set_property IOSTANDARD LVCMOS33 [get_ports {led[*]}]

## ── Timing Constraints ────────────────────────────────────────────────────────
## Constrain FIFO RCK output (it drives the FIFO read clock)
set_output_delay -clock sys_clk -max 5.0 [get_ports fifo_rck]
set_output_delay -clock sys_clk -min 1.0 [get_ports fifo_rck]

## FIFO data is read on RCK rising edge — set as multicycle since RCK is slow
set_multicycle_path 4 -setup -from [get_clocks sys_clk] -to [get_ports fifo_rck]

## ── Configuration ─────────────────────────────────────────────────────────────
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]

## =============================================================================
## WIRING REFERENCE (physical connections):
##
## OV7670+FIFO module → Basys 3
## ─────────────────────────────────────────────────────────────────
##  Camera → Pmod JA (data bus):
##    D0-D7  → JA pins 1-4, 7-10
##
##  Camera → Pmod JB (control):
##    VSYNC  → JB pin 1
##    WRST_N → JB pin 2
##    RRST_N → JB pin 3
##    OE_N   → JB pin 4
##    RCK    → JB pin 7
##
##  Camera config → Pmod JC:
##    XCLK   → JC pin 2   (25 MHz camera clock)
##    SIO_C  → JC pin 3   (SCCB clock)
##    SIO_D  → JC pin 4   (SCCB data, bidirectional)
##    UART_TX→ JC pin 1   (to ESP32 GPIO 3 / RX)
##
##  Power:
##    Camera VCC → 3.3V (Pmod VCC pin)
##    Camera GND → GND  (Pmod GND pin)
## =============================================================================
