-- ============================================================
-- tb_pipeline.vhd - Complete Pipeline Simulation
-- Tests ALL sign types + lane detection
--
-- Full pipeline verified:
--   Fake Camera ? OV7670 Capture ? Frame Buffer ?
--   Gaussian Blur ? Sobel Edge ? Blob Detection ?
--   Lane Detection ? Sign Classification ? UART Output
--
-- Sign tests:
--   1. STOP sign        (red centered blob)
--   2. WARNING sign     (yellow blob)
--   3. GO sign          (green blob)
--   4. PROHIBITION      (red offset blob - no entry)
--   5. Lane detection   (white lines on dark background)
--   6. No sign          (empty frame)
--   7. Mixed scene      (sign + lane lines together)
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_pipeline is
end tb_pipeline;

architecture Behavioral of tb_pipeline is

    signal clk_100  : std_logic := '0';
    signal rst_btn  : std_logic := '1';
    signal ov_pclk  : std_logic := '0';
    signal ov_vsync : std_logic := '0';
    signal ov_href  : std_logic := '0';
    signal ov_d     : std_logic_vector(7 downto 0) := (others=>'0');
    signal sio_c    : std_logic;
    signal sio_d    : std_logic;
    signal xclk     : std_logic;
    signal uart_tx  : std_logic := '1';
    signal uart_rx  : std_logic := '1';
    signal led      : std_logic_vector(15 downto 0);

    constant CLK_PERIOD  : time := 10 ns;
    constant PCLK_PERIOD : time := 40 ns;
    constant BAUD_PERIOD : time := 8680 ns;

    constant IMG_W : integer := 160;
    constant IMG_H : integer := 120;

    -- RGB565 colours
    -- Red   : R=31 G=0  B=0  ? 1111 1000 0000 0000 ? 0xF800
    -- Yellow: R=31 G=63 B=0  ? 1111 1111 1110 0000 ? 0xFFE0
    -- Green : R=0  G=63 B=0  ? 0000 0111 1110 0000 ? 0x07E0
    -- White : R=31 G=63 B=31 ? 1111 1111 1111 1111 ? 0xFFFF
    -- Black : 0x0000
    constant C_RED_H   : std_logic_vector(7 downto 0) := x"F8";
    constant C_RED_L   : std_logic_vector(7 downto 0) := x"00";
    constant C_YELLOW_H: std_logic_vector(7 downto 0) := x"FF";
    constant C_YELLOW_L: std_logic_vector(7 downto 0) := x"E0";
    constant C_GREEN_H : std_logic_vector(7 downto 0) := x"07";
    constant C_GREEN_L : std_logic_vector(7 downto 0) := x"E0";
    constant C_WHITE_H : std_logic_vector(7 downto 0) := x"FF";
    constant C_WHITE_L : std_logic_vector(7 downto 0) := x"FF";
    constant C_BLACK_H : std_logic_vector(7 downto 0) := x"00";
    constant C_BLACK_L : std_logic_vector(7 downto 0) := x"00";

    signal test_number : integer := 0;

begin

    -- DUT
    uut: entity work.top
        port map(
            clk_100=>clk_100, rst_btn=>rst_btn,
            ov_pclk=>ov_pclk, ov_vsync=>ov_vsync,
            ov_href=>ov_href, ov_d=>ov_d,
            sio_c=>sio_c, sio_d=>sio_d, xclk=>xclk,
            uart_tx=>uart_tx, uart_rx=>uart_rx, led=>led
        );

    -- Clocks
    clk_100 <= not clk_100 after CLK_PERIOD/2;
    ov_pclk <= not ov_pclk after PCLK_PERIOD/2;

    -- ?? LED Stage Monitor ????????????????????????????????????????????????????
    process(led)
    begin
        if led(1) = '1' then
            report "[SYSTEM] Ready - Camera configured";
        end if;
        if led(2) = '1' then
            report "[STAGE 1] Frame capture active";
        end if;
        if led(3) = '1' then
            report "[STAGE 2] Gaussian blur processing";
        end if;
        if led(4) = '1' then
            report "[STAGE 3] Sobel edge + blob detection";
        end if;
        if led(5) = '1' then
            report "[STAGE 4] UART transmitting to RPi 5";
        end if;
        if led(12) = '1' then
            report "[LANE] Lane edges detected";
        end if;
        case led(10 downto 8) is
            when "001" => report "*** SIGN CLASS: STOP (red sign) ***";
            when "010" => report "*** SIGN CLASS: WARNING (yellow sign) ***";
            when "011" => report "*** SIGN CLASS: GO (green sign) ***";
            when "100" => report "*** SIGN CLASS: PROHIBITION (no entry) ***";
            when "000" => null;
            when others => null;
        end case;
    end process;

    -- ?? Main Test Stimulus ???????????????????????????????????????????????????
    process
        -- Send one pixel (2 PCLK cycles)
        procedure px(h,l: std_logic_vector(7 downto 0)) is
        begin
            wait until rising_edge(ov_pclk);
            ov_d <= h;
            wait until rising_edge(ov_pclk);
            ov_d <= l;
        end procedure;

        -- Send complete frame with configurable blobs
        procedure send_frame(
            -- Blob 1 parameters
            b1_row_lo, b1_row_hi : integer;
            b1_col_lo, b1_col_hi : integer;
            b1_h, b1_l           : std_logic_vector(7 downto 0);
            -- Blob 2 parameters (set same as blob1 to disable)
            b2_row_lo, b2_row_hi : integer;
            b2_col_lo, b2_col_hi : integer;
            b2_h, b2_l           : std_logic_vector(7 downto 0);
            -- Lane lines (white vertical stripes)
            has_lanes            : boolean;
            test_name            : string
        ) is
        begin
            report ">>> TEST: " & test_name;
            report "    Sending 160x120 frame...";

            -- VSYNC pulse
            wait until rising_edge(ov_pclk);
            ov_vsync <= '1';
            wait until rising_edge(ov_pclk);
            ov_vsync <= '0';
            wait until rising_edge(ov_pclk);

            -- Send all rows
            for row in 0 to IMG_H-1 loop
                ov_href <= '1';
                for col in 0 to IMG_W-1 loop
                    -- Lane lines: white at cols 30 and 130 (bottom half)
                    if has_lanes and row > 60 and
                       ((col >= 28 and col <= 32) or
                        (col >= 128 and col <= 132)) then
                        px(C_WHITE_H, C_WHITE_L);
                    -- Blob 1
                    elsif row >= b1_row_lo and row <= b1_row_hi and
                          col >= b1_col_lo and col <= b1_col_hi then
                        px(b1_h, b1_l);
                    -- Blob 2
                    elsif row >= b2_row_lo and row <= b2_row_hi and
                          col >= b2_col_lo and col <= b2_col_hi then
                        px(b2_h, b2_l);
                    else
                        px(C_BLACK_H, C_BLACK_L);
                    end if;
                end loop;
                ov_href <= '0';
                wait until rising_edge(ov_pclk);
                wait until rising_edge(ov_pclk);
            end loop;

            ov_d <= (others=>'0');
            report "    Frame complete. Waiting for pipeline...";
            wait for 80 us;  -- Pipeline processing time
        end procedure;

    begin
        rst_btn <= '1';
        wait for 500 ns;
        rst_btn <= '0';

        report "================================================";
        report " FPGA Vision Pipeline - Complete Simulation";
        report " Testing ALL sign types + lane detection";
        report "================================================";
        wait for 300 us; -- Init time

        -- ?? TEST 1: STOP Sign ????????????????????????????????????????????????
        -- Large red blob in center of frame
        test_number <= 1;
        send_frame(
            30, 90, 50, 110, C_RED_H, C_RED_L,    -- Red center blob
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,      -- No blob 2
            false, "STOP Sign (red centered blob)"
        );

        -- ?? TEST 2: WARNING Sign ?????????????????????????????????????????????
        -- Large yellow blob
        test_number <= 2;
        send_frame(
            25, 95, 40, 120, C_YELLOW_H, C_YELLOW_L,
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            false, "WARNING Sign (yellow blob)"
        );

        -- ?? TEST 3: GO Sign ??????????????????????????????????????????????????
        -- Green blob
        test_number <= 3;
        send_frame(
            30, 90, 45, 115, C_GREEN_H, C_GREEN_L,
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            false, "GO Sign (green blob)"
        );

        -- ?? TEST 4: PROHIBITION Sign ?????????????????????????????????????????
        -- Red blob offset to the side (not centered)
        test_number <= 4;
        send_frame(
            20, 80, 5, 50, C_RED_H, C_RED_L,     -- Red blob far left
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            false, "PROHIBITION Sign (red offset blob)"
        );

        -- ?? TEST 5: Lane Detection Only ??????????????????????????????????????
        -- White lane lines, no sign
        test_number <= 5;
        send_frame(
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,    -- No blob
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            true, "Lane Detection (white lines, no sign)"
        );

        -- ?? TEST 6: STOP Sign + Lane Lines ???????????????????????????????????
        -- Real world: car on road approaching stop sign
        test_number <= 6;
        send_frame(
            10, 60, 50, 110, C_RED_H, C_RED_L,   -- Stop sign upper area
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            true, "STOP Sign + Lane Lines (real world scene)"
        );

        -- ?? TEST 7: WARNING + Lane ???????????????????????????????????????????
        test_number <= 7;
        send_frame(
            5, 55, 45, 115, C_YELLOW_H, C_YELLOW_L,
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            true, "WARNING Sign + Lane Lines"
        );

        -- ?? TEST 8: No Sign (Empty Road) ?????????????????????????????????????
        test_number <= 8;
        send_frame(
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            0, 0, 0, 0, C_BLACK_H, C_BLACK_L,
            true, "Empty Road (lane only, no sign)"
        );

        wait for 200 us;

        report "================================================";
        report " ALL 8 TESTS COMPLETE";
        report " Check:";
        report "   led(10:8) for sign class per frame";
        report "   led(12)   for lane detection";
        report "   uart_tx   for 13-byte packets";
        report "   TCL console for decoded UART bytes";
        report "================================================";
        wait;
    end process;

    -- ?? UART Decoder (shows what RPi 5 would receive) ????????????????????????
    process
        variable rx_byte : std_logic_vector(7 downto 0);
        variable pkt_pos : integer := 0;
    begin
        wait until rst_btn = '0';
        report "[UART] Monitor started - decoding packets";

        loop
            wait until falling_edge(uart_tx);
            wait for BAUD_PERIOD + BAUD_PERIOD/2;

            for i in 0 to 7 loop
                rx_byte(i) := uart_tx;
                wait for BAUD_PERIOD;
            end loop;

            -- Decode each byte position in 13-byte packet
            case pkt_pos is
                when 0 =>
                    if rx_byte = x"AA" then
                        report "[UART] --- Packet Start ---";
                        pkt_pos := 1;
                    end if;
                when 1 =>
                    case rx_byte is
                        when x"00" => report "[UART] Sign: NONE";
                        when x"01" => report "[UART] Sign: STOP ? Car should STOP";
                        when x"02" => report "[UART] Sign: WARNING ? Car should SLOW";
                        when x"03" => report "[UART] Sign: GO ? Car should MOVE";
                        when x"04" => report "[UART] Sign: PROHIBITION";
                        when others => report "[UART] Sign: Unknown";
                    end case;
                    pkt_pos := 2;
                when 2 =>
                    report "[UART] Confidence: " &
                        integer'image(to_integer(unsigned(rx_byte)));
                    pkt_pos := 3;
                when 3 | 4 =>
                    report "[UART] Red area byte";
                    pkt_pos := pkt_pos + 1;
                when 5 | 6 =>
                    report "[UART] Yellow area byte";
                    pkt_pos := pkt_pos + 1;
                when 7 | 8 =>
                    report "[UART] Green area byte";
                    pkt_pos := pkt_pos + 1;
                when 9 =>
                    report "[UART] Left lane X: " &
                        integer'image(to_integer(unsigned(rx_byte)));
                    pkt_pos := 10;
                when 10 =>
                    report "[UART] Right lane X: " &
                        integer'image(to_integer(unsigned(rx_byte)));
                    pkt_pos := 11;
                when 11 =>
                    report "[UART] Steering error: " &
                        integer'image(to_integer(signed(rx_byte)));
                    pkt_pos := 12;
                when 12 =>
                    if rx_byte = x"55" then
                        report "[UART] --- Packet End ---";
                    end if;
                    pkt_pos := 0;
                when others =>
                    pkt_pos := 0;
            end case;
        end loop;
    end process;

end Behavioral;