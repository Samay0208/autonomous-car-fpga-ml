-- ============================================================
-- frame_buffer.vhd
-- Contains 3 entities:
--   1. rgb565_to_gray  - converts RGB565 pixel to 8-bit grayscale
--   2. frame_buffer    - dual-port BRAM 160x120 grayscale
--   3. frame_writer    - connects capture output to BRAM
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- ============================================================
-- Entity 1: rgb565_to_gray
-- Converts one RGB565 pixel to 8-bit grayscale
-- Latency: 1 clock cycle
-- Formula: gray = (5R + 9G + 2B) / 16
--   approximates: 0.299R + 0.587G + 0.114B
-- ============================================================
entity rgb565_to_gray is
    port (
        clk       : in  std_logic;
        pix_in    : in  std_logic_vector(15 downto 0);
        valid_in  : in  std_logic;
        gray_out  : out std_logic_vector(7 downto 0);
        valid_out : out std_logic
    );
end rgb565_to_gray;

architecture Behavioral of rgb565_to_gray is
begin
    process(clk)
        variable r8, g8, b8 : unsigned(7 downto 0);
        variable gray        : unsigned(11 downto 0);
    begin
        if rising_edge(clk) then
            valid_out <= '0';
            if valid_in = '1' then
                -- Extract and scale each channel to 8 bits
                -- R: 5 bits [15:11] ? pad with top 3 bits
                r8 := unsigned(pix_in(15 downto 11))
                    & unsigned(pix_in(15 downto 13));
                -- G: 6 bits [10:5]  ? pad with top 2 bits
                g8 := unsigned(pix_in(10 downto 5))
                    & unsigned(pix_in(10 downto 9));
                -- B: 5 bits [4:0]   ? pad with top 3 bits
                b8 := unsigned(pix_in(4 downto 0))
                    & unsigned(pix_in(4 downto 2));

                -- Weighted sum then divide by 16 (right shift 4)
                gray := resize(5 * r8, 12)
                      + resize(9 * g8, 12)
                      + resize(2 * b8, 12);

                gray_out  <= std_logic_vector(gray(11 downto 4));
                valid_out <= '1';
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- Entity 2: frame_buffer
-- Dual-port BRAM: 160 x 120 x 8-bit = 19,200 bytes
-- Port A: write (from frame_writer)
-- Port B: read  (by processing pipeline)
-- Uses ~4.3 Basys 3 BRAMs (50 available - plenty)
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity frame_buffer is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        -- Write port
        clk_a  : in  std_logic;
        we_a   : in  std_logic;
        addr_a : in  std_logic_vector(14 downto 0);
        din_a  : in  std_logic_vector(7 downto 0);
        -- Read port
        clk_b  : in  std_logic;
        addr_b : in  std_logic_vector(14 downto 0);
        dout_b : out std_logic_vector(7 downto 0)
    );
end frame_buffer;

architecture Behavioral of frame_buffer is
    type ram_t is array(0 to 160 * 120 - 1) of std_logic_vector(7 downto 0);
    shared variable ram : ram_t := (others => (others => '0'));
begin
    -- Write port
    process(clk_a)
    begin
        if rising_edge(clk_a) then
            if we_a = '1' then
                ram(to_integer(unsigned(addr_a))) := din_a;
            end if;
        end if;
    end process;

    -- Read port
    process(clk_b)
    begin
        if rising_edge(clk_b) then
            if to_integer(unsigned(addr_b)) < IMG_W * IMG_H then
                dout_b <= ram(to_integer(unsigned(addr_b)));
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- Entity 3: frame_writer
-- Connects ov7670_capture output to frame_buffer
-- Converts RGB565 ? grayscale inline (1 cycle latency)
-- Computes BRAM write address from pixel x,y coordinates
-- Also passes frame_done through for top-level FSM
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity frame_writer is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        -- From ov7670_capture
        pix_data   : in  std_logic_vector(15 downto 0);
        pix_valid  : in  std_logic;
        pix_x      : in  std_logic_vector(7 downto 0);
        pix_y      : in  std_logic_vector(6 downto 0);
        frame_done : in  std_logic;
        -- To frame_buffer port A
        buf_we     : out std_logic;
        buf_addr   : out std_logic_vector(14 downto 0);
        buf_din    : out std_logic_vector(7 downto 0);
        -- Status
        write_done : out std_logic
    );
end frame_writer;

architecture Behavioral of frame_writer is
    signal gray_out   : std_logic_vector(7 downto 0);
    signal gray_valid : std_logic;
    -- Delay coordinates by 1 cycle to match gray conversion latency
    signal pix_x_d    : std_logic_vector(7 downto 0);
    signal pix_y_d    : std_logic_vector(6 downto 0);
begin

    -- Instantiate colour converter
    u_gray : entity work.rgb565_to_gray
        port map (
            clk       => clk,
            pix_in    => pix_data,
            valid_in  => pix_valid,
            gray_out  => gray_out,
            valid_out => gray_valid
        );

    -- Delay pixel coordinates by 1 cycle
    process(clk)
    begin
        if rising_edge(clk) then
            pix_x_d <= pix_x;
            pix_y_d <= pix_y;
        end if;
    end process;

    -- Compute write address and drive buffer
    process(clk)
        variable addr_v : unsigned(14 downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                buf_we     <= '0';
                write_done <= '0';
            else
                write_done <= frame_done;
                buf_we     <= gray_valid;
                if gray_valid = '1' then
                    -- addr = y * IMG_W + x
                    addr_v   := to_unsigned(
                        to_integer(unsigned(pix_y_d)) * IMG_W
                        + to_integer(unsigned(pix_x_d)), 15);
                    buf_addr <= std_logic_vector(addr_v);
                    buf_din  <= gray_out;
                end if;
            end if;
        end if;
    end process;

end Behavioral;