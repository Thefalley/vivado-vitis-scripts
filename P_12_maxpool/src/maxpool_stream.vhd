library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- maxpool_stream: Wrapper AXI-Stream para testar maxpool_unit via DMA
--
-- PROTOCOLO DE ENTRADA (s_axis, 32 bits):
--   Para cada pixel:
--     1 word con bit 8 = '1' (0x100) -> clear: reset max a -128
--     25 words con bits [7:0] = valor int8 (signed) -> valid_in pulses
--     1 word con bit 9 = '1' (0x200) -> read: captura max_out y envia al output
--   Total: 27 words por pixel
--
-- PROTOCOLO DE SALIDA (m_axis, 32 bits):
--   1 word por pixel: max_out sign-extended a 32 bits en [7:0]

entity maxpool_stream is
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

architecture rtl of maxpool_stream is

    type state_t is (
        ST_INPUT,       -- accept input words: clear / value / read
        ST_OUTPUT,      -- send captured max to output stream
        ST_DONE         -- all pixels done (after TLAST), wait for reset
    );
    signal state : state_t;

    -- maxpool_unit signals
    signal mp_x_in      : signed(7 downto 0);
    signal mp_valid_in   : std_logic;
    signal mp_clear      : std_logic;
    signal mp_max_out    : signed(7 downto 0);
    signal mp_valid_out  : std_logic;

    -- Captured max for output
    signal captured_max  : std_logic_vector(31 downto 0);

    -- Track if this is the last pixel (TLAST seen on read command)
    signal is_last       : std_logic;

    -- Want data from input stream
    signal want_data     : std_logic;

begin

    u_maxpool : entity work.maxpool_unit
        port map (
            clk       => clk,
            rst_n     => resetn,
            x_in      => mp_x_in,
            valid_in  => mp_valid_in,
            clear     => mp_clear,
            max_out   => mp_max_out,
            valid_out => mp_valid_out
        );

    want_data <= '1' when state = ST_INPUT else '0';
    s_axis_tready <= want_data;

    process(clk)
        variable accepted : std_logic;
    begin
        if rising_edge(clk) then
            if resetn = '0' then
                state        <= ST_INPUT;
                mp_x_in      <= (others => '0');
                mp_valid_in  <= '0';
                mp_clear     <= '0';
                captured_max <= (others => '0');
                is_last      <= '0';
                m_axis_tdata  <= (others => '0');
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';
            else
                -- Default: deassert single-cycle pulses
                mp_valid_in  <= '0';
                mp_clear     <= '0';
                m_axis_tvalid <= '0';
                m_axis_tlast  <= '0';

                accepted := s_axis_tvalid and want_data;

                case state is

                when ST_INPUT =>
                    if accepted = '1' then
                        if s_axis_tdata(9) = '1' then
                            -- READ command: capture max_out, go to output
                            captured_max <= (others => '0');
                            captured_max(7 downto 0) <= std_logic_vector(mp_max_out);
                            -- sign-extend to 32 bits
                            if mp_max_out(7) = '1' then
                                captured_max(31 downto 8) <= (others => '1');
                            else
                                captured_max(31 downto 8) <= (others => '0');
                            end if;
                            if s_axis_tlast = '1' then
                                is_last <= '1';
                            else
                                is_last <= '0';
                            end if;
                            state <= ST_OUTPUT;

                        elsif s_axis_tdata(8) = '1' then
                            -- CLEAR command: pulse clear on maxpool
                            mp_clear <= '1';

                        else
                            -- DATA word: feed value to maxpool
                            mp_x_in     <= signed(s_axis_tdata(7 downto 0));
                            mp_valid_in <= '1';
                        end if;
                    end if;

                when ST_OUTPUT =>
                    m_axis_tdata  <= captured_max;
                    m_axis_tvalid <= '1';
                    m_axis_tlast  <= is_last;
                    if m_axis_tready = '1' then
                        if is_last = '1' then
                            state <= ST_DONE;
                        else
                            state <= ST_INPUT;
                        end if;
                    end if;

                when ST_DONE =>
                    -- Wait for reset (all data processed)
                    null;

                end case;
            end if;
        end if;
    end process;

end architecture;
