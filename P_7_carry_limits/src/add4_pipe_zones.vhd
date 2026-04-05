library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- add4_pipe_zones: Sumador de 4 valores signed de N bits
-- con carry partido en zonas (para N grande, ej. 64 bits)
--
-- R = A + B + C + D (signed, N+2 bits resultado)
--
-- Problema: incluso con tree (A+B)+(C+D), el carry chain es N+2.
-- Para N=64, carry=66 bits -> puede no pasar timing a 100 MHz.
--
-- Solucion: partir la suma en zona BAJA y zona ALTA con carry explicito.
--
-- Definimos SPLIT = N/2 (ej. 32 para N=64)
--
--   Stage 1 (paralelo):
--     S_AB = A + B    (N+1 bits)
--     S_CD = C + D    (N+1 bits)
--
--   Stage 2 (paralelo):
--     {carry_lo, R_lo} = S_AB[SPLIT-1:0] + S_CD[SPLIT-1:0]  (carry SPLIT bits)
--     R_hi_0 = S_AB[N:SPLIT] + S_CD[N:SPLIT]                 (carry N-SPLIT+1 bits)
--     R_hi_1 = S_AB[N:SPLIT] + S_CD[N:SPLIT] + 1             (speculative carry)
--
--   Stage 3:
--     R_hi = carry_lo ? R_hi_1 : R_hi_0   (mux, sin carry chain)
--     R = {R_hi, R_lo}
--
-- Carry chain max: max(SPLIT, N-SPLIT+1) = ~N/2 bits
-- Latencia: 4 ciclos
-- Throughput: 1/ciclo

entity add4_pipe_zones is
    generic (
        DATA_WIDTH : integer := 64
    );
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        valid_in  : in  std_logic;
        a_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        b_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        c_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        d_in      : in  std_logic_vector(DATA_WIDTH - 1 downto 0);
        valid_out : out std_logic;
        result    : out std_logic_vector(DATA_WIDTH + 1 downto 0)
    );
end add4_pipe_zones;

architecture rtl of add4_pipe_zones is

    constant RW    : integer := DATA_WIDTH + 2;
    constant SPLIT : integer := DATA_WIDTH / 2;     -- punto de corte
    constant HI_W  : integer := DATA_WIDTH + 1 - SPLIT;  -- ancho zona alta de S_AB/S_CD

    -- Stage 0: input registers
    signal a_reg, b_reg, c_reg, d_reg : signed(DATA_WIDTH - 1 downto 0);
    signal v0 : std_logic := '0';

    -- Stage 1: sumas paralelas
    signal s_ab : signed(DATA_WIDTH downto 0);
    signal s_cd : signed(DATA_WIDTH downto 0);
    signal v1   : std_logic := '0';

    -- Stage 2: zona baja + zona alta especulativa
    signal r_lo      : unsigned(SPLIT - 1 downto 0);
    signal carry_lo  : std_logic;
    signal r_hi_0    : signed(HI_W downto 0);   -- sin carry
    signal r_hi_1    : signed(HI_W downto 0);   -- con carry
    signal v2        : std_logic := '0';

    -- Stage 3: select + assemble
    signal v3 : std_logic := '0';

begin

    -- Stage 0: register inputs
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v0 <= '0';
            else
                v0 <= valid_in;
                a_reg <= signed(a_in);
                b_reg <= signed(b_in);
                c_reg <= signed(c_in);
                d_reg <= signed(d_in);
            end if;
        end if;
    end process;

    -- Stage 1: dos sumas paralelas (carry N+1 cada una)
    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v1 <= '0';
            else
                v1 <= v0;
                s_ab <= resize(a_reg, DATA_WIDTH + 1) + resize(b_reg, DATA_WIDTH + 1);
                s_cd <= resize(c_reg, DATA_WIDTH + 1) + resize(d_reg, DATA_WIDTH + 1);
            end if;
        end if;
    end process;

    -- Stage 2: zona baja + zona alta especulativa (carry SPLIT y HI_W bits)
    process(clk)
        variable lo_sum : unsigned(SPLIT downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v2 <= '0';
            else
                v2 <= v1;

                -- Zona BAJA: carry chain = SPLIT bits
                lo_sum := resize(unsigned(std_logic_vector(s_ab(SPLIT - 1 downto 0))), SPLIT + 1)
                        + resize(unsigned(std_logic_vector(s_cd(SPLIT - 1 downto 0))), SPLIT + 1);
                r_lo     <= lo_sum(SPLIT - 1 downto 0);
                carry_lo <= lo_sum(SPLIT);

                -- Zona ALTA especulativa: carry chain = HI_W bits (paralelo con baja)
                r_hi_0 <= resize(s_ab(DATA_WIDTH downto SPLIT), HI_W + 1)
                        + resize(s_cd(DATA_WIDTH downto SPLIT), HI_W + 1);
                r_hi_1 <= resize(s_ab(DATA_WIDTH downto SPLIT), HI_W + 1)
                        + resize(s_cd(DATA_WIDTH downto SPLIT), HI_W + 1)
                        + 1;
            end if;
        end if;
    end process;

    -- Stage 3: select carry + assemble
    process(clk)
        variable hi_sel : signed(HI_W downto 0);
    begin
        if rising_edge(clk) then
            if rst = '1' then
                v3     <= '0';
                result <= (others => '0');
            else
                v3 <= v2;

                -- Mux: 1 LUT de delay, sin carry chain
                if carry_lo = '1' then
                    hi_sel := r_hi_1;
                else
                    hi_sel := r_hi_0;
                end if;

                -- Ensamblar: {hi, lo}
                result <= std_logic_vector(hi_sel(RW - SPLIT - 1 downto 0))
                        & std_logic_vector(r_lo);
            end if;
        end if;
    end process;

    valid_out <= v3;

end rtl;
