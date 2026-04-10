library IEEE;
use IEEE.STD_LOGIC_1164.ALL;
use IEEE.NUMERIC_STD.ALL;

-- add_wide_test: Test de sumas anchas (50 y 80 bits) con pines reales
--
-- Problema: 50+80 bits de entrada + salida = demasiados pines para el chip.
-- Solucion: usar un registro de desplazamiento para meter datos serial,
-- y XOR-reducir la salida a 8 bits (LEDs de ZedBoard).
--
-- Arquitectura:
--   - Datos entran por data_in(7:0) serial, se van llenando en shift registers
--   - sel='0' → suma 50+50=51 bits
--   - sel='1' → suma 80+80=81 bits
--   - result_xor(7:0) = XOR-fold del resultado para verificacion
--   - Cada suma es: input_reg → combinacional add → output_reg (1 ciclo)

entity add_wide_test is
    port (
        clk       : in  std_logic;
        rst       : in  std_logic;
        -- Entrada serial (8 bits por ciclo)
        data_in   : in  std_logic_vector(7 downto 0);
        load      : in  std_logic;   -- '1' = shift data_in into registers
        sel       : in  std_logic;   -- '0' = 50-bit, '1' = 80-bit
        go        : in  std_logic;   -- '1' = ejecutar suma
        -- Salida (8 bits, XOR-fold del resultado)
        result_out : out std_logic_vector(7 downto 0);
        done       : out std_logic
    );
end entity;

architecture rtl of add_wide_test is

    -- Shift registers de entrada (80 bits max por operando)
    signal sr_a : std_logic_vector(79 downto 0) := (others => '0');
    signal sr_b : std_logic_vector(79 downto 0) := (others => '0');
    signal load_a_done : std_logic := '0';  -- '0'=llenando A, '1'=llenando B

    -- Sumas
    signal sum50  : unsigned(50 downto 0);  -- 51 bits
    signal sum80  : unsigned(80 downto 0);  -- 81 bits

    -- Registros de resultado
    signal result50_r : unsigned(50 downto 0);
    signal result80_r : unsigned(80 downto 0);
    signal done_r     : std_logic := '0';

    -- XOR-fold: reduce N bits a 8 bits
    function xor_fold_51(v : unsigned(50 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(7 downto 0) := (others => '0');
    begin
        for i in 0 to 50 loop
            r(i mod 8) := r(i mod 8) xor std_logic(v(i));
        end loop;
        return r;
    end function;

    function xor_fold_81(v : unsigned(80 downto 0)) return std_logic_vector is
        variable r : std_logic_vector(7 downto 0) := (others => '0');
    begin
        for i in 0 to 80 loop
            r(i mod 8) := r(i mod 8) xor std_logic(v(i));
        end loop;
        return r;
    end function;

begin

    -- Sumas combinacionales (el path critico que queremos medir)
    sum50 <= resize(unsigned(sr_a(49 downto 0)), 51)
           + resize(unsigned(sr_b(49 downto 0)), 51);

    sum80 <= resize(unsigned(sr_a(79 downto 0)), 81)
           + resize(unsigned(sr_b(79 downto 0)), 81);

    process(clk)
    begin
        if rising_edge(clk) then
            if rst = '1' then
                sr_a <= (others => '0');
                sr_b <= (others => '0');
                load_a_done <= '0';
                result50_r  <= (others => '0');
                result80_r  <= (others => '0');
                done_r      <= '0';
            else
                done_r <= '0';

                if load = '1' then
                    -- Shift data_in into sr_a o sr_b
                    if load_a_done = '0' then
                        sr_a <= sr_a(71 downto 0) & data_in;
                    else
                        sr_b <= sr_b(71 downto 0) & data_in;
                    end if;
                end if;

                if go = '1' then
                    -- Registrar resultado de la suma
                    result50_r <= sum50;
                    result80_r <= sum80;
                    done_r     <= '1';
                    -- Reset para siguiente operacion
                    load_a_done <= '0';
                end if;

                -- Señal para alternar entre A y B
                -- Cuando se han cargado 10 bytes (80 bits), cambiar a B
                -- (simplificado: el ARM controla load_a_done via un bit extra)
                if load = '1' and go = '0' then
                    -- Cada 10 loads, cambiar de A a B
                    -- Simplificacion: el ARM manda primero A, luego pone
                    -- load_a_done='1' manualmente via un registro
                end if;
            end if;
        end if;
    end process;

    -- Salida: XOR-fold segun sel
    result_out <= xor_fold_51(result50_r) when sel = '0'
                  else xor_fold_81(result80_r);
    done <= done_r;

end architecture;
