library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

-- TB minimal para replicar el bug de padding en HW
entity conv_engine_pad_tb is
end;

architecture bench of conv_engine_pad_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal cfg_c_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out     : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize     : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride    : std_logic := '0';
    signal cfg_pad       : std_logic := '0';
    signal cfg_x_zp      : signed(8 downto 0) := (others => '0');
    signal cfg_w_zp      : signed(7 downto 0) := (others => '0');
    signal cfg_M0        : unsigned(31 downto 0) := (others => '0');
    signal cfg_n_shift   : unsigned(5 downto 0) := (others => '0');
    signal cfg_y_zp      : signed(7 downto 0) := (others => '0');
    signal cfg_addr_input   : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_weights : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_bias    : unsigned(24 downto 0) := (others => '0');
    signal cfg_addr_output  : unsigned(24 downto 0) := (others => '0');
    signal cfg_ic_tile_size : unsigned(9 downto 0) := (others => '0');
    signal start         : std_logic := '0';
    signal done          : std_logic;
    signal busy          : std_logic;
    signal ddr_rd_addr   : unsigned(24 downto 0);
    signal ddr_rd_data   : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en     : std_logic;
    signal ddr_wr_addr   : unsigned(24 downto 0);
    signal ddr_wr_data   : std_logic_vector(7 downto 0);
    signal ddr_wr_en     : std_logic;
    constant ADDR_INPUT   : natural := 16#000#;
    constant ADDR_WEIGHTS : natural := 16#100#;
    constant ADDR_BIAS    : natural := 16#200#;
    constant ADDR_OUTPUT  : natural := 16#300#;
begin
    clk <= not clk after CLK_PERIOD / 2;
    uut : entity work.conv_engine_v2
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride, cfg_pad => cfg_pad,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data,
            ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data,
            ddr_wr_en => ddr_wr_en
        );

    p_main : process
        type ddr_t is array(0 to 4095) of std_logic_vector(7 downto 0);
        variable ddr : ddr_t := (others => (others => '0'));

        procedure ddr_w8(addr : natural; val : integer) is
        begin
            ddr(addr) := std_logic_vector(to_signed(val, 8));
        end procedure;

        procedure ddr_w32(addr : natural; val : integer) is
            variable v : std_logic_vector(31 downto 0);
        begin
            v := std_logic_vector(to_signed(val, 32));
            ddr(addr + 0) := v( 7 downto  0);
            ddr(addr + 1) := v(15 downto  8);
            ddr(addr + 2) := v(23 downto 16);
            ddr(addr + 3) := v(31 downto 24);
        end procedure;

        variable timeout : integer;
        variable got_val : integer;

    begin
        report "======= TEST: 3x3 conv, pad=1, center-only weight =======" severity note;

        -- Input 3x3: {1,2,3, 4,5,6, 7,8,9}
        ddr_w8(ADDR_INPUT + 0, 1);
        ddr_w8(ADDR_INPUT + 1, 2);
        ddr_w8(ADDR_INPUT + 2, 3);
        ddr_w8(ADDR_INPUT + 3, 4);
        ddr_w8(ADDR_INPUT + 4, 5);
        ddr_w8(ADDR_INPUT + 5, 6);
        ddr_w8(ADDR_INPUT + 6, 7);
        ddr_w8(ADDR_INPUT + 7, 8);
        ddr_w8(ADDR_INPUT + 8, 9);

        -- Weight 3x3: center-only {0,0,0, 0,1,0, 0,0,0}
        ddr_w8(ADDR_WEIGHTS + 0, 0);
        ddr_w8(ADDR_WEIGHTS + 1, 0);
        ddr_w8(ADDR_WEIGHTS + 2, 0);
        ddr_w8(ADDR_WEIGHTS + 3, 0);
        ddr_w8(ADDR_WEIGHTS + 4, 1);
        ddr_w8(ADDR_WEIGHTS + 5, 0);
        ddr_w8(ADDR_WEIGHTS + 6, 0);
        ddr_w8(ADDR_WEIGHTS + 7, 0);
        ddr_w8(ADDR_WEIGHTS + 8, 0);

        -- Bias: 1000
        ddr_w32(ADDR_BIAS + 0, 1000);

        report "DDR loaded" severity note;

        -- Reset
        rst_n <= '0';
        for i in 0 to 9 loop
            wait until rising_edge(clk);
        end loop;
        rst_n <= '1';
        wait until rising_edge(clk);

        -- Configure
        cfg_c_in        <= to_unsigned(1, 10);
        cfg_c_out       <= to_unsigned(1, 10);
        cfg_h_in        <= to_unsigned(3, 10);
        cfg_w_in        <= to_unsigned(3, 10);
        cfg_ksize       <= "10";
        cfg_stride      <= '0';
        cfg_pad         <= '1';
        cfg_x_zp        <= to_signed(-128, 9);
        cfg_w_zp        <= to_signed(0, 8);
        cfg_M0          <= to_unsigned(656954014, 32);
        cfg_n_shift     <= to_unsigned(37, 6);
        cfg_y_zp        <= to_signed(-17, 8);
        cfg_addr_input  <= to_unsigned(ADDR_INPUT, 25);
        cfg_addr_weights<= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias   <= to_unsigned(ADDR_BIAS, 25);
        cfg_addr_output <= to_unsigned(ADDR_OUTPUT, 25);
        cfg_ic_tile_size <= to_unsigned(1, 10);

        wait until rising_edge(clk);

        report "STARTING simulation..." severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        timeout := 0;
        while done /= '1' and timeout < 100000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(11 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 100000 then
            report "TIMEOUT" severity failure;
        end if;

        report "DONE at cycle " & integer'image(timeout) severity note;


        -- Wait for final writes
        for i in 0 to 20 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -- Output 5x5 results
        report "===== OUTPUT RESULTS (5x5 with padding) =====" severity note;
        
        for row in 0 to 4 loop
            for col in 0 to 4 loop
                got_val := to_integer(signed(ddr(ADDR_OUTPUT + row * 5 + col)));
                report "out[" & integer'image(row) & "][" & integer'image(col) & 
                       "] = " & integer'image(got_val) severity note;
            end loop;
        end loop;

        report "============ TEST COMPLETE ============" severity note;

        wait;
    end process;

end bench;
