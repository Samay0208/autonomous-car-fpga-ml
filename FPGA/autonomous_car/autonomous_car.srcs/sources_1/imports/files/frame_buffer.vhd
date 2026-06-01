-- =============================================================================
-- rgb565_to_gray.vhd
-- Converts RGB565 pixel to 8-bit grayscale in 1 clock cycle
-- Gray = (5*R + 9*G + 2*B) >> 4  (integer approximation of 0.299R+0.587G+0.114B)
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity rgb565_to_gray is
    port (
        clk       : in  std_logic;
        pix_in    : in  std_logic_vector(15 downto 0); -- RGB565
        pix_valid : in  std_logic;
        gray_out  : out std_logic_vector(7 downto 0);
        gray_valid: out std_logic
    );
end rgb565_to_gray;

architecture Behavioral of rgb565_to_gray is
begin
    process(clk)
        variable r8 : unsigned(7 downto 0);
        variable g8 : unsigned(7 downto 0);
        variable b8 : unsigned(7 downto 0);
        variable gray : unsigned(11 downto 0);
    begin
        if rising_edge(clk) then
            gray_valid <= '0';
            if pix_valid = '1' then
                -- Extract channels from RGB565
                -- R: bits [15:11] (5 bits) → scale to 8 bits
                -- G: bits [10:5]  (6 bits) → scale to 8 bits
                -- B: bits [4:0]   (5 bits) → scale to 8 bits
                r8 := unsigned(pix_in(15 downto 11)) & unsigned(pix_in(15 downto 13));
                g8 := unsigned(pix_in(10 downto 5))  & unsigned(pix_in(10 downto 9));
                b8 := unsigned(pix_in(4 downto 0))   & unsigned(pix_in(4 downto 2));

                -- Gray ≈ (5R + 9G + 2B) / 16
                gray := resize(5 * r8, 12) + resize(9 * g8, 12) + resize(2 * b8, 12);
                gray_out   <= std_logic_vector(gray(11 downto 4));
                gray_valid <= '1';
            end if;
        end if;
    end process;
end Behavioral;


-- =============================================================================
-- frame_buffer.vhd
-- Dual-port BRAM frame buffer: 160x120 grayscale (8-bit)
-- Port A: Write (from rgb565_to_gray)
-- Port B: Read  (by processing pipeline)
-- Total: 19,200 bytes — fits comfortably in Artix-7 BRAM
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity frame_buffer is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        -- Port A: Write
        clk_a   : in  std_logic;
        we_a    : in  std_logic;
        addr_a  : in  std_logic_vector(14 downto 0); -- 0..19199
        din_a   : in  std_logic_vector(7 downto 0);

        -- Port B: Read
        clk_b   : in  std_logic;
        addr_b  : in  std_logic_vector(14 downto 0);
        dout_b  : out std_logic_vector(7 downto 0)
    );
end frame_buffer;

architecture Behavioral of frame_buffer is

    type ram_t is array (0 to IMG_W * IMG_H - 1) of std_logic_vector(7 downto 0);
    shared variable ram : ram_t := (others => (others => '0'));

begin

    -- Port A: Write
    process(clk_a)
    begin
        if rising_edge(clk_a) then
            if we_a = '1' then
                ram(to_integer(unsigned(addr_a))) := din_a;
            end if;
        end if;
    end process;

    -- Port B: Read
    process(clk_b)
    begin
        if rising_edge(clk_b) then
            dout_b <= ram(to_integer(unsigned(addr_b)));
        end if;
    end process;

end Behavioral;


-- =============================================================================
-- frame_writer.vhd
-- Connects fifo_reader → rgb565_to_gray → frame_buffer
-- Computes write address from pixel x,y coordinates
-- =============================================================================
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

        -- From fifo_reader
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

    -- rgb565_to_gray intermediate signals
    signal gray_out   : std_logic_vector(7 downto 0);
    signal gray_valid : std_logic;

    -- Delay x,y by 1 clock to match gray pipeline latency
    signal pix_x_d   : std_logic_vector(7 downto 0);
    signal pix_y_d   : std_logic_vector(6 downto 0);

begin

    -- Instantiate color converter
    u_gray : entity work.rgb565_to_gray
        port map (
            clk        => clk,
            pix_in     => pix_data,
            pix_valid  => pix_valid,
            gray_out   => gray_out,
            gray_valid => gray_valid
        );

    -- Delay coordinates to match 1-cycle pipeline
    process(clk)
    begin
        if rising_edge(clk) then
            pix_x_d <= pix_x;
            pix_y_d <= pix_y;
        end if;
    end process;

    -- Compute write address: addr = y * IMG_W + x
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
                    addr_v   := to_unsigned(to_integer(unsigned(pix_y_d)) * IMG_W
                                          + to_integer(unsigned(pix_x_d)), 15);
                    buf_addr <= std_logic_vector(addr_v);
                    buf_din  <= gray_out;
                end if;
            end if;
        end if;
    end process;

end Behavioral;
