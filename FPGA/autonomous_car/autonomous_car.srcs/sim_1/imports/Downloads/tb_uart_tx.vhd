library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_uart_tx is
end tb_uart_tx;

architecture Behavioral of tb_uart_tx is

    signal clk      : std_logic := '0';
    signal rst      : std_logic := '1';
    signal tx_data  : std_logic_vector(7 downto 0) := (others => '0');
    signal tx_valid : std_logic := '0';
    signal tx_ready : std_logic;
    signal tx_out   : std_logic;

    constant CLK_PERIOD  : time := 10 ns;
    constant BYTE_TIME   : time := 100 us; -- safe wait per byte at 115200

begin

    clk <= not clk after CLK_PERIOD / 2;

    uut : entity work.uart_tx
        generic map (CLK_FREQ => 100_000_000, BAUD_RATE => 115_200)
        port map (
            clk      => clk,
            rst      => rst,
            tx_data  => tx_data,
            tx_valid => tx_valid,
            tx_ready => tx_ready,
            tx_out   => tx_out
        );

    process
    begin
        -- Reset
        rst <= '1';
        wait for 500 ns;
        rst <= '0';
        wait for 500 ns;

        -- Send byte 1: 0xAA (start marker)
        tx_data  <= x"AA";
        tx_valid <= '1';
        wait for CLK_PERIOD;
        tx_valid <= '0';
        wait for BYTE_TIME;

        -- Send byte 2: 0x01 (RED color)
        tx_data  <= x"01";
        tx_valid <= '1';
        wait for CLK_PERIOD;
        tx_valid <= '0';
        wait for BYTE_TIME;

        -- Send byte 3: 0x55 (end marker)
        tx_data  <= x"55";
        tx_valid <= '1';
        wait for CLK_PERIOD;
        tx_valid <= '0';
        wait for BYTE_TIME;

        report "DONE - 3 bytes sent" severity note;
        wait;
    end process;

end Behavioral;