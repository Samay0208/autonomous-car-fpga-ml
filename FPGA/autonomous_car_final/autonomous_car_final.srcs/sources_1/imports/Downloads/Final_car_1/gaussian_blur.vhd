-- ============================================================
-- gaussian_blur.vhd
-- 3x3 Gaussian Blur for Basys 3 Artix-7 FPGA
--
-- Kernel: [1 2 1; 2 4 2; 1 2 1] / 16
-- No DSP slices used - pure shift-and-add arithmetic
-- 3 line buffers in distributed RAM
-- Pipeline latency: 3 clock cycles
--
-- Contains 2 entities:
--   gaussian_blur  - processes frame buffer ? blurred output
--   blurred_buffer - BRAM storage for blurred frame
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity gaussian_blur is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        clk     : in  std_logic;
        rst     : in  std_logic;
        start   : in  std_logic;
        done    : out std_logic;
        -- Read from grayscale frame buffer
        rd_addr : out std_logic_vector(14 downto 0);
        rd_data : in  std_logic_vector(7 downto 0);
        -- Write to blurred buffer
        wr_en   : out std_logic;
        wr_addr : out std_logic_vector(14 downto 0);
        wr_data : out std_logic_vector(7 downto 0)
    );
end gaussian_blur;

architecture Behavioral of gaussian_blur is
    type line_t is array(0 to IMG_W-1) of unsigned(7 downto 0);
    signal lb0, lb1, lb2 : line_t := (others=>(others=>'0'));

    type win_row_t is array(0 to 2) of unsigned(7 downto 0);
    signal w0, w1, w2 : win_row_t := (others=>(others=>'0'));

    signal px, px_d1, px_d2, px_d3 : integer range 0 to IMG_W-1 := 0;
    signal py, py_d1, py_d2, py_d3 : integer range 0 to IMG_H-1 := 0;
    signal addr_cnt  : integer range 0 to IMG_W*IMG_H-1 := 0;
    signal v1,v2,v3  : std_logic := '0';
    signal blur_sum  : unsigned(11 downto 0);
    signal blur_out  : unsigned(7 downto 0);
    signal flush_cnt : integer range 0 to 5 := 0;

    type state_t is (IDLE, RUNNING, FLUSH, DONE_ST);
    signal state : state_t := IDLE;
begin
    rd_addr <= std_logic_vector(to_unsigned(addr_cnt, 15));

    process(clk)
        variable rm      : integer range 0 to 2;
        variable sum_v   : unsigned(11 downto 0);
        variable addr_out: unsigned(14 downto 0);
    begin
        if rising_edge(clk) then
            if rst='1' then
                state<=IDLE; px<=0; py<=0; addr_cnt<=0;
                v1<='0'; v2<='0'; v3<='0';
                wr_en<='0'; done<='0'; flush_cnt<=0;
            else
                wr_en<='0'; done<='0';
                case state is

                    when IDLE =>
                        px<=0; py<=0; addr_cnt<=0;
                        v1<='0'; v2<='0'; v3<='0'; flush_cnt<=0;
                        if start='1' then state<=RUNNING; end if;

                    when RUNNING =>
                        -- Stage 1: load pixel into correct line buffer
                        rm := py mod 3;
                        case rm is
                            when 0 => lb0(px) <= unsigned(rd_data);
                            when 1 => lb1(px) <= unsigned(rd_data);
                            when 2 => lb2(px) <= unsigned(rd_data);
                            when others => null;
                        end case;
                        px_d1<=px; py_d1<=py;
                        if py>=2 and px>=1 then v1<='1'; else v1<='0'; end if;

                        -- Stage 2: fill 3x3 window
                        px_d2<=px_d1; py_d2<=py_d1; v2<=v1;
                        if v1='1' and px_d1>=1 and px_d1<IMG_W-1 then
                            rm := py_d1 mod 3;
                            case rm is
                                when 0 =>
                                    w0<=(lb1(px_d1-1),lb1(px_d1),lb1(px_d1+1));
                                    w1<=(lb2(px_d1-1),lb2(px_d1),lb2(px_d1+1));
                                    w2<=(lb0(px_d1-1),lb0(px_d1),lb0(px_d1+1));
                                when 1 =>
                                    w0<=(lb2(px_d1-1),lb2(px_d1),lb2(px_d1+1));
                                    w1<=(lb0(px_d1-1),lb0(px_d1),lb0(px_d1+1));
                                    w2<=(lb1(px_d1-1),lb1(px_d1),lb1(px_d1+1));
                                when others =>
                                    w0<=(lb0(px_d1-1),lb0(px_d1),lb0(px_d1+1));
                                    w1<=(lb1(px_d1-1),lb1(px_d1),lb1(px_d1+1));
                                    w2<=(lb2(px_d1-1),lb2(px_d1),lb2(px_d1+1));
                            end case;
                        end if;

                        -- Stage 3: apply kernel [1 2 1; 2 4 2; 1 2 1]/16
                        px_d3<=px_d2; py_d3<=py_d2; v3<=v2;
                        if v2='1' then
                            sum_v := resize(w0(0),12)
                                   + resize(w0(1),12) + resize(w0(1),12)
                                   + resize(w0(2),12)
                                   + resize(w1(0),12) + resize(w1(0),12)
                                   + resize(w1(1),12) + resize(w1(1),12)
                                   + resize(w1(1),12) + resize(w1(1),12)
                                   + resize(w1(2),12) + resize(w1(2),12)
                                   + resize(w2(0),12)
                                   + resize(w2(1),12) + resize(w2(1),12)
                                   + resize(w2(2),12);
                            blur_sum <= sum_v;
                            blur_out <= sum_v(11 downto 4); -- /16
                        end if;

                        -- Stage 4: write blurred pixel
                        if v3='1' and py_d3>=2 and px_d3>=1 then
                            addr_out := to_unsigned((py_d3-2)*IMG_W+(px_d3-1), 15);
                            wr_addr <= std_logic_vector(addr_out);
                            wr_data <= std_logic_vector(blur_out);
                            wr_en   <= '1';
                        end if;

                        -- Advance counters
                        addr_cnt <= addr_cnt+1;
                        if px=IMG_W-1 then
                            px<=0;
                            if py=IMG_H-1 then state<=FLUSH;
                            else py<=py+1; end if;
                        else px<=px+1; end if;

                    when FLUSH =>
                        v1<='0'; v2<=v1; v3<=v2;
                        if v3='1' and py_d3>=2 and px_d3>=1 then
                            addr_out := to_unsigned((py_d3-2)*IMG_W+(px_d3-1), 15);
                            if addr_out < IMG_W*IMG_H then
                                wr_addr <= std_logic_vector(addr_out);
                                wr_data <= std_logic_vector(blur_out);
                                wr_en   <= '1';
                            end if;
                        end if;
                        flush_cnt <= flush_cnt+1;
                        if flush_cnt=4 then state<=DONE_ST; end if;

                    when DONE_ST =>
                        done<='1'; addr_cnt<=0; px<=0; py<=0; state<=IDLE;

                    when others => state<=IDLE;
                end case;
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- blurred_buffer
-- Dual-port BRAM: stores Gaussian-blurred frame
-- Port A: write (from gaussian_blur)
-- Port B: read  (by sobel_edge)
-- Size: 160x120 = 19,200 bytes (~4.3 BRAMs)
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity blurred_buffer is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        clk_a  : in  std_logic;
        we_a   : in  std_logic;
        addr_a : in  std_logic_vector(14 downto 0);
        din_a  : in  std_logic_vector(7 downto 0);
        clk_b  : in  std_logic;
        addr_b : in  std_logic_vector(14 downto 0);
        dout_b : out std_logic_vector(7 downto 0)
    );
end blurred_buffer;

architecture Behavioral of blurred_buffer is
    type ram_t is array(0 to 160*120-1) of std_logic_vector(7 downto 0);
    shared variable ram : ram_t := (others=>(others=>'0'));
begin
    process(clk_a) begin
        if rising_edge(clk_a) then
            if we_a='1' then
                ram(to_integer(unsigned(addr_a))) := din_a;
            end if;
        end if;
    end process;
    process(clk_b) begin
        if rising_edge(clk_b) then
            if to_integer(unsigned(addr_b)) < 160*120 then
                dout_b <= ram(to_integer(unsigned(addr_b)));
            end if;
        end if;
    end process;
end Behavioral;