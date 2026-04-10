library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

-- mac_test_stream: Wrapper AXI-Stream para testar mac_array via DMA
--
-- PROTOCOLO DE ENTRADA (s_axis, 32 bits):
--   32 words: bias[0..31] (int32)
--   27 × 9 words: a_in + 8 words de pesos packed
--
-- PROTOCOLO DE SALIDA (m_axis, 32 bits):
--   32 words: acc_out[0..31] (int32)

entity mac_test_stream is
    generic (
        N_STEPS : natural := 27
    );
    port (
        clk           : in  std_logic;
        resetn        : in  std_logic;
        s_axis_tdata  : in  std_logic_vector(31 downto 0);
        s_axis_tvalid : in  std_logic;
        s_axis_tready : out std_logic;
        s_axis_tlast  : in  std_logic;
        m_axis_tdata  : out std_logic_vector(31 downto 0);
        m_axis_tvalid : out std_logic;
        m_axis_tready : in  std_logic;
        m_axis_tlast  : out std_logic
    );
end entity;

architecture rtl of mac_test_stream is

    type state_t is (
        ST_LOAD_BIAS,
        ST_CLEAR,
        ST_CLEAR_WAIT,
        ST_BIAS_LOAD,
        ST_BIAS_WAIT,
        ST_BIAS_WAIT2,
        ST_READ_AIN,
        ST_READ_WEIGHTS,
        ST_FIRE,
        ST_FIRE_WAIT,
        ST_DRAIN_1,
        ST_DRAIN_2,
        ST_OUTPUT
    );
    signal state : state_t;

    signal bias_cnt  : unsigned(5 downto 0);
    signal step_cnt  : unsigned(4 downto 0);
    signal w_word    : unsigned(3 downto 0);
    signal out_cnt   : unsigned(5 downto 0);

    signal bias_buf : bias_array_t;

    signal mac_a   : signed(8 downto 0);
    signal mac_b   : weight_array_t;
    signal mac_bi  : bias_array_t;
    signal mac_vi  : std_logic;
    signal mac_lb  : std_logic;
    signal mac_clr : std_logic;
    signal mac_acc : acc_array_t;

    signal a_in_r : signed(8 downto 0);

    -- tready combinacional: activo en estados que esperan datos del stream
    signal want_data : std_logic;

begin

    u_mac : entity work.mac_array
        port map (
            clk => clk, rst_n => resetn,
            a_in => mac_a, b_in => mac_b, bias_in => mac_bi,
            valid_in => mac_vi, load_bias => mac_lb, clear => mac_clr,
            acc_out => mac_acc, valid_out => open
        );

    -- tready combinacional (no registrado)
    want_data <= '1' when (state = ST_LOAD_BIAS or state = ST_READ_AIN or state = ST_READ_WEIGHTS) else '0';
    s_axis_tready <= want_data;

    process(clk)
        variable accepted : std_logic;
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state <= ST_LOAD_BIAS;
                m_axis_tdata  <= (others => '0');
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';
                mac_a   <= (others => '0');
                mac_b   <= (others => (others => '0'));
                mac_bi  <= (others => (others => '0'));
                mac_vi  <= '0';
                mac_lb  <= '0';
                mac_clr <= '0';
                bias_cnt <= (others => '0');
                step_cnt <= (others => '0');
                w_word   <= (others => '0');
                out_cnt  <= (others => '0');
                a_in_r   <= (others => '0');
            else
                mac_vi  <= '0';
                mac_lb  <= '0';
                mac_clr <= '0';
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';

                -- Handshake: dato aceptado cuando tvalid=1 AND tready=1
                accepted := s_axis_tvalid and want_data;

                case state is

                when ST_LOAD_BIAS =>
                    if accepted = '1' then
                        bias_buf(to_integer(bias_cnt)) <= signed(s_axis_tdata);
                        if bias_cnt = 31 then
                            bias_cnt <= (others => '0');
                            state <= ST_CLEAR;
                        else
                            bias_cnt <= bias_cnt + 1;
                        end if;
                    end if;

                when ST_CLEAR =>
                    mac_clr <= '1';
                    state <= ST_CLEAR_WAIT;

                when ST_CLEAR_WAIT =>
                    state <= ST_BIAS_LOAD;

                when ST_BIAS_LOAD =>
                    mac_bi <= bias_buf;
                    mac_lb <= '1';
                    state <= ST_BIAS_WAIT;

                when ST_BIAS_WAIT =>
                    state <= ST_BIAS_WAIT2;

                when ST_BIAS_WAIT2 =>
                    step_cnt <= (others => '0');
                    state <= ST_READ_AIN;

                when ST_READ_AIN =>
                    if accepted = '1' then
                        a_in_r <= signed(s_axis_tdata(8 downto 0));
                        w_word <= (others => '0');
                        state <= ST_READ_WEIGHTS;
                    end if;

                when ST_READ_WEIGHTS =>
                    if accepted = '1' then
                        mac_b(to_integer(w_word & "00")) <= signed(s_axis_tdata( 7 downto  0));
                        mac_b(to_integer(w_word & "01")) <= signed(s_axis_tdata(15 downto  8));
                        mac_b(to_integer(w_word & "10")) <= signed(s_axis_tdata(23 downto 16));
                        mac_b(to_integer(w_word & "11")) <= signed(s_axis_tdata(31 downto 24));

                        if w_word = 7 then
                            state <= ST_FIRE;
                        else
                            w_word <= w_word + 1;
                        end if;
                    end if;

                when ST_FIRE =>
                    mac_a  <= a_in_r;
                    mac_vi <= '1';
                    state <= ST_FIRE_WAIT;

                when ST_FIRE_WAIT =>
                    if step_cnt = N_STEPS - 1 then
                        state <= ST_DRAIN_1;
                    else
                        step_cnt <= step_cnt + 1;
                        state <= ST_READ_AIN;
                    end if;

                when ST_DRAIN_1 =>
                    state <= ST_DRAIN_2;

                when ST_DRAIN_2 =>
                    out_cnt <= (others => '0');
                    state <= ST_OUTPUT;

                when ST_OUTPUT =>
                    m_axis_tdata  <= std_logic_vector(mac_acc(to_integer(out_cnt)));
                    m_axis_tvalid <= '1';
                    if out_cnt = 31 then
                        m_axis_tlast <= '1';
                    end if;

                    if m_axis_tready = '1' then
                        if out_cnt = 31 then
                            state <= ST_LOAD_BIAS;
                        else
                            out_cnt <= out_cnt + 1;
                        end if;
                    end if;

                end case;
            end if;
        end if;
    end process;

end architecture;
