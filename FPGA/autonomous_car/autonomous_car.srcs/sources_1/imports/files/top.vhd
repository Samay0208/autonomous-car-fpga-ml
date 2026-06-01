-- =============================================================================
-- top.vhd
-- Top-Level Module: FPGA-Accelerated Autonomous Car Vision Pipeline
-- Basys 3 (Artix-7 XC7A35T)
--
-- Pipeline:
--   OV7670+FIFO ? Frame Buffer ? Color Blob Detection ? UART ? ESP32
--
-- UART Protocol (to ESP32):
--   Byte 0: 0xAA (start marker)
--   Byte 1: dominant_color (0=none, 1=red, 2=yellow, 3=green)
--   Byte 2: red_area high byte
--   Byte 3: red_area low byte
--   Byte 4: yellow_area high byte
--   Byte 5: yellow_area low byte
--   Byte 6: green_area high byte
--   Byte 7: green_area low byte
--   Byte 8: 0x55 (end marker)
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top is
    port (
        -- Basys 3 100 MHz clock
        clk_100     : in    std_logic;

        -- Reset (BTNC on Basys 3)
        rst_btn     : in    std_logic;

        -- OV7670 + AL422B FIFO (connected via Pmod JA + JB)
        ov_vsync    : in    std_logic;
        fifo_d      : in    std_logic_vector(7 downto 0);
        fifo_wrst_n : out   std_logic;
        fifo_rrst_n : out   std_logic;
        fifo_oe_n   : out   std_logic;
        fifo_rck    : out   std_logic;

        -- SCCB (Camera configuration)
        sio_c       : out   std_logic;
        sio_d       : inout std_logic;

        -- Camera clock (XCLK - 24 MHz from FPGA)
        xclk        : out   std_logic;

        -- UART to ESP32
        uart_tx     : out   std_logic;

        -- Debug LEDs
        led         : out   std_logic_vector(15 downto 0)
    );
end top;

architecture Behavioral of top is

    -- ??? Clock ??????????????????????????????????????????????????????????????
    signal clk : std_logic;  -- 100 MHz main
    signal rst  : std_logic;

    -- XCLK divider (100 MHz / 4 = 25 MHz for camera)
    signal xclk_cnt : integer range 0 to 1 := 0;
    signal xclk_r   : std_logic := '0';

    -- ??? SCCB / Config ??????????????????????????????????????????????????????
    signal sccb_wr_en   : std_logic;
    signal sccb_reg_addr: std_logic_vector(7 downto 0);
    signal sccb_reg_data: std_logic_vector(7 downto 0);
    signal sccb_busy    : std_logic;
    signal sccb_done    : std_logic;
    signal config_done  : std_logic;

    -- ??? FIFO Reader ????????????????????????????????????????????????????????
    signal fifo_start   : std_logic := '0';
    signal pix_data     : std_logic_vector(15 downto 0);
    signal pix_valid    : std_logic;
    signal pix_x        : std_logic_vector(7 downto 0);
    signal pix_y        : std_logic_vector(6 downto 0);
    signal frame_done   : std_logic;

    -- ??? Frame Writer (to BRAM) ?????????????????????????????????????????????
    signal buf_we       : std_logic;
    signal buf_addr_w   : std_logic_vector(14 downto 0);
    signal buf_din      : std_logic_vector(7 downto 0);
    signal write_done   : std_logic;

    -- ??? Frame Buffer ???????????????????????????????????????????????????????
    signal buf_addr_r   : std_logic_vector(14 downto 0) := (others => '0');
    signal buf_dout     : std_logic_vector(7 downto 0);

    -- ??? Color Blob Detector ????????????????????????????????????????????????
    signal blob_start       : std_logic := '0';
    signal red_area         : std_logic_vector(15 downto 0);
    signal yellow_area      : std_logic_vector(15 downto 0);
    signal green_area       : std_logic_vector(15 downto 0);
    signal red_cx           : std_logic_vector(7 downto 0);
    signal red_cy           : std_logic_vector(6 downto 0);
    signal dominant_color   : std_logic_vector(1 downto 0);
    signal blob_done        : std_logic;

    -- ??? UART Transmitter ???????????????????????????????????????????????????
    signal uart_data    : std_logic_vector(7 downto 0);
    signal uart_valid   : std_logic;
    signal uart_ready   : std_logic;

    -- ??? Top-Level FSM ??????????????????????????????????????????????????????
    type top_state_t is (
        INIT,           -- Wait for camera config to finish
        IDLE,           -- Wait between frames
        CAPTURE,        -- Trigger frame capture
        WAIT_FRAME,     -- Wait for frame to be in BRAM
        PROC_ST,        -- Run blob detector
        WAIT_RESULT,    -- Wait for blob result
        TRANSMIT,       -- Send result over UART
        WAIT_TX         -- Wait for UART to finish
    );
    signal top_state : top_state_t := INIT;

    -- UART packet FSM
    type uart_state_t is (
        TX_START, TX_COLOR, TX_RED_H, TX_RED_L,
        TX_YEL_H, TX_YEL_L, TX_GRN_H, TX_GRN_L, TX_END, TX_DONE
    );
    signal uart_state : uart_state_t := TX_DONE;

    signal frame_cnt  : unsigned(7 downto 0) := (others => '0');

begin

    clk <= clk_100;
    rst <= rst_btn;

    -- ??? XCLK Generation (25 MHz for camera) ????????????????????????????????
    process(clk)
    begin
        if rising_edge(clk) then
            if xclk_cnt = 1 then
                xclk_cnt <= 0;
                xclk_r   <= not xclk_r;
            else
                xclk_cnt <= xclk_cnt + 1;
            end if;
        end if;
    end process;
    xclk <= xclk_r;

    -- ??? SCCB Master ?????????????????????????????????????????????????????????
    u_sccb : entity work.sccb_master
        port map (
            clk      => clk,
            rst      => rst,
            wr_en    => sccb_wr_en,
            reg_addr => sccb_reg_addr,
            reg_data => sccb_reg_data,
            busy     => sccb_busy,
            done     => sccb_done,
            sio_c    => sio_c,
            sio_d    => sio_d
        );

    -- ??? OV7670 Config Sequencer ?????????????????????????????????????????????
    u_config : entity work.ov7670_config
        port map (
            clk         => clk,
            rst         => rst,
            wr_en       => sccb_wr_en,
            reg_addr    => sccb_reg_addr,
            reg_data    => sccb_reg_data,
            sccb_busy   => sccb_busy,
            sccb_done   => sccb_done,
            config_done => config_done
        );

    -- ??? FIFO Reader ?????????????????????????????????????????????????????????
    u_fifo : entity work.fifo_reader
        port map (
            clk        => clk,
            rst        => rst,
            start      => fifo_start,
            vsync      => ov_vsync,
            fifo_d     => fifo_d,
            wrst_n     => fifo_wrst_n,
            rrst_n     => fifo_rrst_n,
            oe_n       => fifo_oe_n,
            rck        => fifo_rck,
            pix_data   => pix_data,
            pix_valid  => pix_valid,
            pix_x      => pix_x,
            pix_y      => pix_y,
            frame_done => frame_done
        );

    -- ??? Frame Writer (RGB565 ? Gray ? BRAM) ?????????????????????????????????
    u_writer : entity work.frame_writer
        port map (
            clk        => clk,
            rst        => rst,
            pix_data   => pix_data,
            pix_valid  => pix_valid,
            pix_x      => pix_x,
            pix_y      => pix_y,
            frame_done => frame_done,
            buf_we     => buf_we,
            buf_addr   => buf_addr_w,
            buf_din    => buf_din,
            write_done => write_done
        );

    -- ??? Frame Buffer (BRAM) ?????????????????????????????????????????????????
    u_buffer : entity work.frame_buffer
        port map (
            clk_a  => clk,
            we_a   => buf_we,
            addr_a => buf_addr_w,
            din_a  => buf_din,
            clk_b  => clk,
            addr_b => buf_addr_r,
            dout_b => buf_dout
        );

    -- ??? Color Blob Detector ?????????????????????????????????????????????????
    u_blob : entity work.hsv_blob_detector
        port map (
            clk            => clk,
            rst            => rst,
            start          => blob_start,
            rd_addr        => buf_addr_r,
            rd_data        => buf_dout,
            pix_rgb        => pix_data,
            pix_rgb_valid  => pix_valid,
            pix_rgb_x      => pix_x,
            pix_rgb_y      => pix_y,
            red_area       => red_area,
            yellow_area    => yellow_area,
            green_area     => green_area,
            red_cx         => red_cx,
            red_cy         => red_cy,
            dominant_color => dominant_color,
            done           => blob_done
        );

    -- ??? UART Transmitter ????????????????????????????????????????????????????
    u_uart : entity work.uart_tx
        port map (
            clk      => clk,
            rst      => rst,
            tx_data  => uart_data,
            tx_valid => uart_valid,
            tx_ready => uart_ready,
            tx_out   => uart_tx
        );

    -- ??? Top-Level State Machine ?????????????????????????????????????????????
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                top_state  <= INIT;
                fifo_start <= '0';
                blob_start <= '0';
                uart_valid <= '0';
                uart_state <= TX_DONE;
                frame_cnt  <= (others => '0');
                led        <= (others => '0');
            else
                fifo_start <= '0';
                blob_start <= '0';
                uart_valid <= '0';

                case top_state is

                    -- ?? Wait for camera registers to be programmed ??????????
                    when INIT =>
                        led(0) <= '1'; -- LED0: Initialising
                        if config_done = '1' then
                            top_state <= IDLE;
                            led(0)    <= '0';
                            led(1)    <= '1'; -- LED1: Ready
                        end if;

                    -- ?? Wait state between frames ???????????????????????????
                    when IDLE =>
                        top_state  <= CAPTURE;

                    -- ?? Trigger one frame capture ???????????????????????????
                    when CAPTURE =>
                        fifo_start <= '1';
                        blob_start <= '1'; -- Start blob in parallel
                        top_state  <= WAIT_FRAME;

                    -- ?? Wait for frame write to BRAM to complete ????????????
                    when WAIT_FRAME =>
                        led(2) <= '1';
                        if write_done = '1' then
                            led(2)    <= '0';
                            top_state <= WAIT_RESULT;
                        end if;

                    when PROC_ST =>
                        top_state <= WAIT_RESULT;

                    -- ?? Wait for blob detector to finish ????????????????????
                    when WAIT_RESULT =>
                        led(3) <= '1';
                        if blob_done = '1' then
                            led(3)    <= '0';
                            -- Show result on LEDs
                            led(15 downto 14) <= dominant_color;
                            top_state <= TRANSMIT;
                            uart_state <= TX_START;
                        end if;

                    -- ?? Transmit 9-byte packet to ESP32 ????????????????????
                    when TRANSMIT =>
                        led(4) <= '1';
                        if uart_ready = '1' then
                            case uart_state is
                                when TX_START =>
                                    uart_data  <= x"AA"; -- Start marker
                                    uart_valid <= '1';
                                    uart_state <= TX_COLOR;

                                when TX_COLOR =>
                                    uart_data  <= "000000" & dominant_color;
                                    uart_valid <= '1';
                                    uart_state <= TX_RED_H;

                                when TX_RED_H =>
                                    uart_data  <= red_area(15 downto 8);
                                    uart_valid <= '1';
                                    uart_state <= TX_RED_L;

                                when TX_RED_L =>
                                    uart_data  <= red_area(7 downto 0);
                                    uart_valid <= '1';
                                    uart_state <= TX_YEL_H;

                                when TX_YEL_H =>
                                    uart_data  <= yellow_area(15 downto 8);
                                    uart_valid <= '1';
                                    uart_state <= TX_YEL_L;

                                when TX_YEL_L =>
                                    uart_data  <= yellow_area(7 downto 0);
                                    uart_valid <= '1';
                                    uart_state <= TX_GRN_H;

                                when TX_GRN_H =>
                                    uart_data  <= green_area(15 downto 8);
                                    uart_valid <= '1';
                                    uart_state <= TX_GRN_L;

                                when TX_GRN_L =>
                                    uart_data  <= green_area(7 downto 0);
                                    uart_valid <= '1';
                                    uart_state <= TX_END;

                                when TX_END =>
                                    uart_data  <= x"55"; -- End marker
                                    uart_valid <= '1';
                                    uart_state <= TX_DONE;
                                    top_state  <= WAIT_TX;

                                when TX_DONE =>
                                    top_state <= IDLE;
                            end case;
                        end if;

                    when WAIT_TX =>
                        led(4) <= '0';
                        if uart_ready = '1' then
                            frame_cnt <= frame_cnt + 1;
                            top_state <= IDLE;
                        end if;

                    when others =>
                        top_state <= INIT;

                end case;
            end if;
        end if;
    end process;

end Behavioral;