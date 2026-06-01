## ============================================================
## basys3.xdc — Constraints for Autonomous Car FPGA
## Basys 3 (Artix-7 XC7A35T-1CPG236C)
## ============================================================

## System Clock (100 MHz)
set_property PACKAGE_PIN W5 [get_ports clk_100]
set_property IOSTANDARD LVCMOS33 [get_ports clk_100]
create_clock -add -name sys_clk -period 10.00 [get_ports clk_100]

## Reset — Center button BTNC
set_property PACKAGE_PIN U18 [get_ports rst_btn]
set_property IOSTANDARD LVCMOS33 [get_ports rst_btn]

## ── OV7670 Data Bus → Pmod JA ─────────────────────────────
## D0=JA1, D1=JA2, D2=JA3, D3=JA4, D4=JA7, D5=JA8, D6=JA9, D7=JA10
set_property PACKAGE_PIN J1 [get_ports {ov_d[0]}]
set_property PACKAGE_PIN L2 [get_ports {ov_d[1]}]
set_property PACKAGE_PIN J2 [get_ports {ov_d[2]}]
set_property PACKAGE_PIN G2 [get_ports {ov_d[3]}]
set_property PACKAGE_PIN H1 [get_ports {ov_d[4]}]
set_property PACKAGE_PIN K2 [get_ports {ov_d[5]}]
set_property PACKAGE_PIN H2 [get_ports {ov_d[6]}]
set_property PACKAGE_PIN G3 [get_ports {ov_d[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {ov_d[*]}]

## ── OV7670 Control → Pmod JB ──────────────────────────────
## PCLK → JB1, VSYNC → JB2, HREF → JB3
set_property PACKAGE_PIN A14 [get_ports ov_pclk]
set_property PACKAGE_PIN A16 [get_ports ov_vsync]
set_property PACKAGE_PIN B15 [get_ports ov_href]
set_property IOSTANDARD LVCMOS33 [get_ports ov_pclk]
set_property IOSTANDARD LVCMOS33 [get_ports ov_vsync]
set_property IOSTANDARD LVCMOS33 [get_ports ov_href]

## ── UART + SCCB + XCLK → Pmod JC ─────────────────────────
## UART TX → JC1, XCLK → JC2, SIO_C → JC3, SIO_D → JC4
## UART RX → JC7
set_property PACKAGE_PIN K17 [get_ports uart_tx]
set_property PACKAGE_PIN M18 [get_ports xclk]
set_property PACKAGE_PIN N17 [get_ports sio_c]
set_property PACKAGE_PIN P18 [get_ports sio_d]
set_property PACKAGE_PIN L17 [get_ports uart_rx]
set_property IOSTANDARD LVCMOS33 [get_ports uart_tx]
set_property IOSTANDARD LVCMOS33 [get_ports xclk]
set_property IOSTANDARD LVCMOS33 [get_ports sio_c]
set_property IOSTANDARD LVCMOS33 [get_ports sio_d]
set_property IOSTANDARD LVCMOS33 [get_ports uart_rx]

## ── LEDs ──────────────────────────────────────────────────
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

## ── Timing ────────────────────────────────────────────────
## PCLK is asynchronous to sys_clk — declare separate clock
create_clock -name pclk -period 41.67 [get_ports ov_pclk]
## Tell timing analyzer they are unrelated
set_clock_groups -asynchronous \
    -group [get_clocks sys_clk] \
    -group [get_clocks pclk]

## ── Bitstream ─────────────────────────────────────────────
set_property BITSTREAM.GENERAL.COMPRESS TRUE [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]

## ============================================================
## COMPLETE WIRING GUIDE
## ============================================================
##
## OV7670 → Basys 3
## ─────────────────
## OV7670 D0   → Pmod JA Pin 1  (top-left)
## OV7670 D1   → Pmod JA Pin 2
## OV7670 D2   → Pmod JA Pin 3
## OV7670 D3   → Pmod JA Pin 4
## OV7670 D4   → Pmod JA Pin 7  (bottom-left)
## OV7670 D5   → Pmod JA Pin 8
## OV7670 D6   → Pmod JA Pin 9
## OV7670 D7   → Pmod JA Pin 10
## OV7670 PCLK → Pmod JB Pin 1
## OV7670 VS   → Pmod JB Pin 2  (VSYNC)
## OV7670 HS   → Pmod JB Pin 3  (HREF)
## OV7670 XCLK → Pmod JC Pin 2  (25MHz from FPGA)
## OV7670 SIO_C→ Pmod JC Pin 3
## OV7670 SIO_D→ Pmod JC Pin 4
## OV7670 3.3V → Pmod VCC (any)
## OV7670 GND  → Pmod GND (any)
##
## Basys 3 → Raspberry Pi 5
## ─────────────────────────
## Pmod JC Pin 1 (UART TX) → RPi GPIO 15 (Pin 10, RX)
## Pmod JC Pin 7 (UART RX) → RPi GPIO 14 (Pin 8, TX)
## Pmod GND                → RPi GND     (Pin 6)
## NOTE: Both are 3.3V — direct connection, no level shifter needed
##
## Raspberry Pi 5 → TB6612FNG
## ───────────────────────────
## RPi GPIO 17 (Pin 11) → AIN1
## RPi GPIO 27 (Pin 13) → AIN2
## RPi GPIO 18 (Pin 12) → PWMA  (hardware PWM)
## RPi GPIO 22 (Pin 15) → BIN1
## RPi GPIO 23 (Pin 16) → BIN2
## RPi GPIO 13 (Pin 33) → PWMB  (hardware PWM)
## RPi 3.3V   (Pin 1)  → STBY  (keep HIGH = not standby)
## RPi 3.3V   (Pin 1)  → VCC   (logic supply)
## Battery +            → VM    (motor supply 7.4V from 18650)
## Common GND           → GND
##
## ESP32-CAM → Raspberry Pi 5
## ───────────────────────────
## Connect via USB (easiest) or UART
## ESP32-CAM acts as WiFi camera server
## RPi fetches JPEG frames via HTTP
## ============================================================

## PCLK non-dedicated clock route fix
## Pin A14 (Pmod JB pin 1) is not clock-capable IO
## Safe to use non-dedicated route: PCLK is slow (6-24MHz)
## and design uses 2-FF synchronizer for clock domain crossing
set_property CLOCK_DEDICATED_ROUTE FALSE [get_nets ov_pclk_IBUF]
