-------------------------------------------------------------------------------
-- mac_array.vhd — Array de N_MAC unidades MAC en paralelo
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Instancia N_MAC mac_units que trabajan en paralelo.
--   Todas reciben la MISMA activacion (broadcast) pero cada una
--   tiene su PROPIO peso y su PROPIO bias.
--   Asi se calculan N_MAC canales de salida simultaneamente.
--
-- =========================================================================
-- EXPLICACION TECNICA: Output Channel Parallelism (OCP)
-- =========================================================================
--
-- CONTEXTO — QUE ES UNA CONVOLUCION EN YOLOV4:
--
--   Ejemplo real: layer_005 del modelo YOLOv4-416 INT8.
--   Entrada: 416×416 pixeles, 3 canales (RGB).
--   Salida:  416×416 pixeles, 32 canales.
--   Kernel:  3×3.
--   Filtros: 32 (uno por canal de salida).
--
--   Cada filtro es un bloque de pesos de tamaño 3×3×3 = 27 valores.
--   Ejemplo del filtro 0 (produce el canal de salida 0):
--
--     Canal R:          Canal G:          Canal B:
--     [12, -3,  7]     [ 4,  8, -1]     [-6,  2,  5]
--     [ 1, -5,  9]     [ 3, -7,  0]     [ 8, -4,  1]
--     [-2,  6, -8]     [ 5,  1, -3]     [-1,  9, -7]
--
--   Para calcular UN pixel de salida (ej: posicion row=5, col=10):
--     1. Tomar la ventana 3×3 de la imagen centrada en (5,10)
--     2. Tiene 3 canales → 3×3×3 = 27 valores de activacion
--     3. Multiplicar elemento a elemento con los 27 pesos del filtro
--     4. Sumar todo + bias → 27 operaciones MAC (multiply-accumulate)
--
--   Para el MISMO pixel pero canal de salida 1, se usan los pesos
--   del filtro 1. Y asi para los 32 canales de salida.
--
-- LA OBSERVACION CLAVE:
--
--   Canal salida 0:  acc_0  = bias_0  + x[4,9,R]×w0[0,0,R]  + x[4,10,R]×w0[0,1,R]  + ...
--   Canal salida 1:  acc_1  = bias_1  + x[4,9,R]×w1[0,0,R]  + x[4,10,R]×w1[0,1,R]  + ...
--   Canal salida 31: acc_31 = bias_31 + x[4,9,R]×w31[0,0,R] + x[4,10,R]×w31[0,1,R] + ...
--                             ────────   ────────              ─────────
--                             distinto   IGUAL                 IGUAL
--
--   Las activaciones son IDENTICAS para los 32 canales de salida.
--   Solo cambian los pesos y el bias. Esto permite paralelizar.
--
-- LA OPTIMIZACION — OUTPUT CHANNEL PARALLELISM:
--
--   En vez de calcular los 32 canales uno tras otro (secuencial),
--   ponemos 32 multiplicadores en paralelo. Todos reciben la MISMA
--   activacion (broadcast) pero cada uno tiene SU propio peso.
--
--   Sin paralelismo (1 mac_unit):
--     Ciclo 1-27:    calcular canal 0 del pixel    (27 MACs)
--     Ciclo 28-54:   calcular canal 1 del pixel    (27 MACs)
--     ...
--     Ciclo 838-864: calcular canal 31 del pixel   (27 MACs)
--     Total: 27 × 32 = 864 ciclos POR PIXEL
--
--   Con paralelismo (32 mac_units en mac_array):
--     Ciclo 1:  enviar x[0,0,R] a las 32 mac_units, cada una con SU peso
--     Ciclo 2:  enviar x[0,1,R] a las 32 mac_units
--     ...
--     Ciclo 27: enviar x[2,2,B] a las 32 mac_units
--     Total: 27 ciclos POR PIXEL (los 32 canales salen a la vez)
--
--   Speedup: 32× mas rapido, a cambio de 32× mas DSPs.
--   Esta tecnica se llama "Output Channel Parallelism" (OCP).
--   La usan Xilinx DPU (B512/B1024/B4096), Google TPU v1, y
--   practicamente todas las DPUs comerciales de FPGA.
--
-- POR QUE N_MAC=32 Y NO 64 O 16:
--
--   La ZedBoard (XC7Z020) tiene 80 DSP48E1.
--     mac_array:     32 DSPs (1 por mac_unit)
--     requantize:     4 DSPs (multiplicacion 32×30)
--     leaky_relu:     4 DSPs (2 ramas × 2)
--     elem_add:       4 DSPs (2 ramas × 2)
--     Total:         44 DSPs de 80 (55%)
--
--   Con 64 MACs: 76 DSPs (95%) — demasiado justo, sin margen.
--   Con 16 MACs: mitad de velocidad sin necesidad.
--   32 es el sweet spot para esta FPGA.
--
-- DIAGRAMA DEL HARDWARE:
--
--                   a_in (1 activacion, broadcast)
--                           │
--             ┌─────────────┼─────────────┐
--             │             │             │
--             ▼             ▼             ▼
--        ┌─────────┐  ┌─────────┐   ┌─────────┐
--        │mac_unit │  │mac_unit │   │mac_unit │
--        │   #0    │  │   #1    │   │  #31    │
--        │peso: w0 │  │peso: w1 │   │peso: w31│
--        │bias: b0 │  │bias: b1 │   │bias: b31│
--        └────┬────┘  └────┬────┘   └────┬────┘
--             │             │             │
--             ▼             ▼             ▼
--         acc_out(0)    acc_out(1)    acc_out(31)
--
--   Las 32 mac_units son hardware fisico separado:
--   32 multiplicadores, 32 acumuladores, 32 DSP48E1.
--   No comparten nada excepto a_in y las señales de control.
--
-- SECUENCIA COMPLETA PARA 1 PIXEL (controlada por conv_engine):
--
--   1. CLEAR:     las 32 mac_units ponen acc=0              (1 ciclo)
--   2. LOAD_BIAS: cada mac_unit carga SU bias               (1 ciclo)
--   3. BUCLE MAC: 27 iteraciones (3×3×3 para layer_005)     (27 ciclos)
--        Cada iteracion: a_in = activacion[j], b_in[i] = peso_filtro_i[j]
--   4. RESULTADO:  32 acumuladores listos en paralelo
--   5. REQUANTIZE: cada acc → int8 via multiply_shift       (4 ciclos)
--   6. ESCRIBIR:   32 bytes a DDR                           (32 ciclos)
--
-- NOTA: el "for generate" de VHDL NO es un bucle temporal.
--   Es una directiva al sintetizador: "crea 32 copias fisicas".
--   Despues de sintesis, hay 32 multiplicadores reales en el chip.
--
-- =========================================================================
--
-- INTERFAZ DE DATOS:
--   Los pesos y bias se pasan como arrays de N_MAC elementos.
--   Los acumuladores salen como array de N_MAC elementos.
--   Se usa el tipo array definido en mac_array_pkg.
--
-- LATENCIA: 2 ciclos (misma que mac_unit)
-- THROUGHPUT: 1 MAC/ciclo × N_MAC filtros en paralelo
-- RECURSOS: N_MAC DSP48E1 (1 por mac_unit) + N_MAC sumadores 32 bits
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

-- Paquete con los tipos array para los puertos
package mac_array_pkg is
    -- Numero de MACs en paralelo (configurable)
    constant N_MAC : natural := 32;

    -- Arrays para los puertos del mac_array
    type weight_array_t is array(0 to N_MAC-1) of signed(7 downto 0);
    type bias_array_t   is array(0 to N_MAC-1) of signed(31 downto 0);
    type acc_array_t    is array(0 to N_MAC-1) of signed(31 downto 0);
end package mac_array_pkg;


library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.mac_array_pkg.all;

entity mac_array is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;

        -- Activacion broadcast (la misma para todas las MACs)
        a_in      : in  signed(8 downto 0);     -- 9 bits signed

        -- Peso individual por MAC (cada filtro tiene su peso)
        b_in      : in  weight_array_t;          -- array de N_MAC × 8 bits

        -- Bias individual por MAC (cada filtro tiene su bias)
        bias_in   : in  bias_array_t;            -- array de N_MAC × 32 bits

        -- Control (compartido, todas las MACs hacen lo mismo)
        valid_in  : in  std_logic;
        load_bias : in  std_logic;
        clear     : in  std_logic;

        -- Acumuladores de salida (uno por MAC)
        acc_out   : out acc_array_t;             -- array de N_MAC × 32 bits
        valid_out : out std_logic                -- comun a todas (avanzan en lockstep)
    );
end entity mac_array;

architecture rtl of mac_array is

    -- Señales internas para conectar los valid_out de cada mac_unit
    -- (todas seran iguales porque avanzan en lockstep)
    type valid_array_t is array(0 to N_MAC-1) of std_logic;
    signal valid_arr : valid_array_t;

begin

    ---------------------------------------------------------------------------
    -- GENERAR N_MAC instancias de mac_unit
    --
    -- Cada mac_unit recibe:
    --   a_in:      la MISMA activacion (broadcast)
    --   b_in:      SU propio peso (b_in(i))
    --   bias_in:   SU propio bias (bias_in(i))
    --   valid_in:  la MISMA señal de control
    --   load_bias: la MISMA señal
    --   clear:     la MISMA señal
    --
    -- Cada mac_unit produce:
    --   acc_out:   SU propio acumulador (acc_out(i))
    --   valid_out: SU propio valid (todos iguales)
    ---------------------------------------------------------------------------
    gen_macs : for i in 0 to N_MAC-1 generate
        u_mac : entity work.mac_unit
            port map (
                clk       => clk,
                rst_n     => rst_n,
                a_in      => a_in,          -- broadcast: misma para todos
                b_in      => b_in(i),       -- peso propio de este filtro
                bias_in   => bias_in(i),    -- bias propio de este filtro
                valid_in  => valid_in,       -- compartido
                load_bias => load_bias,      -- compartido
                clear     => clear,          -- compartido
                acc_out   => acc_out(i),     -- acumulador propio
                valid_out => valid_arr(i)    -- valid propio (todos iguales)
            );
    end generate gen_macs;

    -- valid_out comun: tomamos el del primer mac_unit
    -- (todos son iguales porque avanzan en lockstep)
    valid_out <= valid_arr(0);

end architecture rtl;
