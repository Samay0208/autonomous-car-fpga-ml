-- =============================================================================
-- ov7670_config.vhd
-- OV7670 Register Configuration Sequencer
-- Sends all required register writes via SCCB at startup
-- Configures: QQVGA (160x120), RGB565, ~30fps
-- =============================================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ov7670_config is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        -- To SCCB master
        wr_en     : out std_logic;
        reg_addr  : out std_logic_vector(7 downto 0);
        reg_data  : out std_logic_vector(7 downto 0);
        sccb_busy : in  std_logic;
        sccb_done : in  std_logic;
        -- Status
        config_done : out std_logic
    );
end ov7670_config;

architecture Behavioral of ov7670_config is

    -- Register table: (address, data) pairs
    -- 0xFF = end marker
    type reg_pair is record
        addr : std_logic_vector(7 downto 0);
        data : std_logic_vector(7 downto 0);
    end record;

    type reg_table_t is array (natural range <>) of reg_pair;

    -- OV7670 register configuration for QQVGA RGB565
    constant REG_TABLE : reg_table_t := (
        -- Software reset — wait after this
        (x"12", x"80"),   -- COM7: reset

        -- Clock settings (30fps at XCLK=24MHz)
        (x"11", x"01"),   -- CLKRC: prescaler /2
        (x"6B", x"4A"),   -- DBLV: PLL x4

        -- Output format: RGB565
        (x"12", x"04"),   -- COM7: RGB mode
        (x"40", x"D0"),   -- COM15: RGB565 full range
        (x"8C", x"00"),   -- RGB444: disable

        -- QQVGA (160x120) output size
        (x"0C", x"04"),   -- COM3: scale enable
        (x"3E", x"19"),   -- COM14: DCW enable, PCLK divider /2
        (x"72", x"22"),   -- SCALING_DCWCTR: downsample by 4
        (x"73", x"F2"),   -- SCALING_PCLK_DIV: /4
        (x"A2", x"02"),   -- SCALING_PCLK_DELAY

        -- Window size for QQVGA
        (x"17", x"16"),   -- HSTART
        (x"18", x"04"),   -- HSTOP
        (x"19", x"02"),   -- VSTART
        (x"1A", x"7A"),   -- VSTOP
        (x"32", x"80"),   -- HREF
        (x"03", x"0A"),   -- VREF

        -- Image quality
        (x"13", x"E7"),   -- COM8: AGC, AWB, AEC enable
        (x"01", x"40"),   -- GAIN
        (x"0D", x"40"),   -- COM4
        (x"14", x"18"),   -- COM9: max gain 4x
        (x"4F", x"B3"),   -- MTX1 (color matrix)
        (x"50", x"B3"),   -- MTX2
        (x"51", x"00"),   -- MTX3
        (x"52", x"3D"),   -- MTX4
        (x"53", x"A7"),   -- MTX5
        (x"54", x"E4"),   -- MTX6
        (x"58", x"9E"),   -- MTXS

        -- Gamma
        (x"7A", x"20"),   -- SLOP
        (x"7B", x"10"),   -- GAM1
        (x"7C", x"1E"),   -- GAM2
        (x"7D", x"35"),   -- GAM3
        (x"7E", x"5A"),   -- GAM4
        (x"7F", x"69"),   -- GAM5
        (x"80", x"76"),   -- GAM6
        (x"81", x"80"),   -- GAM7
        (x"82", x"88"),   -- GAM8
        (x"83", x"8F"),   -- GAM9
        (x"84", x"96"),   -- GAM10
        (x"85", x"A3"),   -- GAM11
        (x"86", x"AF"),   -- GAM12
        (x"87", x"C4"),   -- GAM13
        (x"88", x"D7"),   -- GAM14
        (x"89", x"E8"),   -- GAM15

        -- Denoise and edge enhancement
        (x"B0", x"84"),   -- ABLC1
        (x"B1", x"0C"),
        (x"B2", x"0E"),
        (x"B3", x"82"),

        -- AWB
        (x"43", x"14"),
        (x"44", x"F0"),
        (x"45", x"45"),
        (x"46", x"61"),
        (x"47", x"51"),
        (x"48", x"79"),
        (x"59", x"88"),
        (x"5A", x"88"),
        (x"5B", x"44"),
        (x"5C", x"67"),
        (x"5D", x"49"),
        (x"5E", x"0E"),
        (x"6C", x"0A"),
        (x"6D", x"55"),
        (x"6E", x"11"),
        (x"6F", x"9F"),
        (x"6A", x"40"),

        -- End marker
        (x"FF", x"FF")
    );

    signal reg_idx    : integer range 0 to REG_TABLE'length - 1 := 0;
    signal delay_cnt  : integer range 0 to 1_000_000 := 0; -- delay after reset

    type fsm_t is (WAIT_RESET, DELAY, WRITE_REG, WAIT_DONE, FINISHED);
    signal state : fsm_t := WAIT_RESET;

    signal wr_en_r : std_logic := '0';

begin

    wr_en    <= wr_en_r;
    reg_addr <= REG_TABLE(reg_idx).addr;
    reg_data <= REG_TABLE(reg_idx).data;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state       <= WAIT_RESET;
                reg_idx     <= 0;
                delay_cnt   <= 0;
                wr_en_r     <= '0';
                config_done <= '0';
            else
                wr_en_r <= '0'; -- Default

                case state is

                    when WAIT_RESET =>
                        -- Send software reset first (index 0)
                        if sccb_busy = '0' then
                            wr_en_r <= '1';
                            state   <= DELAY;
                        end if;

                    -- Wait 100ms after reset (10,000,000 cycles @ 100MHz)
                    when DELAY =>
                        if delay_cnt = 10_000_000 then
                            delay_cnt <= 0;
                            reg_idx   <= 1; -- Skip reset reg, start from index 1
                            state     <= WRITE_REG;
                        else
                            delay_cnt <= delay_cnt + 1;
                        end if;

                    when WRITE_REG =>
                        if REG_TABLE(reg_idx).addr = x"FF" then
                            state       <= FINISHED;
                            config_done <= '1';
                        elsif sccb_busy = '0' then
                            wr_en_r <= '1';
                            state   <= WAIT_DONE;
                        end if;

                    when WAIT_DONE =>
                        if sccb_done = '1' then
                            reg_idx <= reg_idx + 1;
                            state   <= WRITE_REG;
                        end if;

                    when FINISHED =>
                        config_done <= '1';

                    when others =>
                        state <= WAIT_RESET;

                end case;
            end if;
        end if;
    end process;

end Behavioral;
