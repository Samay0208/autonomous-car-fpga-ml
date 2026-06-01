-- ============================================================
-- vision_pipeline.vhd
-- Contains all vision processing modules:
--   1. sobel_edge       - edge detection
--   2. hsv_blob_detector - color blob analysis
--   3. lane_detector    - lane edge X coordinates
--   4. sign_classifier  - hardware sign classification
-- ============================================================

-- ============================================================
-- 1. SOBEL EDGE DETECTOR
-- 3x3 Sobel operator with line buffers
-- Reads frame buffer sequentially, outputs binary edge map
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sobel_edge is
    generic (
        IMG_W     : integer := 160;
        IMG_H     : integer := 120;
        THRESHOLD : integer := 25
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        start      : in  std_logic;
        rd_addr    : out std_logic_vector(14 downto 0);
        rd_data    : in  std_logic_vector(7 downto 0);
        edge_valid : out std_logic;
        edge_out   : out std_logic;
        edge_x     : out std_logic_vector(7 downto 0);
        edge_y     : out std_logic_vector(6 downto 0);
        edge_mag   : out std_logic_vector(7 downto 0);
        done       : out std_logic
    );
end sobel_edge;

architecture Behavioral of sobel_edge is
    -- Three line buffers for 3x3 window
    type line_t is array(0 to IMG_W-1) of unsigned(7 downto 0);
    signal lb0, lb1, lb2 : line_t := (others => (others=>'0'));
    -- 3x3 window registers
    type win_row is array(0 to 2) of unsigned(7 downto 0);
    signal w0, w1, w2    : win_row := (others => (others=>'0'));

    signal px, px_d1, px_d2 : integer range 0 to IMG_W-1 := 0;
    signal py, py_d1, py_d2 : integer range 0 to IMG_H-1 := 0;
    signal addr_cnt : integer range 0 to IMG_W*IMG_H-1 := 0;
    signal v1, v2   : std_logic := '0';
    type state_t is (IDLE, RUNNING, DONE_ST);
    signal state    : state_t := IDLE;
    signal row_mod  : integer range 0 to 2;
begin
    rd_addr <= std_logic_vector(to_unsigned(addr_cnt, 15));

    process(clk)
        variable gx_v, gy_v : signed(11 downto 0);
        variable mag_v       : unsigned(11 downto 0);
        variable rm          : integer range 0 to 2;
    begin
        if rising_edge(clk) then
            if rst='1' then
                state<= IDLE; edge_valid<='0'; done<='0';
                px<=0; py<=0; addr_cnt<=0; v1<='0'; v2<='0';
            else
                edge_valid <= '0'; done <= '0'; v1 <= '0'; v2 <= '0';

                case state is
                    when IDLE =>
                        px<=0; py<=0; addr_cnt<=0; v1<='0'; v2<='0';
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

                        -- Stage 1 pipeline
                        px_d1 <= px; py_d1 <= py;
                        if px >= 1 and py >= 1 then v1 <= '1'; end if;

                        -- Stage 2: fill window and compute Sobel
                        px_d2 <= px_d1; py_d2 <= py_d1; v2 <= v1;
                        if v1 = '1' and px_d1 >= 1 and px_d1 < IMG_W-1 then
                            -- Fill 3x3 window from line buffers
                            rm := py_d1 mod 3;
                            case rm is
                                when 0 =>
                                    w0 <= (lb2(px_d1-1), lb2(px_d1), lb2(px_d1+1) );
                                    w1 <= (lb0(px_d1-1), lb0(px_d1), lb0(px_d1+1) );
                                    w2 <= (lb1(px_d1-1), lb1(px_d1), lb1(px_d1+1) );
                                when 1 =>
                                    w0 <= (lb0(px_d1-1), lb0(px_d1), lb0(px_d1+1) );
                                    w1 <= (lb1(px_d1-1), lb1(px_d1), lb1(px_d1+1) );
                                    w2 <= (lb2(px_d1-1), lb2(px_d1), lb2(px_d1+1) );
                                when others =>
                                    w0 <= (lb1(px_d1-1), lb1(px_d1), lb1(px_d1+1) );
                                    w1 <= (lb2(px_d1-1), lb2(px_d1), lb2(px_d1+1) );
                                    w2 <= (lb0(px_d1-1), lb0(px_d1), lb0(px_d1+1) );
                            end case;
                        end if;

                        -- Stage 3: output edge if valid
                        if v2='1' and px_d2 >= 2 and py_d2 >= 2 then
                            -- Sobel Gx = [-1 0 1; -2 0 2; -1 0 1]
                            -- Use x+x instead of 2*x to keep 12-bit width
                            gx_v := resize(signed('0'&w0(2)),12)
                                  - resize(signed('0'&w0(0)),12)
                                  + resize(signed('0'&w1(2)),12)
                                  + resize(signed('0'&w1(2)),12)
                                  - resize(signed('0'&w1(0)),12)
                                  - resize(signed('0'&w1(0)),12)
                                  + resize(signed('0'&w2(2)),12)
                                  - resize(signed('0'&w2(0)),12);
                            -- Sobel Gy = [-1 -2 -1; 0 0 0; 1 2 1]
                            gy_v := resize(signed('0'&w2(0)),12)
                                  + resize(signed('0'&w2(1)),12)
                                  + resize(signed('0'&w2(1)),12)
                                  + resize(signed('0'&w2(2)),12)
                                  - resize(signed('0'&w0(0)),12)
                                  - resize(signed('0'&w0(1)),12)
                                  - resize(signed('0'&w0(1)),12)
                                  - resize(signed('0'&w0(2)),12);
                            mag_v := unsigned(abs(gx_v)) + unsigned(abs(gy_v));
                            edge_valid <= '1';
                            edge_x <= std_logic_vector(to_unsigned(px_d2-2, 8));
                            edge_y <= std_logic_vector(to_unsigned(py_d2-2, 7));
                            if mag_v > THRESHOLD then
                                edge_out <= '1';
                            else
                                edge_out <= '0';
                            end if;
                            edge_mag <= std_logic_vector(mag_v(8 downto 1));
                        end if;

                        -- Advance counters
                        addr_cnt <= addr_cnt + 1;
                        if px = IMG_W-1 then
                            px <= 0;
                            if py = IMG_H-1 then state <= DONE_ST;
                            else py <= py+1; end if;
                        else px <= px+1; end if;

                    when DONE_ST =>
                        done <= '1'; state <= IDLE;
                        addr_cnt <= 0; px <= 0; py <= 0;
                    when others => state <= IDLE;
                end case;
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- 2. HSV BLOB DETECTOR
-- Detects red/yellow/green color blobs in RGB565 stream
-- Outputs area, centroid for each color
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hsv_blob_detector is
    generic (IMG_W : integer := 160; IMG_H : integer := 120);
    port (
        clk            : in  std_logic;
        rst            : in  std_logic;
        start          : in  std_logic;
        rd_addr        : out std_logic_vector(14 downto 0);
        rd_data        : in  std_logic_vector(7 downto 0);
        pix_rgb        : in  std_logic_vector(15 downto 0);
        pix_rgb_valid  : in  std_logic;
        pix_rgb_x      : in  std_logic_vector(7 downto 0);
        pix_rgb_y      : in  std_logic_vector(6 downto 0);
        red_area       : out std_logic_vector(15 downto 0);
        yellow_area    : out std_logic_vector(15 downto 0);
        green_area     : out std_logic_vector(15 downto 0);
        red_cx         : out std_logic_vector(7 downto 0);
        red_cy         : out std_logic_vector(6 downto 0);
        dominant_color : out std_logic_vector(1 downto 0);
        done           : out std_logic
    );
end hsv_blob_detector;

architecture Behavioral of hsv_blob_detector is
    signal red_acc    : unsigned(19 downto 0) := (others=>'0');
    signal yel_acc    : unsigned(19 downto 0) := (others=>'0');
    signal grn_acc    : unsigned(19 downto 0) := (others=>'0');
    signal red_sum_x  : unsigned(23 downto 0) := (others=>'0');
    signal red_sum_y  : unsigned(23 downto 0) := (others=>'0');
    type state_t is (IDLE, ACCUMULATE, COMPUTE, DONE_ST);
    signal state : state_t := IDLE;
begin
    process(clk)
        variable r5 : unsigned(4 downto 0);
        variable g6 : unsigned(5 downto 0);
        variable b5 : unsigned(4 downto 0);
        variable r8,g8,b8 : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if rst='1' then
                state<=IDLE; done<='0'; dominant_color<="00";
                red_acc<=(others=>'0'); yel_acc<=(others=>'0');
                grn_acc<=(others=>'0');
            else
                done <= '0';
                case state is
                    when IDLE =>
                        red_acc<=(others=>'0'); yel_acc<=(others=>'0');
                        grn_acc<=(others=>'0'); red_sum_x<=(others=>'0');
                        red_sum_y<=(others=>'0');
                        if start='1' then state<=ACCUMULATE; end if;

                    when ACCUMULATE =>
                        if pix_rgb_valid='1' then
                            r5 := unsigned(pix_rgb(15 downto 11));
                            g6 := unsigned(pix_rgb(10 downto 5));
                            b5 := unsigned(pix_rgb(4 downto 0));
                            r8 := r5 & r5(4 downto 2);
                            g8 := g6 & g6(5 downto 4);
                            b8 := b5 & b5(4 downto 2);
                            -- Red: R must be dominant
                            if r8 > 100 and r8 > g8 and r8 > b8 and g8 < 100 and b8 < 100 then
                                red_acc <= red_acc+1;
                                red_sum_x <= red_sum_x + resize(unsigned(pix_rgb_x),24);
                                red_sum_y <= red_sum_y + resize(unsigned(pix_rgb_y),24);
                            end if;
                            -- Yellow: R and G high, B low
                            if r8 > 100 and g8 > 100 and b8 < 100 then
                                yel_acc <= yel_acc+1;
                            end if;
                            -- Green: G must be dominant
                            if g8 > 100 and g8 > r8 and g8 > b8 and r8 < 100 then
                                grn_acc <= grn_acc+1;
                            end if;

                            -- Last pixel
                            if pix_rgb_x = std_logic_vector(to_unsigned(IMG_W-1,8))
                            and pix_rgb_y = std_logic_vector(to_unsigned(IMG_H-1,7)) then
                                state <= COMPUTE;
                            end if;
                        end if;

                    when COMPUTE =>
                        red_area    <= std_logic_vector(red_acc(15 downto 0));
                        yellow_area <= std_logic_vector(yel_acc(15 downto 0));
                        green_area  <= std_logic_vector(grn_acc(15 downto 0));
                        if red_acc>0 then
                            red_cx <= std_logic_vector(red_sum_x(22 downto 15));
                            red_cy <= std_logic_vector(red_sum_y(21 downto 15));
                        end if;
                        if red_acc>yel_acc and red_acc>grn_acc and red_acc>50 then
                            dominant_color <= "01";
                        elsif yel_acc>red_acc and yel_acc>grn_acc and yel_acc>50 then
                            dominant_color <= "10";
                        elsif grn_acc>50 then
                            dominant_color <= "11";
                        else
                            dominant_color <= "00";
                        end if;
                        state <= DONE_ST;

                    when DONE_ST =>
                        done <= '1'; state <= IDLE;
                    when others => state <= IDLE;
                end case;
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- 3. LANE DETECTOR
-- Scans horizontal rows to find left and right lane edges
-- Outputs: left_x, right_x for steering computation on RPi
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity lane_detector is
    generic (
        IMG_W    : integer := 160;
        IMG_H    : integer := 120;
        SCAN_ROW : integer := 90  -- Scan at 75% down the image
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        start      : in  std_logic;
        -- Edge map from sobel (streamed pixel by pixel)
        edge_valid : in  std_logic;
        edge_out   : in  std_logic;
        edge_x     : in  std_logic_vector(7 downto 0);
        edge_y     : in  std_logic_vector(6 downto 0);
        -- Lane outputs
        left_x     : out std_logic_vector(7 downto 0);
        right_x    : out std_logic_vector(7 downto 0);
        lane_valid : out std_logic;
        center_err : out signed(7 downto 0) -- Signed: negative=veer left, positive=veer right
    );
end lane_detector;

architecture Behavioral of lane_detector is
    signal left_x_r  : unsigned(7 downto 0) := to_unsigned(20, 8);   -- Default left
    signal right_x_r : unsigned(7 downto 0) := to_unsigned(140, 8);  -- Default right
    signal found_left : std_logic := '0';
    signal active     : std_logic := '0';
    constant CENTER   : integer := IMG_W / 2; -- 80
begin
    process(clk)
        variable x_int : integer;
        variable y_int : integer;
    begin
        if rising_edge(clk) then
            if rst='1' then
                left_x_r <= to_unsigned(20,8); right_x_r <= to_unsigned(140,8);
                lane_valid<='0'; active<='0'; found_left<='0';
            else
                lane_valid<='0';
                if start='1' then
                    active<='1'; found_left<='0';
                    left_x_r <= to_unsigned(0,8);
                    right_x_r <= to_unsigned(IMG_W-1,8);
                end if;

                if active='1' and edge_valid='1' then
                    x_int := to_integer(unsigned(edge_x));
                    y_int := to_integer(unsigned(edge_y));

                    -- Only look at SCAN_ROW
                    if y_int = SCAN_ROW and edge_out='1' then
                        if x_int < CENTER then
                            -- Left of center ? update left edge (take rightmost)
                            if unsigned(edge_x) > left_x_r then
                                left_x_r <= unsigned(edge_x);
                            end if;
                            found_left <= '1';
                        else
                            -- Right of center ? update right edge (take leftmost)
                            if found_left='0' or unsigned(edge_x) < right_x_r then
                                right_x_r <= unsigned(edge_x);
                            end if;
                        end if;
                    end if;

                    -- Last pixel of scan row ? output results
                    if y_int = SCAN_ROW and x_int = IMG_W-1 then
                        left_x  <= std_logic_vector(left_x_r);
                        right_x <= std_logic_vector(right_x_r);
                        -- Center error: positive = car is left of lane center, steer right
                        center_err <= to_signed(
                            CENTER - to_integer((left_x_r + right_x_r)/2), 8);
                        lane_valid <= '1';
                        active     <= '0';
                    end if;
                end if;
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- 4. SIGN CLASSIFIER
-- Hardware-based sign classification (1 clock latency)
-- Classes: NO_SIGN, STOP, WARNING, GO, PROHIBITION
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sign_classifier is
    generic (
        MIN_RED    : integer := 150;
        MIN_YELLOW : integer := 120;
        MIN_GREEN  : integer := 100
    );
    port (
        clk             : in  std_logic;
        rst             : in  std_logic;
        blob_done       : in  std_logic;
        red_area        : in  std_logic_vector(15 downto 0);
        yellow_area     : in  std_logic_vector(15 downto 0);
        green_area      : in  std_logic_vector(15 downto 0);
        red_cx          : in  std_logic_vector(7 downto 0);
        red_cy          : in  std_logic_vector(6 downto 0);
        sign_class      : out std_logic_vector(2 downto 0);
        sign_confidence : out std_logic_vector(7 downto 0);
        sign_valid      : out std_logic
    );
end sign_classifier;

architecture Behavioral of sign_classifier is
    -- 000=NONE 001=STOP 010=WARNING 011=GO 100=PROHIBITION 101=SPEED_LIMIT
    constant CLS_NONE  : std_logic_vector(2 downto 0) := "000";
    constant CLS_STOP  : std_logic_vector(2 downto 0) := "001";
    constant CLS_WARN  : std_logic_vector(2 downto 0) := "010";
    constant CLS_GO    : std_logic_vector(2 downto 0) := "011";
    constant CLS_PROHIB: std_logic_vector(2 downto 0) := "100";
begin
    process(clk)
        variable ra, ya, ga : unsigned(15 downto 0);
        variable conf       : unsigned(7 downto 0);
    begin
        if rising_edge(clk) then
            if rst='1' then
                sign_class<="000"; sign_confidence<=(others=>'0'); sign_valid<='0';
            else
                sign_valid<='0';
                if blob_done='1' then
                    sign_valid<='1';
                    ra := unsigned(red_area);
                    ya := unsigned(yellow_area);
                    ga := unsigned(green_area);

                    -- Confidence = min(area/8, 255)
                    if ra > 2040 then conf := x"FF";
                    else conf := unsigned(red_area(10 downto 3)); end if;

                    if ra >= MIN_RED and ra > ya and ra > ga then
                        -- Red dominant ? STOP or prohibition based on cx position
                        -- If centroid near center ? STOP (octagonal)
                        -- If centroid offset ? prohibition sign
                        if unsigned(red_cx) > 40 and unsigned(red_cx) < 120 then
                            sign_class <= CLS_STOP;
                        else
                            sign_class <= CLS_PROHIB;
                        end if;
                        sign_confidence <= std_logic_vector(conf);

                    elsif ya >= MIN_YELLOW and ya > ra and ya > ga then
                        sign_class <= CLS_WARN;
                        if ya > 2040 then sign_confidence <= x"FF";
                        else sign_confidence <= yellow_area(10 downto 3); end if;

                    elsif ga >= MIN_GREEN and ga > ra and ga > ya then
                        sign_class <= CLS_GO;
                        if ga > 2040 then sign_confidence <= x"FF";
                        else sign_confidence <= green_area(10 downto 3); end if;

                    else
                        sign_class <= CLS_NONE;
                        sign_confidence <= (others=>'0');
                    end if;
                end if;
            end if;
        end if;
    end process;
end Behavioral;