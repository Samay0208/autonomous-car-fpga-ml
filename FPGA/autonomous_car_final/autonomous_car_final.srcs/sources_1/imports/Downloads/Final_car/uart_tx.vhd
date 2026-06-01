-- ============================================================
-- uart_tx.vhd
-- 8N1 UART Transmitter @ 115200 baud, 100MHz clock
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity uart_tx is
    generic (
        CLK_FREQ  : integer := 100_000_000;
        BAUD_RATE : integer := 115_200
    );
    port (
        clk      : in  std_logic;
        rst      : in  std_logic;
        tx_data  : in  std_logic_vector(7 downto 0);
        tx_valid : in  std_logic;
        tx_ready : out std_logic;
        tx_out   : out std_logic
    );
end uart_tx;

architecture Behavioral of uart_tx is
    constant CLKS_PER_BIT : integer := CLK_FREQ / BAUD_RATE;
    type state_t is (IDLE, START_BIT, DATA_BITS, STOP_BIT);
    signal state   : state_t := IDLE;
    signal clk_cnt : integer range 0 to CLKS_PER_BIT-1 := 0;
    signal bit_idx : integer range 0 to 7 := 0;
    signal tx_reg  : std_logic_vector(7 downto 0);
    signal ready_r : std_logic := '1';
begin
    tx_ready <= ready_r;
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE; tx_out <= '1'; ready_r <= '1';
                clk_cnt <= 0; bit_idx <= 0;
            else
                case state is
                    when IDLE =>
                        tx_out <= '1'; ready_r <= '1'; clk_cnt <= 0; bit_idx <= 0;
                        if tx_valid = '1' then
                            tx_reg <= tx_data; ready_r <= '0'; state <= START_BIT;
                        end if;
                    when START_BIT =>
                        tx_out <= '0';
                        if clk_cnt = CLKS_PER_BIT-1 then clk_cnt <= 0; state <= DATA_BITS;
                        else clk_cnt <= clk_cnt + 1; end if;
                    when DATA_BITS =>
                        tx_out <= tx_reg(bit_idx);
                        if clk_cnt = CLKS_PER_BIT-1 then
                            clk_cnt <= 0;
                            if bit_idx = 7 then bit_idx <= 0; state <= STOP_BIT;
                            else bit_idx <= bit_idx + 1; end if;
                        else clk_cnt <= clk_cnt + 1; end if;
                    when STOP_BIT =>
                        tx_out <= '1';
                        if clk_cnt = CLKS_PER_BIT-1 then
                            clk_cnt <= 0; state <= IDLE; ready_r <= '1';
                        else clk_cnt <= clk_cnt + 1; end if;
                end case;
            end if;
        end if;
    end process;
end Behavioral;
