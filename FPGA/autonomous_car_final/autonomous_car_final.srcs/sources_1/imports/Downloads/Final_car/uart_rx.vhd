-- ============================================================
-- uart_rx.vhd
-- 8N1 UART Receiver @ 115200 baud, 100MHz clock
-- Receives commands from Raspberry Pi 5
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_rx is
    generic (
        CLK_FREQ  : integer := 100_000_000;
        BAUD_RATE : integer := 115_200
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        rx_in    : in  std_logic;
        rx_data  : out std_logic_vector(7 downto 0);
        rx_valid : out std_logic
    );
end uart_rx;

architecture Behavioral of uart_rx is
    constant CLKS_PER_BIT  : integer := CLK_FREQ / BAUD_RATE;
    constant HALF_BIT      : integer := CLKS_PER_BIT / 2;
    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state   : state_t := IDLE;
    signal clk_cnt : integer range 0 to CLKS_PER_BIT-1 := 0;
    signal bit_idx : integer range 0 to 7 := 0;
    signal rx_sync : std_logic_vector(1 downto 0) := "11";
    signal rx_r    : std_logic_vector(7 downto 0) := (others => '0');
begin
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE; rx_valid <= '0';
                clk_cnt <= 0; bit_idx <= 0; rx_sync <= "11";
            else
                rx_sync <= rx_sync(0) & rx_in;
                rx_valid <= '0';
                case state is
                    when IDLE =>
                        clk_cnt <= 0; bit_idx <= 0;
                        if rx_sync(1) = '0' then state <= START_BIT; end if;
                    when START_BIT =>
                        if clk_cnt = HALF_BIT then
                            if rx_sync(1) = '0' then clk_cnt <= 0; state <= DATA_BITS;
                            else state <= IDLE; end if;
                        else clk_cnt <= clk_cnt + 1; end if;
                    when DATA_BITS =>
                        if clk_cnt = CLKS_PER_BIT-1 then
                            clk_cnt <= 0;
                            rx_r(bit_idx) <= rx_sync(1);
                            if bit_idx = 7 then bit_idx <= 0; state <= STOP_BIT;
                            else bit_idx <= bit_idx + 1; end if;
                        else clk_cnt <= clk_cnt + 1; end if;
                    when STOP_BIT =>
                        if clk_cnt = CLKS_PER_BIT-1 then
                            clk_cnt <= 0; state <= IDLE;
                            if rx_sync(1) = '1' then
                                rx_data <= rx_r; rx_valid <= '1';
                            end if;
                        else clk_cnt <= clk_cnt + 1; end if;
                end case;
            end if;
        end if;
    end process;
end Behavioral;
