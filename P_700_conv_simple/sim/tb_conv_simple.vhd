-------------------------------------------------------------------------------
-- tb_conv_simple.vhd — Testbench para conv_simple
-------------------------------------------------------------------------------
-- Carga golden vectors, ejecuta convolucion, compara resultado.
--
-- FIX: un unico proceso (p_mem) maneja toda la memoria para evitar
-- conflictos de multi-driver en VHDL.
--
-- Memory layout:
--   0x0000: Input   192 bytes  (3 x 8 x 8)
--   0x0100: Weights 864 bytes  (32 x 3 x 3 x 3, OHWI)
--   0x0460: Bias    128 bytes  (32 x int32, little-endian)
--   0x0500: Output 2048 bytes  (32 x 8 x 8)
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;

entity tb_conv_simple is
end entity tb_conv_simple;

architecture sim of tb_conv_simple is

    constant CLK_PERIOD : time := 10 ns;

    constant ADDR_INPUT   : natural := 16#0000#;
    constant ADDR_WEIGHTS : natural := 16#0100#;
    constant ADDR_BIAS    : natural := 16#0460#;
    constant ADDR_OUTPUT  : natural := 16#0500#;
    constant N_OUTPUT     : natural := 2048;

    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';

    signal start       : std_logic := '0';
    signal done        : std_logic;
    signal busy        : std_logic;
    signal mem_rd_addr : unsigned(15 downto 0);
    signal mem_rd_en   : std_logic;
    signal mem_rd_data : std_logic_vector(7 downto 0) := (others => '0');
    signal mem_wr_addr : unsigned(15 downto 0);
    signal mem_wr_data : std_logic_vector(7 downto 0);
    signal mem_wr_en   : std_logic;
    signal dbg_state   : std_logic_vector(4 downto 0);
    signal dbg_oh, dbg_ow : unsigned(9 downto 0);

    -- Memory: shared variable para acceso desde multiples procesos
    type mem_t is array(0 to 8191) of std_logic_vector(7 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));

    -- Golden output
    type byte_array_t is array(natural range <>) of std_logic_vector(7 downto 0);
    shared variable golden_output : byte_array_t(0 to N_OUTPUT - 1) := (others => (others => '0'));

    -- Señal para indicar que la memoria esta cargada
    signal mem_loaded : std_logic := '0';

    function hex_to_slv4(c : character) return std_logic_vector is
    begin
        case c is
            when '0' => return "0000"; when '1' => return "0001";
            when '2' => return "0010"; when '3' => return "0011";
            when '4' => return "0100"; when '5' => return "0101";
            when '6' => return "0110"; when '7' => return "0111";
            when '8' => return "1000"; when '9' => return "1001";
            when 'a'|'A' => return "1010"; when 'b'|'B' => return "1011";
            when 'c'|'C' => return "1100"; when 'd'|'D' => return "1101";
            when 'e'|'E' => return "1110"; when 'f'|'F' => return "1111";
            when others => return "0000";
        end case;
    end function;

begin

    clk <= not clk after CLK_PERIOD / 2;

    u_dut : entity work.conv_simple
        port map (
            clk => clk, rst_n => rst_n, start => start,
            done => done, busy => busy,
            cfg_c_in    => to_unsigned(3, 10),
            cfg_c_out   => to_unsigned(32, 10),
            cfg_h_in    => to_unsigned(8, 10),
            cfg_w_in    => to_unsigned(8, 10),
            cfg_ksize   => to_unsigned(3, 4),
            cfg_stride  => to_unsigned(1, 4),
            cfg_pad     => to_unsigned(1, 4),
            cfg_x_zp    => to_signed(-128, 9),
            cfg_M0      => to_unsigned(656954014, 32),
            cfg_n_shift => to_unsigned(37, 6),
            cfg_y_zp    => to_signed(-17, 8),
            cfg_addr_input   => to_unsigned(ADDR_INPUT, 16),
            cfg_addr_weights => to_unsigned(ADDR_WEIGHTS, 16),
            cfg_addr_bias    => to_unsigned(ADDR_BIAS, 16),
            cfg_addr_output  => to_unsigned(ADDR_OUTPUT, 16),
            mem_rd_addr => mem_rd_addr, mem_rd_en => mem_rd_en,
            mem_rd_data => mem_rd_data,
            mem_wr_addr => mem_wr_addr, mem_wr_data => mem_wr_data,
            mem_wr_en => mem_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow
        );

    ---------------------------------------------------------------------------
    -- BRAM MODEL: read port (1-cycle latency) + write port
    -- Unico proceso que maneja memoria para evitar multi-driver
    ---------------------------------------------------------------------------
    p_mem : process(clk)
    begin
        if rising_edge(clk) then
            -- Write port (DUT writes outputs here)
            if mem_wr_en = '1' then
                mem(to_integer(mem_wr_addr)) := mem_wr_data;
            end if;
            -- Read port (1-cycle registered output)
            if mem_rd_en = '1' then
                mem_rd_data <= mem(to_integer(mem_rd_addr));
            end if;
        end if;
    end process;

    ---------------------------------------------------------------------------
    -- STIMULUS: load files, start conv, verify output
    ---------------------------------------------------------------------------
    p_stim : process
        file f_in  : text;
        file f_wt  : text;
        file f_bi  : text;
        file f_out : text;
        variable l     : line;
        variable h2    : string(1 to 2);
        variable h8    : string(1 to 8);
        variable bv    : std_logic_vector(7 downto 0);
        variable wv    : std_logic_vector(31 downto 0);
        variable idx   : natural;
        variable errors : natural := 0;
        variable exp, act : std_logic_vector(7 downto 0);
    begin
        report "=== Loading golden vectors ===" severity note;

        -- Input (hex bytes, one per line)
        file_open(f_in, "golden_mem/mini_input.mem", read_mode);
        idx := ADDR_INPUT;
        while not endfile(f_in) loop
            readline(f_in, l); read(l, h2);
            mem(idx) := hex_to_slv4(h2(1)) & hex_to_slv4(h2(2));
            idx := idx + 1;
        end loop;
        file_close(f_in);
        report "  Input: " & integer'image(idx - ADDR_INPUT) & " bytes" severity note;

        -- Weights (hex bytes, one per line)
        file_open(f_wt, "golden_mem/layer005_weights.mem", read_mode);
        idx := ADDR_WEIGHTS;
        while not endfile(f_wt) loop
            readline(f_wt, l); read(l, h2);
            mem(idx) := hex_to_slv4(h2(1)) & hex_to_slv4(h2(2));
            idx := idx + 1;
        end loop;
        file_close(f_wt);
        report "  Weights: " & integer'image(idx - ADDR_WEIGHTS) & " bytes" severity note;

        -- Bias (hex int32, one per line -> 4 bytes little-endian)
        file_open(f_bi, "golden_mem/layer005_bias.mem", read_mode);
        idx := ADDR_BIAS;
        while not endfile(f_bi) loop
            readline(f_bi, l); read(l, h8);
            wv := hex_to_slv4(h8(1)) & hex_to_slv4(h8(2))
                & hex_to_slv4(h8(3)) & hex_to_slv4(h8(4))
                & hex_to_slv4(h8(5)) & hex_to_slv4(h8(6))
                & hex_to_slv4(h8(7)) & hex_to_slv4(h8(8));
            mem(idx + 0) := wv(7 downto 0);    -- byte 0 (LSB)
            mem(idx + 1) := wv(15 downto 8);
            mem(idx + 2) := wv(23 downto 16);
            mem(idx + 3) := wv(31 downto 24);  -- byte 3 (MSB)
            idx := idx + 4;
        end loop;
        file_close(f_bi);
        report "  Bias: " & integer'image((idx - ADDR_BIAS)/4) & " values" severity note;

        -- Golden output
        file_open(f_out, "golden_mem/mini_output.mem", read_mode);
        idx := 0;
        while not endfile(f_out) and idx < N_OUTPUT loop
            readline(f_out, l); read(l, h2);
            golden_output(idx) := hex_to_slv4(h2(1)) & hex_to_slv4(h2(2));
            idx := idx + 1;
        end loop;
        file_close(f_out);
        report "  Golden output: " & integer'image(idx) & " bytes" severity note;

        mem_loaded <= '1';

        -- Reset
        rst_n <= '0';
        wait for CLK_PERIOD * 5;
        rst_n <= '1';
        wait for CLK_PERIOD * 2;

        -- Start
        report "=== Starting convolution ===" severity note;
        start <= '1';
        wait for CLK_PERIOD;
        start <= '0';

        -- Wait for done
        wait until done = '1' for 500 ms;
        if done /= '1' then
            report "ERROR: Timeout" severity failure;
        end if;

        report "=== Convolution done, verifying ===" severity note;
        wait for CLK_PERIOD * 5;

        -- Verify
        for i in 0 to N_OUTPUT - 1 loop
            exp := golden_output(i);
            act := mem(ADDR_OUTPUT + i);
            if act /= exp then
                errors := errors + 1;
                if errors <= 20 then
                    report "MISMATCH byte " & integer'image(i)
                         & ": exp=" & integer'image(to_integer(signed(exp)))
                         & " got=" & integer'image(to_integer(signed(act)))
                         severity warning;
                end if;
            end if;
        end loop;

        if errors = 0 then
            report "========================================" severity note;
            report "  PASS: All " & integer'image(N_OUTPUT) & " bytes match!" severity note;
            report "========================================" severity note;
        else
            report "========================================" severity note;
            report "  FAIL: " & integer'image(errors) & " / " & integer'image(N_OUTPUT) severity error;
            report "========================================" severity note;
        end if;

        wait for CLK_PERIOD * 10;
        assert false report "Simulation complete" severity failure;
    end process;

end architecture sim;
