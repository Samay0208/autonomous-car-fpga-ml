-- ============================================================
-- top.vhd  (Final Version - includes Gaussian Blur)
-- Complete 8-stage FPGA vision pipeline:
--
--   Stage 1: OV7670 pixel capture    (PCLK domain)
--   Stage 2: RGB565 ? Grayscale      (1 clock)
--   Stage 3: BRAM frame buffer       (19,200 bytes)
--   Stage 4: Gaussian blur           (3x3 kernel, noise removal)
--   Stage 5: Blurred frame buffer    (19,200 bytes)
--   Stage 6: Sobel edge detection    (pipelined, 3 stages)
--   Stage 7: HSV blob + lane detect  (parallel)
--   Stage 8: Sign classification     (1 clock)
--   Output:  UART packet ? RPi 5    (13 bytes per frame)
--
-- LED debug map:
--   LED 0    : Camera initialising (SCCB writes)
--   LED 1    : Camera ready
--   LED 2    : Frame capture active
--   LED 3    : Gaussian blur running
--   LED 4    : Sobel edge + blob running
--   LED 5    : Transmitting UART
--   LED 8-10 : Sign class (binary 0-5)
--   LED 12   : Lane detected this frame
--   LED 14-15: Dominant colour (01=red 10=yellow 11=green)
-- ============================================================
library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

entity top is
    port (
        clk_100  : in    std_logic;
        rst_btn  : in    std_logic;
        ov_pclk  : in    std_logic;
        ov_vsync : in    std_logic;
        ov_href  : in    std_logic;
        ov_d     : in    std_logic_vector(7 downto 0);
        sio_c    : out   std_logic;
        sio_d    : inout std_logic;
        xclk     : out   std_logic;
        uart_tx  : out   std_logic;
        uart_rx  : in    std_logic;
        led      : out   std_logic_vector(15 downto 0)
    );
end top;

architecture Behavioral of top is

    signal clk, rst : std_logic;
    signal xclk_cnt : integer range 0 to 1 := 0;
    signal xclk_r   : std_logic := '0';

    -- SCCB
    signal sccb_wr_en    : std_logic;
    signal sccb_reg_addr : std_logic_vector(7 downto 0);
    signal sccb_reg_data : std_logic_vector(7 downto 0);
    signal sccb_busy     : std_logic;
    signal sccb_done     : std_logic;
    signal config_done   : std_logic := '0';

    -- Camera capture
    signal pix_data   : std_logic_vector(15 downto 0);
    signal pix_valid  : std_logic;
    signal pix_x      : std_logic_vector(7 downto 0);
    signal pix_y      : std_logic_vector(6 downto 0);
    signal frame_done : std_logic;
    signal frame_cnt  : std_logic_vector(7 downto 0);

    -- Grayscale frame buffer (primary)
    signal buf_we     : std_logic;
    signal buf_addr_w : std_logic_vector(14 downto 0);
    signal buf_din    : std_logic_vector(7 downto 0);
    signal buf_addr_r : std_logic_vector(14 downto 0) := (others=>'0');
    signal buf_dout   : std_logic_vector(7 downto 0);
    signal write_done : std_logic;

    -- Gaussian blur
    signal gauss_start   : std_logic := '0';
    signal gauss_done    : std_logic;
    signal gauss_rd_addr : std_logic_vector(14 downto 0);
    signal gauss_wr_en   : std_logic;
    signal gauss_wr_addr : std_logic_vector(14 downto 0);
    signal gauss_wr_data : std_logic_vector(7 downto 0);

    -- Blurred frame buffer (secondary)
    signal blur_addr_r : std_logic_vector(14 downto 0) := (others=>'0');
    signal blur_dout   : std_logic_vector(7 downto 0);

    -- Sobel edge detector (reads from blurred buffer)
    signal sobel_start  : std_logic := '0';
    signal sobel_done   : std_logic;
    signal sobel_rd_addr: std_logic_vector(14 downto 0);
    signal edge_valid   : std_logic;
    signal edge_out     : std_logic;
    signal edge_x       : std_logic_vector(7 downto 0);
    signal edge_y       : std_logic_vector(6 downto 0);
    signal edge_mag     : std_logic_vector(7 downto 0);

    -- Buffer read mux: gaussian reads primary, sobel reads blurred
    -- gauss_rd_addr ? buf_addr_r (primary BRAM read)
    -- sobel_rd_addr ? blur_addr_r (blurred BRAM read)

    -- Blob detector (reads live pixels from camera)
    signal blob_start     : std_logic := '0';
    signal blob_rd_addr   : std_logic_vector(14 downto 0);
    signal red_area       : std_logic_vector(15 downto 0);
    signal yellow_area    : std_logic_vector(15 downto 0);
    signal green_area     : std_logic_vector(15 downto 0);
    signal red_cx         : std_logic_vector(7 downto 0);
    signal red_cy         : std_logic_vector(6 downto 0);
    signal dominant_color : std_logic_vector(1 downto 0);
    signal blob_done      : std_logic;

    -- Lane detector
    signal lane_start  : std_logic := '0';
    signal left_x      : std_logic_vector(7 downto 0);
    signal right_x     : std_logic_vector(7 downto 0);
    signal lane_valid  : std_logic;
    signal center_err  : signed(7 downto 0);

    -- Sign classifier
    signal sign_class      : std_logic_vector(2 downto 0);
    signal sign_confidence : std_logic_vector(7 downto 0);
    signal sign_valid      : std_logic;

    -- UART
    signal uart_data  : std_logic_vector(7 downto 0);
    signal uart_valid : std_logic;
    signal uart_ready : std_logic;
    signal rx_data    : std_logic_vector(7 downto 0);
    signal rx_valid   : std_logic;

    -- Top FSM
    type top_state_t is (
        INIT,          -- Camera SCCB config
        IDLE,          -- Between frames
        CAPTURE,       -- Start blob (parallel with capture)
        WAIT_FRAME,    -- Frame in primary BRAM
        GAUSSIAN,      -- Blur the frame
        WAIT_GAUSSIAN, -- Wait for blur complete
        RUN_SOBEL,     -- Edge detect on blurred frame
        WAIT_SOBEL,    -- Wait for edge + blob both done
        TRANSMIT,      -- Send UART packet
        WAIT_TX        -- Wait for TX complete
    );
    signal top_state : top_state_t := INIT;

    -- UART FSM (13-byte packet)
    type uart_st_t is (
        U_START, U_CLASS, U_CONF,
        U_RED_H, U_RED_L,
        U_YEL_H, U_YEL_L,
        U_GRN_H, U_GRN_L,
        U_LANE_L, U_LANE_R, U_STEER,
        U_END, U_DONE
    );
    signal uart_st : uart_st_t := U_DONE;

    signal sobel_done_latch : std_logic := '0';
    signal blob_done_latch  : std_logic := '0';

begin
    clk <= clk_100; rst <= rst_btn;

    -- XCLK: 25 MHz for OV7670
    process(clk) begin
        if rising_edge(clk) then
            if xclk_cnt=1 then xclk_cnt<=0; xclk_r<=not xclk_r;
            else xclk_cnt<=xclk_cnt+1; end if;
        end if;
    end process;
    xclk <= xclk_r;

    -- Primary BRAM read address: gaussian reads from it
    buf_addr_r <= gauss_rd_addr;

    -- Blurred BRAM read address: sobel reads from it
    blur_addr_r <= sobel_rd_addr;

    -- ?? Module Instantiations ?????????????????????????????????????????????

    u_sccb: entity work.sccb_master
        port map(clk=>clk, rst=>rst, wr_en=>sccb_wr_en,
                 reg_addr=>sccb_reg_addr, reg_data=>sccb_reg_data,
                 busy=>sccb_busy, done=>sccb_done,
                 sio_c=>sio_c, sio_d=>sio_d);

    u_config: entity work.ov7670_config
        port map(clk=>clk, rst=>rst, wr_en=>sccb_wr_en,
                 reg_addr=>sccb_reg_addr, reg_data=>sccb_reg_data,
                 sccb_busy=>sccb_busy, sccb_done=>sccb_done,
                 config_done=>config_done);

    u_capture: entity work.ov7670_capture
        port map(clk=>clk, rst=>rst, pclk=>ov_pclk, vsync=>ov_vsync,
                 href=>ov_href, cam_d=>ov_d,
                 pix_data=>pix_data, pix_valid=>pix_valid,
                 pix_x=>pix_x, pix_y=>pix_y,
                 frame_done=>frame_done, frame_count=>frame_cnt);

    u_writer: entity work.frame_writer
        port map(clk=>clk, rst=>rst, pix_data=>pix_data, pix_valid=>pix_valid,
                 pix_x=>pix_x, pix_y=>pix_y, frame_done=>frame_done,
                 buf_we=>buf_we, buf_addr=>buf_addr_w,
                 buf_din=>buf_din, write_done=>write_done);

    u_bram: entity work.frame_buffer
        port map(clk_a=>clk, we_a=>buf_we, addr_a=>buf_addr_w, din_a=>buf_din,
                 clk_b=>clk, addr_b=>buf_addr_r, dout_b=>buf_dout);

    u_gauss: entity work.gaussian_blur
        port map(clk=>clk, rst=>rst, start=>gauss_start, done=>gauss_done,
                 rd_addr=>gauss_rd_addr, rd_data=>buf_dout,
                 wr_en=>gauss_wr_en, wr_addr=>gauss_wr_addr,
                 wr_data=>gauss_wr_data);

    u_blurbuf: entity work.blurred_buffer
        port map(clk_a=>clk, we_a=>gauss_wr_en, addr_a=>gauss_wr_addr,
                 din_a=>gauss_wr_data,
                 clk_b=>clk, addr_b=>blur_addr_r, dout_b=>blur_dout);

    u_sobel: entity work.sobel_edge
        port map(clk=>clk, rst=>rst, start=>sobel_start,
                 rd_addr=>sobel_rd_addr, rd_data=>blur_dout,  -- reads BLURRED buffer
                 edge_valid=>edge_valid, edge_out=>edge_out,
                 edge_x=>edge_x, edge_y=>edge_y, edge_mag=>edge_mag,
                 done=>sobel_done);

    u_blob: entity work.hsv_blob_detector
        port map(clk=>clk, rst=>rst, start=>blob_start,
                 rd_addr=>blob_rd_addr, rd_data=>buf_dout,
                 pix_rgb=>pix_data, pix_rgb_valid=>pix_valid,
                 pix_rgb_x=>pix_x, pix_rgb_y=>pix_y,
                 red_area=>red_area, yellow_area=>yellow_area,
                 green_area=>green_area, red_cx=>red_cx, red_cy=>red_cy,
                 dominant_color=>dominant_color, done=>blob_done);

    u_lane: entity work.lane_detector
        port map(clk=>clk, rst=>rst, start=>lane_start,
                 edge_valid=>edge_valid, edge_out=>edge_out,
                 edge_x=>edge_x, edge_y=>edge_y,
                 left_x=>left_x, right_x=>right_x,
                 lane_valid=>lane_valid, center_err=>center_err);

    u_sign: entity work.sign_classifier
        port map(clk=>clk, rst=>rst, blob_done=>blob_done,
                 red_area=>red_area, yellow_area=>yellow_area,
                 green_area=>green_area, red_cx=>red_cx, red_cy=>red_cy,
                 sign_class=>sign_class, sign_confidence=>sign_confidence,
                 sign_valid=>sign_valid);

    u_uart_tx: entity work.uart_tx
        port map(clk=>clk, rst=>rst, tx_data=>uart_data,
                 tx_valid=>uart_valid, tx_ready=>uart_ready, tx_out=>uart_tx);

    u_uart_rx: entity work.uart_rx
        port map(clk=>clk, rst=>rst, rx_in=>uart_rx,
                 rx_data=>rx_data, rx_valid=>rx_valid);

    -- ?? Top FSM ???????????????????????????????????????????????????????????
    process(clk)
    begin
        if rising_edge(clk) then
            if rst='1' then
                top_state<=INIT; gauss_start<='0'; sobel_start<='0';
                blob_start<='0'; lane_start<='0'; uart_valid<='0';
                uart_st<=U_DONE; led<=(others=>'0');
                sobel_done_latch<='0'; blob_done_latch<='0';
            else
                gauss_start<='0'; sobel_start<='0';
                blob_start<='0'; lane_start<='0'; uart_valid<='0';

                if sobel_done='1' then sobel_done_latch<='1'; end if;
                if blob_done='1'  then blob_done_latch<='1';  end if;

                case top_state is

                    when INIT =>
                        led(0)<='1';
                        if config_done='1' then
                            led(0)<='0'; led(1)<='1'; top_state<=IDLE;
                        end if;

                    when IDLE =>
                        sobel_done_latch<='0'; blob_done_latch<='0';
                        top_state<=CAPTURE;

                    when CAPTURE =>
                        blob_start<='1'; -- run blob on live pixels
                        top_state<=WAIT_FRAME;

                    when WAIT_FRAME =>
                        led(2)<='1';
                        if write_done='1' then
                            led(2)<='0';
                            gauss_start<='1'; -- blur the completed frame
                            top_state<=WAIT_GAUSSIAN;
                        end if;

                    when GAUSSIAN =>
                        top_state<=WAIT_GAUSSIAN;

                    when WAIT_GAUSSIAN =>
                        led(3)<='1';
                        if gauss_done='1' then
                            led(3)<='0';
                            sobel_start<='1'; -- edge detect on blurred frame
                            lane_start<='1';
                            top_state<=WAIT_SOBEL;
                        end if;

                    when RUN_SOBEL =>
                        top_state<=WAIT_SOBEL;

                    when WAIT_SOBEL =>
                        led(4)<='1';
                        if sobel_done_latch='1' and blob_done_latch='1' then
                            led(4)<='0';
                            led(10 downto 8)  <= sign_class;
                            led(15 downto 14) <= dominant_color;
                            -- lane_valid was a pulse, cannot display on LED directly here reliably
                            top_state<=TRANSMIT; uart_st<=U_START;
                        end if;

                    when TRANSMIT =>
                        led(5)<='1';
                        if uart_ready='1' and uart_valid='0' then
                            case uart_st is
                                when U_START  => uart_data<=x"AA"; uart_valid<='1'; uart_st<=U_CLASS;
                                when U_CLASS  => uart_data<="00000"&sign_class; uart_valid<='1'; uart_st<=U_CONF;
                                when U_CONF   => uart_data<=sign_confidence; uart_valid<='1'; uart_st<=U_RED_H;
                                when U_RED_H  => uart_data<=red_area(15 downto 8); uart_valid<='1'; uart_st<=U_RED_L;
                                when U_RED_L  => uart_data<=red_area(7 downto 0); uart_valid<='1'; uart_st<=U_YEL_H;
                                when U_YEL_H  => uart_data<=yellow_area(15 downto 8); uart_valid<='1'; uart_st<=U_YEL_L;
                                when U_YEL_L  => uart_data<=yellow_area(7 downto 0); uart_valid<='1'; uart_st<=U_GRN_H;
                                when U_GRN_H  => uart_data<=green_area(15 downto 8); uart_valid<='1'; uart_st<=U_GRN_L;
                                when U_GRN_L  => uart_data<=green_area(7 downto 0); uart_valid<='1'; uart_st<=U_LANE_L;
                                when U_LANE_L => uart_data<=left_x; uart_valid<='1'; uart_st<=U_LANE_R;
                                when U_LANE_R => uart_data<=right_x; uart_valid<='1'; uart_st<=U_STEER;
                                when U_STEER  => uart_data<=std_logic_vector(center_err); uart_valid<='1'; uart_st<=U_END;
                                when U_END    => uart_data<=x"55"; uart_valid<='1'; uart_st<=U_DONE; top_state<=WAIT_TX;
                                when U_DONE   => top_state<=IDLE;
                            end case;
                        end if;

                    when WAIT_TX =>
                        led(5)<='0';
                        if uart_ready='1' then top_state<=IDLE; end if;

                    when others => top_state<=INIT;
                end case;
            end if;
        end if;
    end process;
end Behavioral;