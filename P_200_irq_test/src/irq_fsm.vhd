library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- irq_fsm: FSM que cuenta ciclos, compara condicion, y genera interrupcion
--
-- Registros de control (desde AXI-Lite):
--   ctrl(0) = start       : 1 = arrancar FSM desde IDLE
--   ctrl(1) = irq_clear   : 1 = limpiar interrupcion, volver a IDLE
--
-- Estados:
--   S_IDLE       -> esperando start
--   S_COUNTING   -> contando ciclos hasta threshold
--   S_CHECK_COND -> compara counter con condition
--   S_IRQ_FIRE   -> interrupcion activa, esperando clear

entity irq_fsm is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        -- Config (from AXI-Lite writable registers)
        ctrl      : in  std_logic_vector(31 downto 0);
        threshold : in  std_logic_vector(31 downto 0);
        condition : in  std_logic_vector(31 downto 0);
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
    signal state   : state_t;
    signal counter : unsigned(31 downto 0);
    signal irq_cnt : unsigned(31 downto 0);
    signal irq_reg : std_logic;

begin

    -- Main FSM process
    p_fsm: process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
                state   <= S_IDLE;
                counter <= (others => '0');
                irq_cnt <= (others => '0');
                irq_reg <= '0';
            else
                case state is

                    when S_IDLE =>
                        counter <= (others => '0');
                        irq_reg <= '0';
                        if ctrl(0) = '1' then
                            state <= S_COUNTING;
                        end if;

                    when S_COUNTING =>
                        if ctrl(0) = '0' then
                            -- Software cleared start -> abort
                            counter <= (others => '0');
                            state   <= S_IDLE;
                        else
                            counter <= counter + 1;
                            if counter + 1 >= unsigned(threshold) then
                                state <= S_CHECK_COND;
                            end if;
                        end if;

                    when S_CHECK_COND =>
                        if counter = unsigned(condition) then
                            -- Condition met -> fire interrupt
                            state   <= S_IRQ_FIRE;
                            irq_reg <= '1';
                            irq_cnt <= irq_cnt + 1;
                        else
                            -- Condition not met -> restart counting
                            counter <= (others => '0');
                            state   <= S_COUNTING;
                        end if;

                    when S_IRQ_FIRE =>
                        irq_reg <= '1';
                        if ctrl(1) = '1' then
                            -- Software cleared the interrupt
                            irq_reg <= '0';
                            state   <= S_IDLE;
                        end if;

                end case;
            end if;
        end if;
    end process;

    -- Concurrent outputs
    irq_out   <= irq_reg;
    count_out <= std_logic_vector(counter);
    irq_count <= std_logic_vector(irq_cnt);

    -- Status register (combinational)
    -- bit 0    : fsm_running (1 when not IDLE)
    -- bit 1    : irq_pending
    -- bits 7:4 : state encoding (0=IDLE, 1=COUNTING, 2=CHECK, 3=IRQ)
    p_status: process(state, irq_reg)
    begin
        status <= (others => '0');
        -- bit 0: running
        if state /= S_IDLE then
            status(0) <= '1';
        end if;
        -- bit 1: irq pending
        status(1) <= irq_reg;
        -- bits 7:4: state code
        case state is
            when S_IDLE       => status(7 downto 4) <= x"0";
            when S_COUNTING   => status(7 downto 4) <= x"1";
            when S_CHECK_COND => status(7 downto 4) <= x"2";
            when S_IRQ_FIRE   => status(7 downto 4) <= x"3";
        end case;
    end process;

end rtl;
