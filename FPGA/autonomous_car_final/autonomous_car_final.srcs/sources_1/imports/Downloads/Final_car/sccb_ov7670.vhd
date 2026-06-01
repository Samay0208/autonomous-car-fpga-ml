-- ============================================================
-- sccb_master.vhd
-- SCCB (I2C-compatible) Master for OV7670 configuration
-- OV7670 write address: 0x42
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity sccb_master is
    generic (
        CLK_FREQ  : integer := 100_000_000;
        SCCB_FREQ : integer := 100_000
    );
    port (
        clk      : in    std_logic;
        rst      : in    std_logic;
        wr_en    : in    std_logic;
        reg_addr : in    std_logic_vector(7 downto 0);
        reg_data : in    std_logic_vector(7 downto 0);
        busy     : out   std_logic;
        done     : out   std_logic;
        sio_c    : out   std_logic;
        sio_d    : inout std_logic
    );
end sccb_master;

architecture Behavioral of sccb_master is
    constant HALF_PERIOD : integer := CLK_FREQ / (2 * SCCB_FREQ);
    constant DEV_ADDR    : std_logic_vector(7 downto 0) := x"42";
    type state_t is (IDLE, START, SEND_BYTE, ACK, STOP, DONE_ST);
    signal state     : state_t := IDLE;
    signal clk_cnt   : integer range 0 to HALF_PERIOD-1 := 0;
    signal phase     : std_logic := '0';
    signal bit_cnt   : integer range 0 to 7 := 7;
    signal shift_r   : std_logic_vector(7 downto 0);
    signal byte_idx  : integer range 0 to 2 := 0;
    signal sda_out   : std_logic := '1';
    signal sda_oe    : std_logic := '1';
    signal sio_c_r   : std_logic := '1';
    signal addr_r    : std_logic_vector(7 downto 0);
    signal data_r    : std_logic_vector(7 downto 0);
begin
    sio_d <= sda_out when sda_oe = '1' else 'Z';
    sio_c <= sio_c_r;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= IDLE; sio_c_r <= '1'; sda_out <= '1';
                sda_oe <= '1'; busy <= '0'; done <= '0';
                clk_cnt <= 0; phase <= '0';
            else
                done <= '0';
                if clk_cnt = HALF_PERIOD-1 then
                    clk_cnt <= 0; phase <= not phase;
                    case state is
                        when IDLE =>
                            sio_c_r <= '1'; sda_out <= '1'; sda_oe <= '1'; busy <= '0';
                            if wr_en = '1' then
                                addr_r <= reg_addr; data_r <= reg_data;
                                busy <= '1'; byte_idx <= 0;
                                shift_r <= DEV_ADDR; bit_cnt <= 7;
                                state <= START; phase <= '0';
                            end if;
                        when START =>
                            if phase = '0' then sio_c_r <= '1'; sda_out <= '1';
                            else sda_out <= '0'; state <= SEND_BYTE; phase <= '0'; end if;
                        when SEND_BYTE =>
                            sda_oe <= '1';
                            if phase = '0' then sio_c_r <= '0'; sda_out <= shift_r(bit_cnt);
                            else
                                sio_c_r <= '1';
                                if bit_cnt = 0 then state <= ACK; phase <= '0';
                                else bit_cnt <= bit_cnt - 1; end if;
                            end if;
                        when ACK =>
                            sda_oe <= '0';
                            if phase = '0' then sio_c_r <= '0';
                            else
                                sio_c_r <= '1';
                                byte_idx <= byte_idx + 1;
                                bit_cnt <= 7;
                                case byte_idx is
                                    when 0 => shift_r <= addr_r; state <= SEND_BYTE;
                                    when 1 => shift_r <= data_r; state <= SEND_BYTE;
                                    when others => state <= STOP;
                                end case;
                                phase <= '0';
                            end if;
                        when STOP =>
                            sda_oe <= '1';
                            if phase = '0' then sio_c_r <= '0'; sda_out <= '0';
                            else sio_c_r <= '1'; sda_out <= '1'; state <= DONE_ST; end if;
                        when DONE_ST =>
                            done <= '1'; busy <= '0'; state <= IDLE;
                        when others => state <= IDLE;
                    end case;
                else
                    clk_cnt <= clk_cnt + 1;
                end if;
            end if;
        end if;
    end process;
end Behavioral;


-- ============================================================
-- ov7670_config.vhd
-- Sequences all OV7670 register writes via SCCB
-- Configures: QQVGA 160x120, RGB565, ~15fps
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity ov7670_config is
    port (
        clk         : in  std_logic;
        rst         : in  std_logic;
        wr_en       : out std_logic;
        reg_addr    : out std_logic_vector(7 downto 0);
        reg_data    : out std_logic_vector(7 downto 0);
        sccb_busy   : in  std_logic;
        sccb_done   : in  std_logic;
        config_done : out std_logic
    );
end ov7670_config;

architecture Behavioral of ov7670_config is
    type reg_pair is record
        addr : std_logic_vector(7 downto 0);
        data : std_logic_vector(7 downto 0);
    end record;
    type reg_table_t is array(natural range <>) of reg_pair;

    constant REG_TABLE : reg_table_t := (
        (x"12", x"80"), -- Software reset (wait after this)
        (x"12", x"04"), -- COM7: RGB mode
        (x"40", x"D0"), -- COM15: RGB565 full range
        (x"8C", x"00"), -- RGB444: disable
        (x"11", x"01"), -- CLKRC: /2
        (x"6B", x"4A"), -- DBLV: PLL x4
        (x"0C", x"04"), -- COM3: scale enable
        (x"3E", x"19"), -- COM14: DCW + PCLK /2
        (x"72", x"22"), -- SCALING_DCWCTR: /4
        (x"73", x"F2"), -- SCALING_PCLK_DIV: /4
        (x"A2", x"02"), -- SCALING_PCLK_DELAY
        (x"17", x"16"), -- HSTART
        (x"18", x"04"), -- HSTOP
        (x"19", x"02"), -- VSTART
        (x"1A", x"7A"), -- VSTOP
        (x"32", x"80"), -- HREF
        (x"03", x"0A"), -- VREF
        (x"13", x"E7"), -- COM8: AGC+AWB+AEC
        (x"14", x"18"), -- COM9: max gain 4x
        (x"4F", x"B3"), -- Color matrix
        (x"50", x"B3"),
        (x"51", x"00"),
        (x"52", x"3D"),
        (x"53", x"A7"),
        (x"54", x"E4"),
        (x"58", x"9E"),
        (x"7A", x"20"), -- Gamma
        (x"7B", x"10"),
        (x"7C", x"1E"),
        (x"7D", x"35"),
        (x"7E", x"5A"),
        (x"7F", x"69"),
        (x"80", x"76"),
        (x"81", x"80"),
        (x"82", x"88"),
        (x"83", x"8F"),
        (x"84", x"96"),
        (x"85", x"A3"),
        (x"86", x"AF"),
        (x"87", x"C4"),
        (x"88", x"D7"),
        (x"89", x"E8"),
        (x"FF", x"FF")  -- End marker
    );

    signal reg_idx  : integer range 0 to REG_TABLE'length-1 := 0;
    signal delay_cnt: integer range 0 to 10_000_000 := 0;
    type fsm_t is (SEND_RESET, WAIT_RESET, WRITE_REG, WAIT_DONE, FINISHED);
    signal state    : fsm_t := SEND_RESET;
    signal wr_en_r  : std_logic := '0';
begin
    wr_en    <= wr_en_r;
    reg_addr <= REG_TABLE(reg_idx).addr;
    reg_data <= REG_TABLE(reg_idx).data;

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state <= SEND_RESET; reg_idx <= 0;
                delay_cnt <= 0; wr_en_r <= '0'; config_done <= '0';
            else
                case state is
                    when SEND_RESET =>
                        wr_en_r <= '1';
                        if sccb_busy = '1' then 
                            wr_en_r <= '0'; 
                            state <= WAIT_RESET; 
                        end if;
                    when WAIT_RESET =>
                        if delay_cnt = 10_000_000 then
                            delay_cnt <= 0; reg_idx <= 1; state <= WRITE_REG;
                        else delay_cnt <= delay_cnt + 1; end if;
                    when WRITE_REG =>
                        if REG_TABLE(reg_idx).addr = x"FF" then
                            state <= FINISHED; config_done <= '1';
                        else
                            wr_en_r <= '1';
                            if sccb_busy = '1' then
                                wr_en_r <= '0'; 
                                state <= WAIT_DONE;
                            end if;
                        end if;
                    when WAIT_DONE =>
                        if sccb_done = '1' then reg_idx <= reg_idx+1; state <= WRITE_REG; end if;
                    when FINISHED => config_done <= '1';
                    when others => state <= SEND_RESET;
                end case;
            end if;
        end if;
    end process;
end Behavioral;
