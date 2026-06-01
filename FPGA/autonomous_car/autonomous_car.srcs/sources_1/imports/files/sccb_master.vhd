-- =============================================================================
-- sccb_master.vhd
-- SCCB (Serial Camera Control Bus) Master — I2C-compatible
-- Configures OV7670 registers at startup
-- OV7670 write address: 0x42  read address: 0x43
-- SCCB clock: 100 kHz (Basys 3 @ 100 MHz)
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sccb_master is
    generic (
        CLK_FREQ  : integer := 100_000_000;
        SCCB_FREQ : integer := 100_000
    );
    port (
        clk       : in    std_logic;
        rst       : in    std_logic;
        -- Control interface
        wr_en     : in    std_logic;                    -- Pulse to start write
        reg_addr  : in    std_logic_vector(7 downto 0); -- OV7670 register address
        reg_data  : in    std_logic_vector(7 downto 0); -- Data to write
        busy      : out   std_logic;                    -- High while transaction active
        done      : out   std_logic;                    -- 1-cycle pulse on completion
        -- SCCB pins
        sio_c     : out   std_logic;
        sio_d     : inout std_logic
    );
end sccb_master;

architecture Behavioral of sccb_master is

    -- Clock divider: 100MHz / 100kHz = 1000 cycles per SCCB bit
    -- Quarter period = 250 cycles (we use 4-phase clocking)
    constant HALF_PERIOD : integer := CLK_FREQ / (2 * SCCB_FREQ); -- 500

    type state_t is (
        IDLE,
        START,
        SEND_ADDR,   -- Device address (0x42)
        ACK1,
        SEND_REG,    -- Register address
        ACK2,
        SEND_DATA,   -- Register data
        ACK3,
        STOP,
        DONE_ST
    );

    signal state    : state_t := IDLE;
    signal clk_cnt  : integer range 0 to HALF_PERIOD - 1 := 0;
    signal phase    : std_logic := '0'; -- 0=low half, 1=high half of SCCB clock
    signal bit_cnt  : integer range 0 to 7 := 7;
    signal shift_r  : std_logic_vector(7 downto 0) := (others => '0');

    -- Tri-state for sio_d
    signal sda_out  : std_logic := '1';
    signal sda_oe   : std_logic := '0'; -- Output enable
    signal sio_c_r  : std_logic := '1';

    -- Latched inputs
    signal reg_addr_r : std_logic_vector(7 downto 0) := (others => '0');
    signal reg_data_r : std_logic_vector(7 downto 0) := (others => '0');

    -- Device write address
    constant DEV_ADDR : std_logic_vector(7 downto 0) := x"42";

begin

    -- Tri-state buffer for SDA
    sio_d <= sda_out when sda_oe = '1' else 'Z';
    sio_c <= sio_c_r;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state    <= IDLE;
                sio_c_r  <= '1';
                sda_out  <= '1';
                sda_oe   <= '1';
                busy     <= '0';
                done     <= '0';
                clk_cnt  <= 0;
                phase    <= '0';
            else
                done <= '0'; -- Default

                -- Clock divider
                if clk_cnt = HALF_PERIOD - 1 then
                    clk_cnt <= 0;
                    phase   <= not phase;

                    case state is

                        when IDLE =>
                            sio_c_r <= '1';
                            sda_out <= '1';
                            sda_oe  <= '1';
                            busy    <= '0';
                            if wr_en = '1' then
                                reg_addr_r <= reg_addr;
                                reg_data_r <= reg_data;
                                busy       <= '1';
                                state      <= START;
                                phase      <= '0';
                            end if;

                        -- START condition: SDA goes low while SCL high
                        when START =>
                            if phase = '0' then
                                sio_c_r <= '1';
                                sda_out <= '1';
                            else
                                sda_out <= '0'; -- SDA low while SCL high = START
                                sio_c_r <= '1';
                                shift_r <= DEV_ADDR;
                                bit_cnt <= 7;
                                state   <= SEND_ADDR;
                                phase   <= '0';
                            end if;

                        -- Send 8 bits, MSB first
                        when SEND_ADDR | SEND_REG | SEND_DATA =>
                            sda_oe <= '1';
                            if phase = '0' then
                                sio_c_r <= '0';
                                sda_out <= shift_r(bit_cnt);
                            else
                                sio_c_r <= '1'; -- Clock high = data valid
                                if bit_cnt = 0 then
                                    case state is
                                        when SEND_ADDR => state <= ACK1;
                                        when SEND_REG  => state <= ACK2;
                                        when SEND_DATA => state <= ACK3;
                                        when others    => null;
                                    end case;
                                    phase <= '0';
                                else
                                    bit_cnt <= bit_cnt - 1;
                                end if;
                            end if;

                        -- SCCB uses "don't care" acknowledge — release SDA and clock once
                        when ACK1 | ACK2 =>
                            sda_oe <= '0'; -- Release (input mode, don't care)
                            if phase = '0' then
                                sio_c_r <= '0';
                            else
                                sio_c_r <= '1';
                                -- Load next byte
                                case state is
                                    when ACK1 =>
                                        shift_r <= reg_addr_r;
                                        bit_cnt <= 7;
                                        state   <= SEND_REG;
                                    when ACK2 =>
                                        shift_r <= reg_data_r;
                                        bit_cnt <= 7;
                                        state   <= SEND_DATA;
                                    when others => null;
                                end case;
                                phase <= '0';
                            end if;

                        when ACK3 =>
                            sda_oe <= '0';
                            if phase = '0' then
                                sio_c_r <= '0';
                            else
                                sio_c_r <= '1';
                                state   <= STOP;
                                phase   <= '0';
                            end if;

                        -- STOP condition: SDA goes high while SCL high
                        when STOP =>
                            sda_oe <= '1';
                            if phase = '0' then
                                sio_c_r <= '0';
                                sda_out <= '0';
                            else
                                sio_c_r <= '1';
                                sda_out <= '1'; -- SDA high while SCL high = STOP
                                state   <= DONE_ST;
                                phase   <= '0';
                            end if;

                        when DONE_ST =>
                            done  <= '1';
                            busy  <= '0';
                            state <= IDLE;

                        when others =>
                            state <= IDLE;

                    end case;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            end if;
        end if;
    end process;

end Behavioral;
