library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity tb_top is
end tb_top;

architecture sim of tb_top is

    signal clk_100  : std_logic := '0';
    signal rst_btn  : std_logic := '1';

    signal ov_pclk  : std_logic := '0';
    signal ov_vsync : std_logic := '0';
    signal ov_href  : std_logic := '0';
    signal ov_d     : std_logic_vector(7 downto 0) := (others=>'0');

    signal sio_c    : std_logic;
    signal sio_d    : std_logic := 'Z';
    signal xclk     : std_logic;

    signal uart_tx  : std_logic;
    signal uart_rx  : std_logic := '1';

    signal led      : std_logic_vector(15 downto 0);

    constant CLK_PERIOD  : time := 10 ns;
    constant PCLK_PERIOD : time := 80 ns;

begin

    ------------------------------------------------------------------
    -- DUT
    ------------------------------------------------------------------

    uut : entity work.top
    port map(
        clk_100  => clk_100,
        rst_btn  => rst_btn,
        ov_pclk  => ov_pclk,
        ov_vsync => ov_vsync,
        ov_href  => ov_href,
        ov_d     => ov_d,
        sio_c    => sio_c,
        sio_d    => sio_d,
        xclk     => xclk,
        uart_tx  => uart_tx,
        uart_rx  => uart_rx,
        led      => led
    );

    ------------------------------------------------------------------
    -- 100 MHz clock
    ------------------------------------------------------------------

    clk_process : process
    begin
        while true loop
            clk_100 <= '0';
            wait for CLK_PERIOD/2;
            clk_100 <= '1';
            wait for CLK_PERIOD/2;
        end loop;
    end process;

    ------------------------------------------------------------------
    -- Camera PCLK
    ------------------------------------------------------------------

    pclk_process : process
    begin
        while true loop
            ov_pclk <= '0';
            wait for PCLK_PERIOD/2;
            ov_pclk <= '1';
            wait for PCLK_PERIOD/2;
        end loop;
    end process;

    ------------------------------------------------------------------
    -- Reset
    ------------------------------------------------------------------

    reset_process : process
    begin
        wait for 200 ns;
        rst_btn <= '0';
        wait;
    end process;

    ------------------------------------------------------------------
    -- Fake OV7670 Camera Generator
    ------------------------------------------------------------------

    camera_process : process

        variable x : integer := 0;
        variable y : integer := 0;

        variable pixel : std_logic_vector(15 downto 0);

    begin

        wait until rst_btn='0';

        wait for 1 us;

        ------------------------------------------------------------------
        -- FRAME START
        ------------------------------------------------------------------

        ov_vsync <= '1';
        wait for 2 us;
        ov_vsync <= '0';

        ------------------------------------------------------------------
        -- 320x240 IMAGE
        ------------------------------------------------------------------

        for y in 0 to 239 loop

            ov_href <= '1';

            for x in 0 to 319 loop

                ----------------------------------------------------------
                -- BLACK BACKGROUND
                ----------------------------------------------------------

                pixel := x"0000";

                ----------------------------------------------------------
                -- WHITE LANE LINES
                ----------------------------------------------------------

                if (x=80 or x=240) then
                    pixel := x"FFFF";
                end if;

                ----------------------------------------------------------
                -- RED SIGN BLOB
                ----------------------------------------------------------

                if (x>120 and x<200 and y>90 and y<150) then
                    pixel := x"F800";
                end if;

                ----------------------------------------------------------
                -- HIGH BYTE
                ----------------------------------------------------------

                ov_d <= pixel(15 downto 8);
                wait until rising_edge(ov_pclk);

                ----------------------------------------------------------
                -- LOW BYTE
                ----------------------------------------------------------

                ov_d <= pixel(7 downto 0);
                wait until rising_edge(ov_pclk);

            end loop;

            ov_href <= '0';

            wait for 2 us;

        end loop;

        ------------------------------------------------------------------
        -- FRAME GAP
        ------------------------------------------------------------------

        wait for 10 us;

        ------------------------------------------------------------------
        -- STOP SIMULATION
        ------------------------------------------------------------------

        assert false report "Simulation Finished Successfully" severity failure;

    end process;

end sim;
