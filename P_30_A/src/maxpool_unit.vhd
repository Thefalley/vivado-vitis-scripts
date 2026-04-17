-------------------------------------------------------------------------------
-- maxpool_unit.vhd — MaxPool comparador INT8 (1 etapa)
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Compara cada valor de entrada con el maximo acumulado.
--   Si el nuevo valor es mayor, actualiza el maximo.
--   Al final de la ventana, max_out tiene el maximo de todos los valores.
--
-- COMO FUNCIONA:
--   - clear = '1': inicializa el registro a -128 (minimo int8)
--   - valid_in = '1': compara x_in con max_r, guarda el mayor
--   - max_out: siempre tiene el valor actual del registro
--
-- EJEMPLO para MaxPool 2×2, stride 2:
--   Ventana de 4 valores: [35, -10, 127, 42]
--   Ciclo 0: clear → max_r = -128
--   Ciclo 1: x_in=35,  35 > -128 → max_r = 35
--   Ciclo 2: x_in=-10, -10 < 35  → max_r = 35
--   Ciclo 3: x_in=127, 127 > 35  → max_r = 127
--   Ciclo 4: x_in=42,  42 < 127  → max_r = 127, valid_out = '1'
--   Resultado: max_out = 127 (correcto)
--
-- NO HAY PIPELINE: la operacion es simplemente una comparacion de 8 bits
-- y un mux, que cabe en < 1 ns. No hace falta partir en etapas.
--
-- NOTA: el MaxPool no tiene requantizacion. La salida tiene
-- la misma escala y zero point que la entrada.
-- (Los valores ya son int8, el maximo de int8 sigue siendo int8.)
--
-- LATENCIA: 1 ciclo por valor (sin pipeline).
--   Para ventana 2×2: 4 ciclos. Para ventana 3×3: 9 ciclos.
--   El resultado esta listo en max_out cuando valid_out = '1'.
--
-- THROUGHPUT: 1 comparacion por ciclo.
--
-- RECURSOS:
--   DSP48E1: 0 (no hay multiplicacion)
--   LUTs: ~8 (comparador 8 bits + mux)
--   FFs: ~9 (registro max_r 8 bits + valid_out 1 bit)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity maxpool_unit is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- Entrada
        x_in      : in  signed(7 downto 0);     -- valor int8 a comparar
        valid_in  : in  std_logic;               -- '1' = hay dato nuevo
        clear     : in  std_logic;               -- '1' = iniciar nueva ventana

        -- Salida
        max_out   : out signed(7 downto 0);      -- maximo actual
        valid_out : out std_logic                 -- '1' = se actualizo el maximo
    );
end entity maxpool_unit;

architecture rtl of maxpool_unit is

    ---------------------------------------------------------------------------
    -- Registro del maximo acumulado.
    -- Se inicializa a -128 (el valor minimo de int8) con clear.
    -- Cada vez que llega un valor mayor, se actualiza.
    ---------------------------------------------------------------------------
    signal max_r : signed(7 downto 0);

begin

    ---------------------------------------------------------------------------
    -- PROCESO PRINCIPAL: COMPARAR Y ACTUALIZAR
    --
    -- Prioridad: rst_n > clear > valid_in
    --
    -- rst_n = '0': reset global → max_r = -128, valid_out = '0'
    -- clear = '1': inicio de nueva ventana → max_r = -128, valid_out = '0'
    -- valid_in = '1': comparar x_in con max_r:
    --   - Si x_in > max_r: max_r <= x_in (nuevo maximo)
    --   - Si x_in <= max_r: max_r <= max_r (mantener)
    --   - valid_out = '1' (se proceso un valor)
    -- Sin operacion: valid_out = '0'
    --
    -- La comparacion signed de 8 bits es trivial en FPGA:
    -- ~4 LUTs para el comparador, ~4 LUTs para el mux.
    -- Timing: < 1 ns. No hay problema a 100 MHz.
    ---------------------------------------------------------------------------
    p_maxpool : process(clk)
    begin
        if rising_edge(clk) then
            if rst_n = '0' then
            -- Reset global: inicializar al minimo int8
            max_r     <= to_signed(-128, 8);
            valid_out <= '0';

        else
            if clear = '1' then
                -- Inicio de nueva ventana: resetear al minimo
                max_r     <= to_signed(-128, 8);
                valid_out <= '0';

            elsif valid_in = '1' then
                -- Comparar y actualizar
                if x_in > max_r then
                    max_r <= x_in;     -- nuevo maximo
                else
                    max_r <= max_r;    -- mantener (redundante pero explicito)
                end if;
                valid_out <= '1';

            else
                -- Sin operacion este ciclo
                valid_out <= '0';
            end if;
        end if;
        end if;
    end process p_maxpool;

    ---------------------------------------------------------------------------
    -- SALIDA: cable directo al registro (sin logica combinacional)
    ---------------------------------------------------------------------------
    max_out <= max_r;

end architecture rtl;
