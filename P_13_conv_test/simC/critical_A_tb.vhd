-------------------------------------------------------------------------------
-- critical_A_tb.vhd
--
-- CRITICAL CONFIG A: stride-2 asymmetric pad (YOLOv4-style first conv).
--
--   c_in=3, c_out=32, h_in=w_in=8, kernel 3x3, stride=2
--   pad_top=1, pad_bottom=0, pad_left=1, pad_right=0
--   x_zp=-128, w_zp=0, M0=656954014, n_shift=37, y_zp=-17
--   ic_tile_size = c_in = 3       (single ic_tile, full)
--
--   Weights (OHWI, simple hand-verifiable pattern):
--     filter 0 : ALL ONES  (sum-of-ic-window detector)
--     filter 1 : center only (kh=1,kw=1) for all 3 channels = identity per
--                center pixel
--     filter 2..31 : zero  -> output is just y_zp (=-17)
--   Bias: oc=0 -> 1000, others 0.
--
-- Goldens (from compute_golden.py):
--   oc=0 (16 pixels): -6 -2 -1 0 -3 1 3 5 1 7 4 5 -2 4 2 1
--   oc=1            : -15 -15 -15 -15 -15 -16 -16 -16 -15 -14 -15 -15 -15 -15 -15 -16
--   oc=2..31        : -17 (all)
--   oc=0 raw acc first pixel: 2302
--
-- Output: trace.csv with full debug signal dump per cycle while busy.
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;

entity critical_A_tb is
end;

architecture bench of critical_A_tb is
    constant CLK_PERIOD : time := 10 ns;

    signal clk           : std_logic := '0';
    signal rst_n         : std_logic := '0';
    signal cfg_c_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_c_out     : unsigned(9 downto 0) := (others => '0');
    signal cfg_h_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_w_in      : unsigned(9 downto 0) := (others => '0');
    signal cfg_ksize     : unsigned(1 downto 0) := (others => '0');
    signal cfg_stride    : std_logic := '0';
    signal cfg_pad_top     : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_bottom  : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_left    : unsigned(1 downto 0) := (others => '0');
    signal cfg_pad_right   : unsigned(1 downto 0) := (others => '0');
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

    signal dbg_state    : integer range 0 to 63;
    signal dbg_oh, dbg_ow, dbg_kh, dbg_kw, dbg_ic : unsigned(9 downto 0);
    signal dbg_oc_tile_base, dbg_ic_tile_base : unsigned(9 downto 0);
    signal dbg_w_base   : unsigned(19 downto 0);
    signal dbg_mac_a    : signed(8 downto 0);
    signal dbg_mac_b    : weight_array_t;
    signal dbg_mac_bi   : bias_array_t;
    signal dbg_mac_acc  : acc_array_t;
    signal dbg_mac_vi, dbg_mac_clr, dbg_mac_lb, dbg_pad : std_logic;
    signal dbg_act_addr : unsigned(24 downto 0);

    -- DDR map (8 KB scratch)
    constant ADDR_INPUT   : natural := 16#0000#;  -- c_in*h*w = 192 bytes
    constant ADDR_WEIGHTS : natural := 16#0200#;  -- 32*3*3*3 = 864 bytes
    constant ADDR_BIAS    : natural := 16#0600#;  -- 128 bytes (32 * int32)
    constant ADDR_OUTPUT  : natural := 16#0800#;  -- 32*4*4 = 512 bytes
    constant DDR_BYTES    : natural := 16#1000#;

    signal sim_done  : std_logic := '0';
    signal cycle_cnt : integer := 0;

begin

    clk <= not clk after CLK_PERIOD / 2 when sim_done = '0';

    p_cnt : process(clk)
    begin
        if rising_edge(clk) then
            cycle_cnt <= cycle_cnt + 1;
        end if;
    end process;

    uut : entity work.conv_engine_v3
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride,
            cfg_pad_top => cfg_pad_top, cfg_pad_bottom => cfg_pad_bottom,
            cfg_pad_left => cfg_pad_left, cfg_pad_right => cfg_pad_right,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data,
            ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data,
            ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_oc_tile_base => dbg_oc_tile_base, dbg_ic_tile_base => dbg_ic_tile_base,
            dbg_w_base => dbg_w_base,
            dbg_mac_a => dbg_mac_a, dbg_mac_b => dbg_mac_b, dbg_mac_bi => dbg_mac_bi,
            dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr, dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr
        );

    ---------------------------------------------------------------------------
    -- CSV logger -- one row per cycle while busy.
    -- Logs full diagnostic state including internal WL_* / wb_* / wload_*.
    ---------------------------------------------------------------------------
    p_csv : process(clk)
        file csv_file    : text;
        variable csv_line    : line;
        variable file_opened : boolean := false;

        alias a_wl_i        is << signal .critical_A_tb.uut.wl_i        : unsigned(5 downto 0) >>;
        alias a_wl_kh       is << signal .critical_A_tb.uut.wl_kh       : unsigned(9 downto 0) >>;
        alias a_wl_kw       is << signal .critical_A_tb.uut.wl_kw       : unsigned(9 downto 0) >>;
        alias a_wl_j        is << signal .critical_A_tb.uut.wl_j        : unsigned(9 downto 0) >>;
        alias a_wl_buf_addr is << signal .critical_A_tb.uut.wl_buf_addr : unsigned(19 downto 0) >>;
        alias a_wl_ddr_addr is << signal .critical_A_tb.uut.wl_ddr_addr : unsigned(24 downto 0) >>;
        alias a_wb_we       is << signal .critical_A_tb.uut.wb_we       : std_logic >>;
        alias a_wb_addr     is << signal .critical_A_tb.uut.wb_addr     : unsigned(14 downto 0) >>;
        alias a_wb_din      is << signal .critical_A_tb.uut.wb_din      : std_logic_vector(7 downto 0) >>;
        alias a_wb_dout     is << signal .critical_A_tb.uut.wb_dout     : signed(7 downto 0) >>;
        alias a_wload_cnt   is << signal .critical_A_tb.uut.wload_cnt   : unsigned(5 downto 0) >>;
        alias a_wload_addr  is << signal .critical_A_tb.uut.wload_addr_r: unsigned(19 downto 0) >>;
        alias a_tile_stride is << signal .critical_A_tb.uut.tile_filter_stride : unsigned(19 downto 0) >>;
        alias a_ic_limit    is << signal .critical_A_tb.uut.ic_in_tile_limit    : unsigned(9 downto 0) >>;
    begin
        if rising_edge(clk) then
            if busy = '1' or done = '1' then
                if not file_opened then
                    file_open(csv_file, "trace_A.csv", write_mode);
                    write(csv_line, string'(
                      "cycle,time_ns,state,oc_tile_base,ic_tile_base,ic_in_tile_limit,tile_filter_stride,"
                    & "wl_i,wl_kh,wl_kw,wl_j,wl_buf_addr,wl_ddr_addr,"
                    & "ddr_rd_en,ddr_rd_addr,ddr_rd_data,"
                    & "wb_we,wb_addr,wb_din,wb_dout,"
                    & "oh,ow,kh,kw,ic,w_base_idx,wload_cnt,wload_addr,"
                    & "mac_a,mac_b_0,mac_b_1,mac_b_2,mac_b_3,mac_b_4,"
                    & "mac_acc_0,mac_acc_1,mac_acc_2,mac_acc_3,mac_acc_4,"
                    & "mac_vi,mac_clr,mac_lb,pad,act_addr,"
                    & "ddr_wr_en,ddr_wr_addr,ddr_wr_data"));
                    writeline(csv_file, csv_line);
                    file_opened := true;
                end if;

                write(csv_line, integer'image(cycle_cnt));                                   write(csv_line, string'(","));
                write(csv_line, integer'image(now / 1 ns));                                  write(csv_line, string'(","));
                write(csv_line, integer'image(dbg_state));                                   write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oc_tile_base)));                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic_tile_base)));                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_ic_limit)));                      write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_tile_stride)));                   write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_i)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_kh)));                         write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_kw)));                         write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_j)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_buf_addr)));                   write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wl_ddr_addr)));                   write(csv_line, string'(","));
                if ddr_rd_en = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_rd_addr)));                     write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(ddr_rd_data))));             write(csv_line, string'(","));
                if a_wb_we = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wb_addr)));                       write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(a_wb_din))));                write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wb_dout)));                       write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_oh)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ow)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kh)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_kw)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_ic)));                          write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_w_base)));                      write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wload_cnt)));                     write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(a_wload_addr)));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_a)));                       write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(0))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(1))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(2))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(3))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_b(4))));                    write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(0))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(1))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(2))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(3))));                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_mac_acc(4))));                  write(csv_line, string'(","));
                if dbg_mac_vi = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                if dbg_mac_clr = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                if dbg_mac_lb = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                if dbg_pad = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(dbg_act_addr)));                    write(csv_line, string'(","));
                if ddr_wr_en = '1' then write(csv_line, string'("1"));
                else write(csv_line, string'("0")); end if;                                  write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(ddr_wr_addr)));                     write(csv_line, string'(","));
                write(csv_line, integer'image(to_integer(signed(ddr_wr_data))));
                writeline(csv_file, csv_line);

                if done = '1' then
                    file_close(csv_file);
                end if;
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- Stimulus + DDR model (4 KB BRAM scratch)
    ---------------------------------------------------------------------------
    p_main : process
        type ddr_t is array(0 to DDR_BYTES-1) of std_logic_vector(7 downto 0);
        variable ddr : ddr_t := (others => (others => '0'));

        procedure ddr_w8(addr : natural; val : integer) is
        begin
            ddr(addr) := std_logic_vector(to_signed(val, 8));
        end procedure;

        -- Expected outputs (16 pixels each, in pixel order oh*4+ow)
        type pix16_t is array(0 to 15) of integer;
        constant EXP_OC0 : pix16_t :=
            (-6, -2, -1, 0, -3, 1, 3, 5, 1, 7, 4, 5, -2, 4, 2, 1);
        constant EXP_OC1 : pix16_t :=
            (-15, -15, -15, -15, -15, -16, -16, -16,
             -15, -14, -15, -15, -15, -15, -15, -16);

        constant C_IN  : natural := 3;
        constant H_IN  : natural := 8;
        constant W_IN  : natural := 8;
        constant C_OUT : natural := 32;
        constant K     : natural := 3;
        constant H_OUT : natural := 4;
        constant W_OUT : natural := 4;

        variable errors  : integer := 0;
        variable got     : integer;
        variable exp     : integer;
        variable timeout : integer;
        variable v_idx   : integer;
        variable v_xval  : integer;
    begin
        report "==============================================" severity note;
        report "critical_A_tb : stride-2 asym pad (YOLOv4)"     severity note;
        report "  c_in=3 c_out=32 8x8 k=3 s=2 pad=[1,0,1,0]"    severity note;
        report "==============================================" severity note;

        -- Inputs: x[ic][ih][iw] in CHW layout (DDR address = ic*hw + ih*w + iw)
        v_idx := 0;
        for ic in 0 to C_IN-1 loop
            for ih in 0 to H_IN-1 loop
                for iw in 0 to W_IN-1 loop
                    v_xval := ((v_idx * 7 + 13) mod 256) - 128;
                    ddr_w8(ADDR_INPUT + ic*H_IN*W_IN + ih*W_IN + iw, v_xval);
                    v_idx := v_idx + 1;
                end loop;
            end loop;
        end loop;

        -- Weights OHWI: filter[oc] occupies kh*kw*c_in = 27 bytes
        --   addr offset = oc*27 + kh*9 + kw*3 + ic
        for oc in 0 to C_OUT-1 loop
            for kh_i in 0 to K-1 loop
                for kw_i in 0 to K-1 loop
                    for ic in 0 to C_IN-1 loop
                        if oc = 0 then
                            ddr_w8(ADDR_WEIGHTS + oc*27 + kh_i*9 + kw_i*3 + ic, 1);
                        elsif oc = 1 and kh_i = 1 and kw_i = 1 then
                            ddr_w8(ADDR_WEIGHTS + oc*27 + kh_i*9 + kw_i*3 + ic, 1);
                        else
                            ddr_w8(ADDR_WEIGHTS + oc*27 + kh_i*9 + kw_i*3 + ic, 0);
                        end if;
                    end loop;
                end loop;
            end loop;
        end loop;

        -- Bias: oc=0 -> 1000, others 0. int32 little-endian.
        ddr_w8(ADDR_BIAS + 0,  16#E8#);
        ddr_w8(ADDR_BIAS + 1,  16#03#);
        ddr_w8(ADDR_BIAS + 2,  16#00#);
        ddr_w8(ADDR_BIAS + 3,  16#00#);

        rst_n <= '0';
        for i in 0 to 9 loop wait until rising_edge(clk); end loop;
        rst_n <= '1';
        wait until rising_edge(clk);
        wait until rising_edge(clk);

        cfg_c_in         <= to_unsigned( 3, 10);
        cfg_c_out        <= to_unsigned(32, 10);
        cfg_h_in         <= to_unsigned( 8, 10);
        cfg_w_in         <= to_unsigned( 8, 10);
        cfg_ksize        <= "10";                          -- 3x3
        cfg_stride       <= '1';                           -- stride 2
        cfg_pad_top      <= "01";
        cfg_pad_bottom   <= "00";
        cfg_pad_left     <= "01";
        cfg_pad_right    <= "00";
        cfg_x_zp         <= to_signed(-128, 9);
        cfg_w_zp         <= to_signed(0, 8);
        cfg_M0           <= to_unsigned(656954014, 32);
        cfg_n_shift      <= to_unsigned(37, 6);
        cfg_y_zp         <= to_signed(-17, 8);
        cfg_addr_input   <= to_unsigned(ADDR_INPUT,   25);
        cfg_addr_weights <= to_unsigned(ADDR_WEIGHTS, 25);
        cfg_addr_bias    <= to_unsigned(ADDR_BIAS,    25);
        cfg_addr_output  <= to_unsigned(ADDR_OUTPUT,  25);
        cfg_ic_tile_size <= to_unsigned(3, 10);            -- single full tile

        wait until rising_edge(clk);
        wait until rising_edge(clk);

        report "STARTING conv_engine_v3 (config A)" severity note;
        start <= '1';
        wait until rising_edge(clk);
        start <= '0';

        timeout := 0;
        while done /= '1' and timeout < 500000 loop
            wait until rising_edge(clk);
            timeout := timeout + 1;
            if ddr_rd_en = '1' then
                ddr_rd_data <= ddr(to_integer(ddr_rd_addr(11 downto 0)));
            end if;
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        if timeout >= 500000 then
            report "TIMEOUT waiting for done" severity failure;
        end if;

        report "DONE after " & integer'image(timeout) & " cycles" severity note;

        for i in 0 to 29 loop
            wait until rising_edge(clk);
            if ddr_wr_en = '1' then
                ddr(to_integer(ddr_wr_addr(11 downto 0))) := ddr_wr_data;
            end if;
        end loop;

        -- Output layout is CHW (channel-major): out[oc][oh][ow] is at
        -- ADDR_OUTPUT + oc*hw_out + oh*w_out + ow  (channels are hw_out apart).
        report "Verifying outputs (CHW layout)..." severity note;
        for oh in 0 to H_OUT-1 loop
            for ow in 0 to W_OUT-1 loop
                for oc in 0 to C_OUT-1 loop
                    got := to_integer(signed(ddr(ADDR_OUTPUT + oc*H_OUT*W_OUT + oh*W_OUT + ow)));
                    if oc = 0 then
                        exp := EXP_OC0(oh*W_OUT + ow);
                    elsif oc = 1 then
                        exp := EXP_OC1(oh*W_OUT + ow);
                    else
                        exp := -17;
                    end if;
                    if got /= exp then
                        errors := errors + 1;
                        if errors < 20 then
                            report "MISMATCH oh=" & integer'image(oh)
                                 & " ow=" & integer'image(ow)
                                 & " oc=" & integer'image(oc)
                                 & " got=" & integer'image(got)
                                 & " exp=" & integer'image(exp) severity error;
                        end if;
                    end if;
                end loop;
            end loop;
        end loop;

        report "==============================================" severity note;
        if errors = 0 then
            report "critical_A_tb : ALL PASSED (512 bytes match)" severity note;
        else
            report "critical_A_tb : FAIL, " & integer'image(errors) & " mismatches" severity note;
        end if;
        report "==============================================" severity note;

        sim_done <= '1';
        wait;
    end process;

end;
