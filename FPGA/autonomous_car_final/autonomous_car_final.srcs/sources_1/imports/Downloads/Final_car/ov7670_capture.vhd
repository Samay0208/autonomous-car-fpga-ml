-- =============================================================================
-- ov7670_capture.vhd
-- Direct OV7670 Pixel Capture (NO FIFO version)
-- Replaces fifo_reader.vhd
--
-- OV7670 output signals:
--   PCLK  : Pixel clock (from camera, ~6-24MHz)
--   VSYNC : High at start of new frame
--   HREF  : High during valid pixel row
--   D[7:0]: Pixel data (RGB565 = 2 bytes per pixel, MSB first)
--
-- Strategy:
--   Use PCLK as sampling clock (cross-clock domain via synchronizer)
--   Detect VSYNC rising edge → start new frame
--   Capture D[7:0] on PCLK rising edge when HREF = '1'
--   Assemble two bytes into RGB565 pixel word
--   Write to frame buffer via handshake
--
-- Configuration: QQVGA 160x120 RGB565
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ov7670_capture is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        -- System clock (100 MHz)
        clk        : in  std_logic;
        rst        : in  std_logic;

        -- OV7670 camera signals (asynchronous to clk)
        pclk       : in  std_logic;
        vsync      : in  std_logic;
        href       : in  std_logic;
        cam_d      : in  std_logic_vector(7 downto 0);

        -- Pixel output (synchronous to clk via FIFO handshake)
        pix_data   : out std_logic_vector(15 downto 0); -- RGB565
        pix_valid  : out std_logic;
        pix_x      : out std_logic_vector(7 downto 0);
        pix_y      : out std_logic_vector(6 downto 0);
        frame_done : out std_logic;
        frame_count: out std_logic_vector(7 downto 0)  -- Debug: frames captured
    );
end ov7670_capture;

architecture Behavioral of ov7670_capture is

    -- ─── PCLK domain signals ──────────────────────────────────────────────────
    signal byte_count   : std_logic := '0';  -- 0=first byte, 1=second byte
    signal byte1        : std_logic_vector(7 downto 0) := (others => '0');
    signal px_cnt       : integer range 0 to IMG_W - 1 := 0;
    signal py_cnt       : integer range 0 to IMG_H - 1 := 0;

    -- PCLK domain output registers
    signal pix_data_p   : std_logic_vector(15 downto 0) := (others => '0');
    signal pix_valid_p  : std_logic := '0';
    signal pix_x_p      : std_logic_vector(7 downto 0) := (others => '0');
    signal pix_y_p      : std_logic_vector(6 downto 0) := (others => '0');
    signal frame_done_p : std_logic := '0';
    signal frame_cnt_p  : unsigned(7 downto 0) := (others => '0');

    -- VSYNC edge detection in PCLK domain
    signal vsync_prev   : std_logic := '0';
    signal vsync_rise   : std_logic := '0';
    signal capturing    : std_logic := '0';

    -- ─── Synchronizers (PCLK → clk domain) ──────────────────────────────────
    -- 2-FF synchronizer for each cross-domain signal
    signal pix_valid_s1, pix_valid_s2 : std_logic := '0';
    signal frame_done_s1, frame_done_s2 : std_logic := '0';

    -- For multi-bit signals, use a simple valid pulse approach
    -- Register full pixel data when pix_valid_p pulses
    signal pix_data_latch  : std_logic_vector(15 downto 0) := (others => '0');
    signal pix_x_latch     : std_logic_vector(7 downto 0) := (others => '0');
    signal pix_y_latch     : std_logic_vector(6 downto 0) := (others => '0');
    signal frame_cnt_latch : std_logic_vector(7 downto 0) := (others => '0');

    -- Synchronized output valid pulse (one cycle in clk domain)
    signal pix_valid_sync  : std_logic := '0';
    signal pix_valid_prev  : std_logic := '0';

begin

    -- =========================================================================
    -- PCLK DOMAIN: Pixel Capture
    -- =========================================================================
    process(pclk)
    begin
        if rising_edge(pclk) then
            -- Default
            pix_valid_p  <= '0';
            frame_done_p <= '0';
            vsync_rise   <= '0';

            -- VSYNC edge detection
            vsync_prev <= vsync;
            
            -- VSYNC rising edge indicates start of vertical blanking (end of active frame)
            if vsync = '1' and vsync_prev = '0' then
                vsync_rise   <= '1';
                frame_done_p <= '1';
                capturing    <= '0'; -- Stop capturing during blanking
            end if;

            -- VSYNC falling edge indicates end of vertical blanking (start of active frame)
            if vsync = '0' and vsync_prev = '1' then
                px_cnt       <= 0;
                py_cnt       <= 0;
                byte_count   <= '0';
                capturing    <= '1'; -- Start capturing active pixels
                frame_cnt_p  <= frame_cnt_p + 1;
            end if;

            -- Pixel capture: only when HREF is high and we're in a valid frame
            if href = '1' and capturing = '1' then
                if byte_count = '0' then
                    -- First byte of RGB565 (high byte)
                    byte1      <= cam_d;
                    byte_count <= '1';
                else
                    -- Second byte → complete pixel
                    pix_data_p  <= byte1 & cam_d;
                    pix_valid_p <= '1';
                    pix_x_p     <= std_logic_vector(to_unsigned(px_cnt, 8));
                    pix_y_p     <= std_logic_vector(to_unsigned(py_cnt, 7));
                    byte_count  <= '0';

                    -- Advance pixel counter
                    if px_cnt = IMG_W - 1 then
                        px_cnt <= 0;
                        if py_cnt < IMG_H - 1 then
                            py_cnt <= py_cnt + 1;
                        end if;
                    else
                        px_cnt <= px_cnt + 1;
                    end if;
                end if;
            end if;

            -- Reset byte counter when HREF goes low (end of line)
            if href = '0' then
                byte_count <= '0';
            end if;

        end if;
    end process;

    -- =========================================================================
    -- LATCH: Register pixel data in PCLK domain when valid
    -- This separates the fast-changing data from the synchronizer
    -- =========================================================================
    process(pclk)
    begin
        if rising_edge(pclk) then
            if pix_valid_p = '1' then
                pix_data_latch  <= pix_data_p;
                pix_x_latch     <= pix_x_p;
                pix_y_latch     <= pix_y_p;
            end if;
            if frame_done_p = '1' then
                frame_cnt_latch <= std_logic_vector(frame_cnt_p);
            end if;
        end if;
    end process;

    -- =========================================================================
    -- CLK DOMAIN: 2-FF Synchronizers
    -- =========================================================================
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                pix_valid_s1   <= '0'; pix_valid_s2   <= '0';
                frame_done_s1  <= '0'; frame_done_s2  <= '0';
                pix_valid_prev <= '0';
            else
                -- 2-FF synchronizer for pix_valid
                pix_valid_s1 <= pix_valid_p;
                pix_valid_s2 <= pix_valid_s1;

                -- 2-FF synchronizer for frame_done
                frame_done_s1 <= frame_done_p;
                frame_done_s2 <= frame_done_s1;

                -- Edge detect on synchronized valid (rising edge = new pixel)
                pix_valid_prev <= pix_valid_s2;

                -- Output assignments (register for stability)
                if pix_valid_s2 = '1' and pix_valid_prev = '0' then
                    -- Rising edge of synchronized valid → output pixel
                    pix_data  <= pix_data_latch;
                    pix_x     <= pix_x_latch;
                    pix_y     <= pix_y_latch;
                    pix_valid <= '1';
                else
                    pix_valid <= '0';
                end if;

                -- Frame done output
                if frame_done_s2 = '1' and frame_done_s1 = '0' then
                    frame_done  <= '1';
                    frame_count <= frame_cnt_latch;
                else
                    frame_done <= '0';
                end if;
            end if;
        end if;
    end process;

end Behavioral;
