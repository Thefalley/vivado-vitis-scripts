library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- mult_2dsp: Multiplicacion 32x30 con 2 multiplicadores time-multiplexed
--
-- Misma descomposicion que mult_4dsp, pero usa 2 multiplicadores
-- que se reutilizan en 2 fases:
--
--   Fase 1 (S_MUL1): mult0 = A_L x B_L (P1),  mult1 = A_L x B_H (P2)
--   Fase 2 (S_MUL2): mult0 = A_H x B_L (P3),  mult1 = A_H x B_H (P4)
--
-- Truco: mult0 siempre usa B_L, mult1 siempre usa B_H.
-- Solo se muxa la entrada A (A_L o A_H).
--
-- IMPORTANTE: Los productos se capturan en el MISMO estado donde el
-- mux los produce, no en el siguiente (el mux cambia con el estado).
--
-- Latencia: 4 ciclos (idle -> mul1 -> mul2 -> sum -> out)
-- Throughput: 1 resultado cada 4 ciclos
-- Recursos esperados: 2 DSP48E1

entity mult_2dsp is
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
end mult_2dsp;

architecture rtl of mult_2dsp is

    type state_t is (S_IDLE, S_MUL1, S_MUL2, S_SUM);
    signal state : state_t := S_IDLE;

    -- Operandos registrados (split)
    signal a_l : unsigned(17 downto 0);
    signal a_h : unsigned(13 downto 0);
    signal b_l : unsigned(17 downto 0);
    signal b_h : unsigned(11 downto 0);

    -- Entradas muxeadas a los 2 multiplicadores (18x18 cada uno)
    signal m0_a : unsigned(17 downto 0);
    signal m0_b : unsigned(17 downto 0);
    signal m1_a : unsigned(17 downto 0);
    signal m1_b : unsigned(17 downto 0);

    -- Productos combinacionales (2 DSPs)
    signal prod0 : unsigned(35 downto 0);
    signal prod1 : unsigned(35 downto 0);

    -- Productos parciales almacenados
    signal p1, p2 : unsigned(35 downto 0);
    signal p3, p4 : unsigned(35 downto 0);

begin

    -- Mux combinacional: selecciona operandos segun estado
    process(state, a_l, a_h, b_l, b_h)
    begin
        m0_a <= (others => '0');
        m0_b <= (others => '0');
        m1_a <= (others => '0');
        m1_b <= (others => '0');
        case state is
            when S_MUL1 =>
                m0_a <= a_l;
                m0_b <= b_l;
                m1_a <= a_l;
                m1_b <= resize(b_h, 18);
            when S_MUL2 =>
                m0_a <= resize(a_h, 18);
                m0_b <= b_l;
                m1_a <= resize(a_h, 18);
                m1_b <= resize(b_h, 18);
            when others =>
                null;
        end case;
    end process;

    -- 2 multiplicadores (Vivado -> 2 DSP48E1)
    prod0 <= m0_a * m0_b;
    prod1 <= m1_a * m1_b;

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
                            state <= S_MUL1;
                        end if;

                    when S_MUL1 =>
                        -- Mux esta produciendo P1 y P2 -> capturar
                        p1    <= prod0;
                        p2    <= prod1;
                        state <= S_MUL2;

                    when S_MUL2 =>
                        -- Mux esta produciendo P3 y P4 -> capturar
                        p3    <= prod0;
                        p4    <= prod1;
                        state <= S_SUM;

                    when S_SUM =>
                        -- Todos los productos registrados, sumar
                        result <= std_logic_vector(
                            resize(p1, 62)
                          + shift_left(resize(p2, 62), 18)
                          + shift_left(resize(p3, 62), 18)
                          + shift_left(resize(p4, 62), 36)
                        );
                        valid_out <= '1';
                        state     <= S_IDLE;
                end case;
            end if;
        end if;
    end process;

end rtl;
