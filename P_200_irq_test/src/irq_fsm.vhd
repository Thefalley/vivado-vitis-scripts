library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- irq_fsm: FSM que cuenta ciclos, compara condicion, y genera interrupcion
--
-- Registros de control (desde AXI-Lite):
--   ctrl(0) = start       : 1 = arrancar FSM desde IDLE
--   ctrl(1) = irq_clear   : 1 = limpiar interrupcion, volver a IDLE
--   ctrl(2) = irq_mask    : 1 = interrupcion habilitada, 0 = enmascarada
--
-- Prescaler: cuando prescaler > 0, el contador principal solo avanza
--   cada (prescaler+1) ciclos de reloj. Permite contar mas lento.

entity irq_fsm is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        -- Config (from AXI-Lite writable registers)
        ctrl      : in  std_logic_vector(31 downto 0);
        threshold : in  std_logic_vector(31 downto 0);
        condition : in  std_logic_vector(31 downto 0);
        prescaler : in  std_logic_vector(31 downto 0);
        -- Status (to AXI-Lite read-only registers)
        status    : out std_logic_vector(31 downto 0);
        count_out : out std_logic_vector(31 downto 0);
        irq_count : out std_logic_vector(31 downto 0);
        -- Interrupt output (active-high, level-sensitive)
        irq_out   : out std_logic
    );
end irq_fsm;

architecture rtl of irq_fsm is

    type state_t is (S_IDLE, S_COUNTING, S_CHECK_COND, S_IRQ_FIRE);
    signal state        : state_t;
    signal counter      : unsigned(31 downto 0);
    signal irq_cnt      : unsigned(31 downto 0);
    signal irq_reg      : std_logic;
    signal prescale_cnt : unsigned(31 downto 0);

begin

    p_fsm: process(clk)
        variable tick : boolean;  -- true when prescaler wraps
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state        <= S_IDLE;
                counter      <= (others => '0');
                irq_cnt      <= (others => '0');
                irq_reg      <= '0';
                prescale_cnt <= (others => '0');
            else
                case state is

                    when S_IDLE =>
                        counter      <= (others => '0');
                        prescale_cnt <= (others => '0');
                        irq_reg      <= '0';
                        if ctrl(0) = '1' then
                            state <= S_COUNTING;
                        end if;

                    when S_COUNTING =>
                        if ctrl(0) = '0' then
                            counter      <= (others => '0');
                            prescale_cnt <= (others => '0');
                            state        <= S_IDLE;
                        else
                            -- Prescaler: tick every (prescaler+1) clocks
                            tick := (prescale_cnt >= unsigned(prescaler));
                            if tick then
                                prescale_cnt <= (others => '0');
                                counter <= counter + 1;
                                if counter + 1 >= unsigned(threshold) then
                                    state <= S_CHECK_COND;
                                end if;
                            else
                                prescale_cnt <= prescale_cnt + 1;
                            end if;
                        end if;

                    when S_CHECK_COND =>
                        if counter = unsigned(condition) then
                            state   <= S_IRQ_FIRE;
                            irq_reg <= '1';
                            irq_cnt <= irq_cnt + 1;
                        else
                            counter      <= (others => '0');
                            prescale_cnt <= (others => '0');
                            state        <= S_COUNTING;
                        end if;

                    when S_IRQ_FIRE =>
                        irq_reg <= '1';
                        if ctrl(1) = '1' then
                            irq_reg <= '0';
                            state   <= S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- IRQ output: masked by ctrl(2)
    irq_out   <= irq_reg and ctrl(2);
    count_out <= std_logic_vector(counter);
    irq_count <= std_logic_vector(irq_cnt);

    p_status: process(state, irq_reg)
    begin
        status <= (others => '0');
        if state /= S_IDLE then
            status(0) <= '1';
        end if;
        status(1) <= irq_reg;
        case state is
            when S_IDLE       => status(7 downto 4) <= x"0";
            when S_COUNTING   => status(7 downto 4) <= x"1";
            when S_CHECK_COND => status(7 downto 4) <= x"2";
            when S_IRQ_FIRE   => status(7 downto 4) <= x"3";
        end case;
    end process;

end rtl;
