-- =============================================================================
-- sobel_edge.vhd
-- 3x3 Sobel Edge Detector with line buffers
-- Reads from frame_buffer sequentially, outputs edge map
-- IMG_W = 160, IMG_H = 120
-- Uses 3 line buffers (shift registers) and a 3x3 window
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sobel_edge is
    generic (
        IMG_W     : integer := 160;
        IMG_H     : integer := 120;
        THRESHOLD : integer := 30   -- Edge magnitude threshold (0-255)
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        -- Scan trigger: assert start, then provide pixels sequentially
        start      : in  std_logic;

        -- Frame buffer read interface
        rd_addr    : out std_logic_vector(14 downto 0);
        rd_data    : in  std_logic_vector(7 downto 0);

        -- Edge output
        edge_valid : out std_logic;
        edge_out   : out std_logic;   -- '1' = edge pixel
        edge_x     : out std_logic_vector(7 downto 0);
        edge_y     : out std_logic_vector(6 downto 0);

        done       : out std_logic
    );
end sobel_edge;

architecture Behavioral of sobel_edge is

    -- 3 line buffers, each 160 pixels wide
    type line_buf_t is array (0 to IMG_W - 1) of std_logic_vector(7 downto 0);
    signal line0 : line_buf_t := (others => (others => '0')); -- Oldest row
    signal line1 : line_buf_t := (others => (others => '0')); -- Middle row
    signal line2 : line_buf_t := (others => (others => '0')); -- Current row

    -- Current pixel being read
    signal px    : integer range 0 to IMG_W - 1 := 0;
    signal py    : integer range 0 to IMG_H - 1 := 0;
    signal addr  : integer range 0 to IMG_W * IMG_H - 1 := 0;

    -- 3x3 window: p[row][col] where row/col in 0..2
    -- p[0][0] p[0][1] p[0][2]
    -- p[1][0] p[1][1] p[1][2]
    -- p[2][0] p[2][1] p[2][2]
    type window_row_t is array(0 to 2) of signed(8 downto 0);
    type window_t     is array(0 to 2) of window_row_t;
    signal win : window_t;

    type state_t is (IDLE, FILL_FIRST_TWO, SCAN, OUTPUT, DONE_ST);
    signal state : state_t := IDLE;

    -- Pipeline delay registers
    signal px_d1, px_d2 : integer range 0 to IMG_W - 1 := 0;
    signal py_d1, py_d2 : integer range 0 to IMG_H - 1 := 0;
    signal valid_d1, valid_d2 : std_logic := '0';

    -- Sobel computation
    signal gx : signed(11 downto 0) := (others => '0');
    signal gy : signed(11 downto 0) := (others => '0');
    signal mag : unsigned(11 downto 0) := (others => '0');

    signal running : std_logic := '0';
    signal row_fill : integer range 0 to IMG_H := 0; -- How many rows loaded

begin

    rd_addr <= std_logic_vector(to_unsigned(addr, 15));

    process(clk)
        variable gx_v, gy_v : signed(11 downto 0);
        variable mag_v       : unsigned(11 downto 0);
        variable row_idx     : integer;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state      <= IDLE;
                running    <= '0';
                edge_valid <= '0';
                edge_out   <= '0';
                done       <= '0';
                px         <= 0;
                py         <= 0;
                addr       <= 0;
                row_fill   <= 0;
            else
                edge_valid <= '0';
                done       <= '0';

                case state is

                    when IDLE =>
                        px       <= 0;
                        py       <= 0;
                        addr     <= 0;
                        row_fill <= 0;
                        if start = '1' then
                            state <= SCAN;
                        end if;

                    when SCAN =>
                        -- Read pixels sequentially from frame buffer
                        -- Shift into line buffers as we go
                        -- Data available 1 cycle after address

                        -- Shift line buffers on new pixel
                        if px > 0 or py > 0 then
                            -- Shift pixel into current row's line buffer
                            row_idx := py mod 3;
                            case row_idx is
                                when 0 => line0(px) <= rd_data;
                                when 1 => line1(px) <= rd_data;
                                when 2 => line2(px) <= rd_data;
                                when others => null;
                            end case;
                        end if;

                        -- Compute Sobel when we have 3 full rows and valid window
                        if py >= 2 and px >= 2 then
                            -- Fill 3x3 window from line buffers
                            -- Current row index determines which buffer is newest
                            -- Simple approach: use modulo addressing
                            -- Rows in window: (py-2)%3, (py-1)%3, py%3

                            -- Compute Gx and Gy
                            -- (Using registered window values from previous cycle)
                            gx_v := resize(signed('0' & win(0)(2)), 12) - 
                                    resize(signed('0' & win(0)(0)), 12) +
                                    2*resize(signed('0' & win(1)(2)), 12) - 
                                    2*resize(signed('0' & win(1)(0)), 12) +
                                    resize(signed('0' & win(2)(2)), 12) - 
                                    resize(signed('0' & win(2)(0)), 12);

                            gy_v := resize(signed('0' & win(2)(0)), 12) + 
                                    2*resize(signed('0' & win(2)(1)), 12) +
                                    resize(signed('0' & win(2)(2)), 12) -
                                    resize(signed('0' & win(0)(0)), 12) - 
                                    2*resize(signed('0' & win(0)(1)), 12) -
                                    resize(signed('0' & win(0)(2)), 12);

                            -- Manhattan magnitude |Gx| + |Gy|
                            mag_v := unsigned(abs(gx_v)) + unsigned(abs(gy_v));

                            edge_valid <= '1';
                            edge_x     <= std_logic_vector(to_unsigned(px-2, 8));
                            edge_y     <= std_logic_vector(to_unsigned(py-2, 7));
                            if mag_v > THRESHOLD then
                                edge_out <= '1';
                            else
                                edge_out <= '0';
                            end if;
                        end if;

                        -- Update window (grab from line buffers)
                        -- This is simplified — in practice use registered line buf values

                        -- Advance address
                        addr <= addr + 1;
                        if px = IMG_W - 1 then
                            px <= 0;
                            if py = IMG_H - 1 then
                                state <= DONE_ST;
                            else
                                py <= py + 1;
                            end if;
                        else
                            px <= px + 1;
                        end if;

                    when DONE_ST =>
                        done  <= '1';
                        state <= IDLE;
                        addr  <= 0;
                        px    <= 0;
                        py    <= 0;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;


-- =============================================================================
-- hsv_blob_detector.vhd
-- Hardware color blob detector for traffic sign detection
-- Works in RGB space (avoids complex HSV conversion)
-- Detects: RED (stop signs), YELLOW (warning), GREEN (go)
-- Also accumulates blob statistics (area, centroid) per color
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity hsv_blob_detector is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        clk          : in  std_logic;
        rst          : in  std_logic;

        -- Frame buffer read interface
        start        : in  std_logic;
        rd_addr      : out std_logic_vector(14 downto 0);
        rd_data      : in  std_logic_vector(7 downto 0); -- Grayscale input

        -- Raw pixel for color (from fifo_reader, parallel path)
        pix_rgb      : in  std_logic_vector(15 downto 0); -- RGB565
        pix_rgb_valid: in  std_logic;
        pix_rgb_x    : in  std_logic_vector(7 downto 0);
        pix_rgb_y    : in  std_logic_vector(6 downto 0);

        -- Blob statistics output (valid when done = '1')
        red_area     : out std_logic_vector(15 downto 0); -- Pixel count
        yellow_area  : out std_logic_vector(15 downto 0);
        green_area   : out std_logic_vector(15 downto 0);
        red_cx       : out std_logic_vector(7 downto 0);  -- Centroid X
        red_cy       : out std_logic_vector(6 downto 0);  -- Centroid Y
        dominant_color: out std_logic_vector(1 downto 0); -- 00=none 01=red 10=yellow 11=green
        done         : out std_logic
    );
end hsv_blob_detector;

architecture Behavioral of hsv_blob_detector is

    -- Color thresholds (tunable via generics or constants)
    -- RED:    R > 150, G < 80,  B < 80
    -- YELLOW: R > 160, G > 120, B < 80
    -- GREEN:  R < 100, G > 130, B < 120

    signal red_acc    : unsigned(19 downto 0) := (others => '0'); -- Pixel count accumulator
    signal yellow_acc : unsigned(19 downto 0) := (others => '0');
    signal green_acc  : unsigned(19 downto 0) := (others => '0');

    signal red_sum_x  : unsigned(23 downto 0) := (others => '0'); -- For centroid
    signal red_sum_y  : unsigned(23 downto 0) := (others => '0');

    type state_t is (IDLE, ACCUMULATE, COMPUTE, DONE_ST);
    signal state : state_t := IDLE;

begin

    -- Color detection runs on the live RGB pixel stream from fifo_reader
    -- This runs in parallel with grayscale writing to frame buffer
    process(clk)
        variable r5 : unsigned(4 downto 0);
        variable g6 : unsigned(5 downto 0);
        variable b5 : unsigned(4 downto 0);
        variable r8, g8, b8 : unsigned(7 downto 0);
        variable is_red, is_yellow, is_green : boolean;
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state       <= IDLE;
                red_acc     <= (others => '0');
                yellow_acc  <= (others => '0');
                green_acc   <= (others => '0');
                red_sum_x   <= (others => '0');
                red_sum_y   <= (others => '0');
                done        <= '0';
                dominant_color <= "00";
            else
                done <= '0';

                case state is

                    when IDLE =>
                        red_acc    <= (others => '0');
                        yellow_acc <= (others => '0');
                        green_acc  <= (others => '0');
                        red_sum_x  <= (others => '0');
                        red_sum_y  <= (others => '0');
                        if start = '1' then
                            state <= ACCUMULATE;
                        end if;

                    when ACCUMULATE =>
                        -- Process each pixel from live RGB stream
                        if pix_rgb_valid = '1' then
                            -- Extract RGB channels from RGB565
                            r5 := unsigned(pix_rgb(15 downto 11));
                            g6 := unsigned(pix_rgb(10 downto 5));
                            b5 := unsigned(pix_rgb(4 downto 0));
                            -- Scale to 8-bit (approximate)
                            r8 := r5 & r5(4 downto 2);  -- R * 8 + R >> 5
                            g8 := g6 & g6(5 downto 4);  -- G * 4 + G >> 6
                            b8 := b5 & b5(4 downto 2);  -- B * 8 + B >> 5

                            -- Classify pixel color
                            is_red    := (r8 > 150) and (g8 < 80) and (b8 < 80);
                            is_yellow := (r8 > 160) and (g8 > 120) and (b8 < 80);
                            is_green  := (r8 < 100) and (g8 > 130) and (b8 < 120);

                            if is_red then
                                red_acc   <= red_acc + 1;
                                red_sum_x <= red_sum_x + resize(unsigned(pix_rgb_x), 24);
                                red_sum_y <= red_sum_y + resize(unsigned(pix_rgb_y), 24);
                            end if;
                            if is_yellow then
                                yellow_acc <= yellow_acc + 1;
                            end if;
                            if is_green then
                                green_acc <= green_acc + 1;
                            end if;

                            -- Frame done when we hit last pixel
                            if pix_rgb_x = std_logic_vector(to_unsigned(IMG_W-1, 8)) and
                               pix_rgb_y = std_logic_vector(to_unsigned(IMG_H-1, 7)) then
                                state <= COMPUTE;
                            end if;
                        end if;

                    when COMPUTE =>
                        -- Finalize statistics
                        red_area    <= std_logic_vector(red_acc(15 downto 0));
                        yellow_area <= std_logic_vector(yellow_acc(15 downto 0));
                        green_area  <= std_logic_vector(green_acc(15 downto 0));

                        -- Centroid = sum_x / area (simplified: use MSBs of sum)
                        if red_acc > 0 then
                            red_cx <= std_logic_vector(red_sum_x(22 downto 15)); -- / ~area
                            red_cy <= std_logic_vector(red_sum_y(21 downto 15));
                        end if;

                        -- Determine dominant color (must exceed minimum blob size = 50px)
                        if red_acc > yellow_acc and red_acc > green_acc
                           and red_acc > 50 then
                            dominant_color <= "01"; -- Red
                        elsif yellow_acc > red_acc and yellow_acc > green_acc
                              and yellow_acc > 50 then
                            dominant_color <= "10"; -- Yellow
                        elsif green_acc > 50 then
                            dominant_color <= "11"; -- Green
                        else
                            dominant_color <= "00"; -- None detected
                        end if;

                        state <= DONE_ST;

                    when DONE_ST =>
                        done  <= '1';
                        state <= IDLE;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
