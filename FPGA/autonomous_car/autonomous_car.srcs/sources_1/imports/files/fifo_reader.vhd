-- =============================================================================
-- fifo_reader.vhd
-- AL422B FIFO Reader for OV7670+FIFO module
-- Reads one complete QQVGA (160x120) RGB565 frame
-- Frame = 160 * 120 * 2 bytes = 38,400 bytes
--
-- AL422B Signals:
--   WRST_N : Write reset (active low) — resets FIFO write pointer
--   RRST_N : Read reset  (active low) — resets FIFO read pointer
--   OE_N   : Output enable (active low)
--   RCK    : Read clock (provided by FPGA — we generate this)
--   WEN    : Write enable (from camera HREF & VSYNC — tied externally)
--   VSYNC  : From OV7670 — high when new frame starts
--
-- Output: pixel data (RGB565, 16-bit) + valid + x,y coordinates
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity fifo_reader is
    generic (
        IMG_W : integer := 160;
        IMG_H : integer := 120
    );
    port (
        clk        : in  std_logic;
        rst        : in  std_logic;
        start      : in  std_logic;   -- Pulse to capture one frame

        -- AL422B FIFO control
        vsync      : in  std_logic;
        fifo_d     : in  std_logic_vector(7 downto 0);
        wrst_n     : out std_logic;
        rrst_n     : out std_logic;
        oe_n       : out std_logic;
        rck        : out std_logic;

        -- Pixel output (assembled RGB565)
        pix_data   : out std_logic_vector(15 downto 0); -- RGB565
        pix_valid  : out std_logic;
        pix_x      : out std_logic_vector(7 downto 0);  -- 0..159
        pix_y      : out std_logic_vector(6 downto 0);  -- 0..119
        frame_done : out std_logic
    );
end fifo_reader;

architecture Behavioral of fifo_reader is

    type state_t is (
        IDLE,
        WAIT_VSYNC_HIGH,   -- Wait for new frame
        RESET_WRITE_PTR,   -- Pulse WRST low
        WAIT_VSYNC_LOW,    -- Wait for frame to fully write to FIFO
        RESET_READ_PTR,    -- Pulse RRST low + enable OE
        READ_BYTE1,        -- Read high byte of RGB565
        READ_BYTE2,        -- Read low byte of RGB565 + output pixel
        FRAME_DONE_ST
    );

    signal state     : state_t := IDLE;

    -- Clock divider for RCK (FIFO read clock ~25 MHz max)
    -- At 100 MHz, divide by 4 → 25 MHz RCK
    constant RCK_DIV : integer := 4;
    signal rck_cnt   : integer range 0 to RCK_DIV - 1 := 0;
    signal rck_r     : std_logic := '0';

    -- Pixel/frame counters
    signal x_cnt     : integer range 0 to IMG_W - 1 := 0;
    signal y_cnt     : integer range 0 to IMG_H - 1 := 0;
    signal byte1     : std_logic_vector(7 downto 0) := (others => '0');

    -- Control registers
    signal wrst_n_r  : std_logic := '1';
    signal rrst_n_r  : std_logic := '1';
    signal oe_n_r    : std_logic := '1';

    -- Delay counter for reset pulses
    signal delay_cnt : integer range 0 to 255 := 0;

    -- Pixel valid registered
    signal pix_valid_r : std_logic := '0';

    -- RCK rising edge detector
    signal rck_prev  : std_logic := '0';
    signal rck_rise  : std_logic := '0';

begin

    wrst_n    <= wrst_n_r;
    rrst_n    <= rrst_n_r;
    oe_n      <= oe_n_r;
    rck       <= rck_r;
    pix_valid <= pix_valid_r;
    pix_x     <= std_logic_vector(to_unsigned(x_cnt, 8));
    pix_y     <= std_logic_vector(to_unsigned(y_cnt, 7));

    -- Generate RCK (read clock for FIFO)
    process(clk)
    begin
        if rising_edge(clk) then
            rck_prev <= rck_r;
            if rck_cnt = RCK_DIV - 1 then
                rck_cnt <= 0;
                rck_r   <= not rck_r;
            else
                rck_cnt <= rck_cnt + 1;
            end if;
        end if;
    end process;

    rck_rise <= '1' when (rck_r = '1' and rck_prev = '0') else '0';

    -- Main state machine
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state       <= IDLE;
                wrst_n_r    <= '1';
                rrst_n_r    <= '1';
                oe_n_r      <= '1';
                pix_valid_r <= '0';
                frame_done  <= '0';
                x_cnt       <= 0;
                y_cnt       <= 0;
                delay_cnt   <= 0;
            else
                pix_valid_r <= '0'; -- Default
                frame_done  <= '0'; -- Default

                case state is

                    when IDLE =>
                        wrst_n_r <= '1';
                        rrst_n_r <= '1';
                        oe_n_r   <= '1';
                        x_cnt    <= 0;
                        y_cnt    <= 0;
                        if start = '1' then
                            state <= WAIT_VSYNC_HIGH;
                        end if;

                    -- Wait for VSYNC to go high (marks start of new frame)
                    when WAIT_VSYNC_HIGH =>
                        if vsync = '1' then
                            state     <= RESET_WRITE_PTR;
                            delay_cnt <= 0;
                            wrst_n_r  <= '0'; -- Pull WRST low immediately
                        end if;

                    -- Hold WRST low for a few cycles, then release
                    -- Camera will now write frame to FIFO
                    when RESET_WRITE_PTR =>
                        if delay_cnt = 10 then
                            wrst_n_r  <= '1'; -- Release write reset
                            delay_cnt <= 0;
                            state     <= WAIT_VSYNC_LOW;
                        else
                            delay_cnt <= delay_cnt + 1;
                        end if;

                    -- Wait for VSYNC to go low — frame fully in FIFO
                    when WAIT_VSYNC_LOW =>
                        if vsync = '0' then
                            state     <= RESET_READ_PTR;
                            delay_cnt <= 0;
                            rrst_n_r  <= '0'; -- Pull RRST low
                            oe_n_r    <= '0'; -- Enable output
                        end if;

                    -- Hold RRST low briefly, then release to start reading
                    when RESET_READ_PTR =>
                        if delay_cnt = 10 then
                            rrst_n_r  <= '1'; -- Release read reset
                            delay_cnt <= 0;
                            state     <= READ_BYTE1;
                        else
                            delay_cnt <= delay_cnt + 1;
                        end if;

                    -- Read first byte of RGB565 (high byte) on RCK rising edge
                    when READ_BYTE1 =>
                        if rck_rise = '1' then
                            byte1 <= fifo_d;
                            state <= READ_BYTE2;
                        end if;

                    -- Read second byte, assemble pixel, output
                    when READ_BYTE2 =>
                        if rck_rise = '1' then
                            pix_data    <= byte1 & fifo_d; -- RGB565 assembled
                            pix_valid_r <= '1';

                            -- Advance pixel coordinates
                            if x_cnt = IMG_W - 1 then
                                x_cnt <= 0;
                                if y_cnt = IMG_H - 1 then
                                    y_cnt  <= 0;
                                    state  <= FRAME_DONE_ST;
                                else
                                    y_cnt <= y_cnt + 1;
                                    state <= READ_BYTE1;
                                end if;
                            else
                                x_cnt <= x_cnt + 1;
                                state <= READ_BYTE1;
                            end if;
                        end if;

                    when FRAME_DONE_ST =>
                        oe_n_r     <= '1'; -- Disable FIFO output
                        frame_done <= '1';
                        state      <= IDLE;

                    when others =>
                        state <= IDLE;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
