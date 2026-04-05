library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- mult_1dsp: Multiplicacion 32x30 con 1 solo multiplicador secuencial
--
-- Un unico multiplicador 18x18 calcula los 4 productos parciales
-- uno por ciclo, muxeando las entradas:
--
--   Fase 0 (S_MUL0): A_L x B_L -> P1
--   Fase 1 (S_MUL1): A_L x B_H -> P2
--   Fase 2 (S_MUL2): A_H x B_L -> P3
--   Fase 3 (S_MUL3): A_H x B_H -> P4
--
-- IMPORTANTE: Los productos se capturan en el MISMO estado donde el
-- mux los produce.
--
-- Latencia: 5 ciclos (idle -> mul0 -> mul1 -> mul2 -> mul3+sum -> out)
-- Throughput: 1 resultado cada 5 ciclos
-- Recursos esperados: 1 DSP48E1

entity mult_1dsp is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        valid_in  : in  std_logic;
        a_in      : in  std_logic_vector(31 downto 0);
        b_in      : in  std_logic_vector(29 downto 0);
        ready     : out std_logic;
        valid_out : out std_logic;
        result    : out std_logic_vector(61 downto 0)
    );
end mult_1dsp;

architecture rtl of mult_1dsp is

    type state_t is (S_IDLE, S_MUL0, S_MUL1, S_MUL2, S_MUL3);
    signal state : state_t := S_IDLE;

    -- Operandos registrados (split)
    signal a_l : unsigned(17 downto 0);
    signal a_h : unsigned(13 downto 0);
    signal b_l : unsigned(17 downto 0);
    signal b_h : unsigned(11 downto 0);

    -- Entradas muxeadas al multiplicador unico (18x18)
    signal m_a : unsigned(17 downto 0);
    signal m_b : unsigned(17 downto 0);

    -- Producto combinacional (1 DSP)
    signal prod : unsigned(35 downto 0);

    -- Productos parciales almacenados
    signal p1, p2, p3 : unsigned(35 downto 0);

begin

    -- Mux combinacional: selecciona operandos segun fase
    process(state, a_l, a_h, b_l, b_h)
    begin
        m_a <= (others => '0');
        m_b <= (others => '0');
        case state is
            when S_MUL0 =>  -- P1 = A_L x B_L
                m_a <= a_l;
                m_b <= b_l;
            when S_MUL1 =>  -- P2 = A_L x B_H
                m_a <= a_l;
                m_b <= resize(b_h, 18);
            when S_MUL2 =>  -- P3 = A_H x B_L
                m_a <= resize(a_h, 18);
                m_b <= b_l;
            when S_MUL3 =>  -- P4 = A_H x B_H
                m_a <= resize(a_h, 18);
                m_b <= resize(b_h, 18);
            when others =>
                null;
        end case;
    end process;

    -- 1 multiplicador (Vivado -> 1 DSP48E1)
    prod <= m_a * m_b;

    -- Maquina de estados
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                state     <= S_IDLE;
                ready     <= '1';
                valid_out <= '0';
                result    <= (others => '0');
            else
                valid_out <= '0';

                case state is
                    when S_IDLE =>
                        ready <= '1';
                        if valid_in = '1' then
                            a_l   <= unsigned(a_in(17 downto 0));
                            a_h   <= unsigned(a_in(31 downto 18));
                            b_l   <= unsigned(b_in(17 downto 0));
                            b_h   <= unsigned(b_in(29 downto 18));
                            ready <= '0';
                            state <= S_MUL0;
                        end if;

                    when S_MUL0 =>
                        -- Mux produce P1 -> capturar
                        p1    <= prod;
                        state <= S_MUL1;

                    when S_MUL1 =>
                        -- Mux produce P2 -> capturar
                        p2    <= prod;
                        state <= S_MUL2;

                    when S_MUL2 =>
                        -- Mux produce P3 -> capturar
                        p3    <= prod;
                        state <= S_MUL3;

                    when S_MUL3 =>
                        -- Mux produce P4 -> sumar con los anteriores
                        result <= std_logic_vector(
                            resize(p1, 62)
                          + shift_left(resize(p2, 62), 18)
                          + shift_left(resize(p3, 62), 18)
                          + shift_left(resize(prod, 62), 36)
                        );
                        valid_out <= '1';
                        state     <= S_IDLE;
                end case;
            end if;
        end if;
    end process;

end rtl;
