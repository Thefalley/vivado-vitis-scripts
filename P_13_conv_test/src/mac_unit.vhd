-------------------------------------------------------------------------------
-- mac_unit.vhd — Unidad MAC (Multiply-Accumulate) para DPU INT8
-------------------------------------------------------------------------------
--
-- QUE HACE:
--   Multiplica una activacion por un peso y acumula el resultado.
--   Es la operacion basica de una convolucion: acc += x * w
--
-- COMO LO HACE:
--   En 2 etapas de pipeline (2 ciclos de reloj por operacion):
--
--   ETAPA 1 (ciclo N):
--     Recibe a_in y b_in
--     Calcula product_r = a_in * b_in
--     Registra el resultado en product_r (flip-flop)
--     Tambien registra las senales de control (valid, bias, clear)
--
--   ETAPA 2 (ciclo N+1):
--     Lee product_r del registro (ya estable)
--     Hace la suma: acc_r = acc_r + product_r
--     Registra el resultado en acc_r (flip-flop)
--
--   POR QUE 2 ETAPAS:
--     Si hicieramos multiplicar + sumar en 1 solo ciclo, el path
--     combinacional seria demasiado largo para 100 MHz.
--     Separando en 2 etapas, cada etapa tiene 1 sola operacion
--     pesada entre registros.
--
-- ANCHOS DE BITS:
--
--   Señal       Tipo              Bits  Rango             Motivo
--   ---------   ---------------   ----  ----------------  -------------------------
--   a_in        signed            9     -255 .. 255       x(int8) - x_zp(int8) = int9
--   b_in        signed            8     -128 .. 127       peso int8 (w_zp=0 siempre)
--   product_r   signed            17    -32640 .. 32385   int9 × int8 = int17
--   acc_r       signed            32    full int32        acumulador de la conv
--   bias_in     signed            32    full int32        valor inicial del acumulador
--
--   El acumulador (32 bits) puede representar hasta 2,147,483,647.
--   Con C_IN=1024, K=3x3: max |acc| ≈ 300,000,000 (29 bits). Cabe.
--
-- CONTROL:
--   clear     = '1' → pone acc_r a 0 (inicio de nuevo pixel)
--   load_bias = '1' → carga bias_in como valor inicial de acc_r
--   valid_in  = '1' → multiplica a_in × b_in y acumula
--   (prioridad: clear > load_bias > valid_in)
--
-- LATENCIA: 2 ciclos desde valid_in hasta que acc_r se actualiza.
-- THROUGHPUT: 1 MAC por ciclo (pipeline), si se alimenta cada ciclo.
--             Pero el conv_engine deja 4+ ciclos entre MACs (por DDR).
--
-- EN HARDWARE:
--   Etapa 1 (multiplicacion): 1 DSP48E1 del XC7Z020 (25×18 bits, sobra)
--   Etapa 2 (suma): carry chain de 32 bits (~1.5 ns, cabe en 10 ns)
--
-------------------------------------------------------------------------------

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity mac_unit is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;   -- reset activo bajo (0 = reset)

        -- Datos de entrada
        a_in      : in  signed(8 downto 0);   -- activacion shifted: 9 bits signed
                                               -- viene de: x_int8 - x_zp
                                               -- rango: -255 a 255
        b_in      : in  signed(7 downto 0);   -- peso: 8 bits signed
                                               -- viene de: weight_buf (BRAM)
                                               -- rango: -128 a 127
        bias_in   : in  signed(31 downto 0);  -- bias: 32 bits signed
                                               -- viene de: bias_buf (BRAM)
                                               -- se carga UNA vez por pixel

        -- Señales de control (cada una dura 1 ciclo de reloj)
        valid_in  : in  std_logic;   -- '1' = hay datos nuevos, multiplicar y acumular
        load_bias : in  std_logic;   -- '1' = cargar bias como valor inicial del acumulador
        clear     : in  std_logic;   -- '1' = poner acumulador a 0

        -- Salida
        acc_out   : out signed(31 downto 0);  -- acumulador actual (32 bits)
        valid_out : out std_logic             -- '1' = se acaba de acumular un nuevo valor
    );
end entity mac_unit;

architecture rtl of mac_unit is

    -- Forzar uso de DSP48E1 para la multiplicacion
    attribute use_dsp : string;

    -- CRITICAL: impedir que phys_opt mueva registros dentro/fuera del DSP.
    -- Sin esto, Vivado hace "DSP Register push" (288 regs para 32 MACs)
    -- que desincroniza product_r con s1_valid, corrompiendo la acumulacion.
    attribute dont_touch : string;

    ---------------------------------------------------------------------------
    -- REGISTROS DE ETAPA 1 (entre la entrada y la multiplicacion)
    ---------------------------------------------------------------------------
    signal product_r    : signed(16 downto 0);
    attribute use_dsp of product_r : signal is "yes";
    attribute dont_touch of product_r : signal is "true";
                                                 -- rango: -32640 a 32385
    signal s1_valid     : std_logic;
    signal s1_bias      : std_logic;
    signal s1_clear     : std_logic;
    signal s1_bias_val  : signed(31 downto 0);
    attribute dont_touch of s1_valid    : signal is "true";
    attribute dont_touch of s1_bias     : signal is "true";
    attribute dont_touch of s1_clear    : signal is "true";
    attribute dont_touch of s1_bias_val : signal is "true";

    ---------------------------------------------------------------------------
    -- REGISTROS DE ETAPA 2 (el acumulador y su valid)
    ---------------------------------------------------------------------------
    signal acc_r        : signed(31 downto 0);   -- acumulador: 32 bits signed
    signal valid_r      : std_logic;             -- '1' cuando acc_r se acaba de actualizar

begin

    ---------------------------------------------------------------------------
    -- ETAPA 1: MULTIPLICACION
    --
    -- En cada flanco de reloj:
    --   product_r <= a_in × b_in
    --
    -- La multiplicacion signed(9) × signed(8) produce signed(17).
    -- VHDL calcula el ancho automaticamente: 9 + 8 = 17 bits.
    -- No hay cast, no hay truncacion, no hay ambiguedad.
    --
    -- Las señales de control se copian a registros s1_* para
    -- que lleguen a la etapa 2 sincronizadas con el producto.
    ---------------------------------------------------------------------------
    p_etapa1 : process(clk)
    begin
        if rising_edge(clk) then
        if rst_n = '0' then
            -- Reset sincrono (necesario para inferir DSP48E1)
            product_r   <= (others => '0');
            s1_valid    <= '0';
            s1_bias     <= '0';
            s1_clear    <= '0';
            s1_bias_val <= (others => '0');

        else
            -- Multiplicar: signed 9 × signed 8 = signed 17
            -- En FPGA esto usa 1 DSP48E1 (cabe en 25×18)
            product_r   <= a_in * b_in;

            -- Pipelinear control (llegan a etapa 2 en el ciclo siguiente)
            s1_valid    <= valid_in;
            s1_bias     <= load_bias;
            s1_clear    <= clear;
            s1_bias_val <= bias_in;
        end if;
        end if;
    end process p_etapa1;

    ---------------------------------------------------------------------------
    -- ETAPA 2: ACUMULACION
    --
    -- En cada flanco de reloj, segun la señal de control:
    --
    --   s1_clear = '1':  acc_r <= 0
    --     Se usa al inicio de cada pixel nuevo.
    --
    --   s1_bias = '1':   acc_r <= bias_in
    --     Se usa justo despues del clear para cargar el bias.
    --     El bias es el valor inicial del acumulador (no 0).
    --
    --   s1_valid = '1':  acc_r <= acc_r + product_r (sign-extended a 32 bits)
    --     Se usa para cada paso MAC (27 veces para kernel 3×3 con 3 canales).
    --     resize(product_r, 32) extiende el signo de 17 a 32 bits.
    --     En FPGA esto es un sumador de 32 bits (carry chain).
    --
    -- PRIORIDAD: clear > bias > valid
    --   Si clear y valid llegan al mismo tiempo, clear gana.
    --   Esto no deberia pasar en operacion normal (la FSM los separa).
    ---------------------------------------------------------------------------
    p_etapa2 : process(clk)
    begin
        if rising_edge(clk) then
        if rst_n = '0' then
            acc_r   <= (others => '0');
            valid_r <= '0';

        else
            if s1_clear = '1' then
                -- Reset acumulador a 0
                acc_r   <= (others => '0');
                valid_r <= '0';

            elsif s1_bias = '1' then
                -- Cargar bias como valor inicial
                -- (bias es int32, se copia directamente)
                acc_r   <= s1_bias_val;
                valid_r <= '0';

            elsif s1_valid = '1' then
                -- Acumular: acc += product
                -- resize extiende signo de 17 bits a 32 bits
                -- Ejemplo: product_r = -1536 (17 bits)
                --   resize a 32 bits: 0xFFFFF9FF...no, veamos:
                --   -1536 en 17 bits: 1_1111_1001_1100_0000
                --   resize a 32 bits: 1111...1111_1001_1100_0000 = -1536
                --   La suma: acc_r + (-1536) funciona correctamente
                acc_r   <= acc_r + resize(product_r, 32);
                valid_r <= '1';

            else
                -- Sin operacion este ciclo
                valid_r <= '0';
            end if;
        end if;
        end if;
    end process p_etapa2;

    ---------------------------------------------------------------------------
    -- SALIDAS (cables directos a los registros, sin logica combinacional)
    ---------------------------------------------------------------------------
    acc_out   <= acc_r;
    valid_out <= valid_r;

end architecture rtl;
