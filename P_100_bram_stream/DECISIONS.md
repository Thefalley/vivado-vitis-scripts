# P_100_bram_stream — Informe de decisiones

**Fecha:** 2026-04-11
**Target:** ZedBoard (xc7z020clg484-1), Vivado 2025.2.1
**Objetivo:** Crear un módulo AXI-Stream que almacene datos en una **Block RAM realmente inferida** (no LUTRAM, no slices), con la misma "estética" que la infra de DMA del repo (HsSkidBuf_dest como skid buffer AXI-Stream), compilarlo en el servidor remoto y verificar mediante `report_utilization` que Vivado sintetiza efectivamente una BRAM.

## 1. Resultado (TL;DR)

✅ **PASS a la primera iteración.** Una sola RAMB36E1 usada, cero memoria distribuida.

| Recurso | Usado | Disponible | % |
|---|---:|---:|---:|
| **Block RAM Tile** | **1** | 140 | **0.71%** |
| RAMB36E1 | 1 | — | — |
| RAMB18E1 | 0 | — | — |
| LUT as Memory | **0** | 17400 | 0.00% |
| LUT as Logic | 80 | 53200 | 0.15% |
| Slice Registers | 171 | 106400 | 0.16% |
| DSPs | 0 | 220 | 0.00% |
| Bonded IOB | 72 | 200 | 36.00% |
| BUFG | 1 | 32 | 3.13% |

Desglose de primitivos (tabla 7 del reporte):

```
FDRE     171   Flop & Latch
LUT3      82   LUT
IBUF      37   IO
OBUF      35   IO
LUT5      14   LUT
LUT6      12   LUT
LUT4       7   LUT
LUT2       6   LUT
RAMB36E1   1   Block Memory   <-- la BRAM que queríamos
LUT1       1   LUT
CARRY4     1   CarryLogic
BUFG       1   Clock
```

La presencia de **RAMB36E1 = 1** y **LUT as Memory = 0** confirma que el patrón VHDL usado se infiere como BRAM "dura" y no queda atrapado en LUTRAM.

## 2. Arquitectura

```
              +--------------+     +----------+     +--------------+
 s_axis ----> | HsSkidBuf    |---->|   FSM    |---->| HsSkidBuf    |----> m_axis
              |  dest (IN)   |     | + BRAM   |     |  dest (OUT)  |
              +--------------+     +----------+     +--------------+
                                        |
                                        v
                                  +-----------+
                                  |  bram_sp  |  1024 x 32 bits
                                  | (RAMB36)  |
                                  +-----------+
```

Flujo:
1. **Estado `S_WRITE`**: cada beat válido del `s_axis` se escribe en BRAM en `wr_addr = 0, 1, 2, ...`. Cuando llega el `tlast`, se latch-ea `count = wr_addr` y se pasa a `S_READ_ISSUE`.
2. **Estado `S_READ_ISSUE`**: se presenta la dirección `rd_addr` a la BRAM (1 ciclo de latencia, el `dout` estará disponible al ciclo siguiente).
3. **Estado `S_READ_WAIT`**: se presenta `wout_tvalid=1` con `wout_tdata = bram_dout`. Cuando el skid buffer de salida acepta (`wout_tready=1`), se avanza `rd_addr++` y se vuelve a `S_READ_ISSUE`. En el último beat (`rd_addr == count`) se asserta `wout_tlast=1` y se vuelve a `S_WRITE`.

## 3. Ficheros del proyecto

```
P_100_bram_stream/
├── DECISIONS.md             (este informe)
├── project.cfg              (metadatos del proyecto, mismo formato que P_1..P_13)
├── src/
│   ├── HsSkidBuf_dest.vhd   (copiado literal de P_3_stream_adder/src/)
│   ├── bram_sp.vhd          (wrapper de BRAM, patrón inferrable)
│   └── bram_stream.vhd      (top: skid IN + FSM + bram_sp + skid OUT)
├── tcl/
│   └── build_check.tcl      (script one-shot: create + synth + check)
└── build/                   (generado por Vivado; utilization.rpt copiado tras la ejecución)
```

Todo lo necesario vive **dentro de la carpeta P_100** (self-contained), así se puede `scp -r` al servidor y ejecutar sin depender de ningún TCL del directorio `tcl/` raíz del repo.

## 4. Decisiones de diseño

### 4.1 Patrón de inferencia de BRAM

El corazón de `bram_sp.vhd` es:

```vhdl
type ram_type is array (0 to (2**ADDR_WIDTH) - 1) of
    std_logic_vector(DATA_WIDTH - 1 downto 0);
signal ram : ram_type := (others => (others => '0'));

attribute ram_style : string;
attribute ram_style of ram : signal is "block";

process(clk)
begin
    if rising_edge(clk) then
        if we = '1' then
            ram(to_integer(unsigned(addr))) <= din;
        end if;
        dout <= ram(to_integer(unsigned(addr)));  -- read síncrono
    end if;
end process;
```

Puntos clave que lo hacen inferirse como BRAM (NO como LUTRAM):

1. **Lectura síncrona registrada**: `dout <= ram(addr)` dentro del bloque `rising_edge(clk)`. Una lectura asíncrona (`dout <= ram(addr)` fuera del process) se mapearía a LUTRAM o a un enorme mux de LUTs — Vivado **no puede** inferir BRAM con lectura combinacional en 7-series.
2. **Atributo `ram_style = "block"`** aplicado a la señal `ram`. Con `DEPTH=1024`, `DATA_WIDTH=32` (32 Kib totales) Vivado ya lo metería en BRAM de forma automática por tamaño, pero el atributo lo fuerza explícitamente y evita sorpresas si alguien baja `ADDR_WIDTH`.
3. **Puerto único** con mismo `addr` para lectura y escritura (single-port BRAM). En el FSM, escritura y lectura son **mutuamente exclusivas en el tiempo**, así que un único puerto es suficiente y encaja en una `RAMB36E1` en modo SP.
4. **Inicialización `(others => (others => '0'))`** en la declaración: BRAM en 7-series soporta inicialización en el bitstream. Esto no impide la inferencia (a veces Vivado rechaza `signal ram : ram_type;` sin inicializar si hay otras restricciones, pero aquí no era necesario — se añadió por claridad y reproducibilidad del estado post-reset).

### 4.2 Profundidad 1024 (ADDR_WIDTH=10)

- **Umbral de inferencia**: Vivado automáticamente promueve a BRAM cuando la memoria supera ~64 palabras (depende de versión y flags). Con 1024 quedamos lejos del umbral → decisión segura.
- **Encaje exacto en una RAMB36**: una `RAMB36E1` tiene 36 Kb; configurada como 1024×36 cabe justo. Usamos 32 bits de datos y 4 bits de paridad quedan sin usar (que es lo que hace `RAMB36E1 only: 1` en el reporte).
- **No es tan grande como para partirse en múltiples BRAMs**: mantiene el reporte limpio para este test.

Si en el futuro quisieras algo más pequeño (p.ej. 256 × 32 = 8 Kib), Vivado podría decidir usar una `RAMB18E1` o, peor, meterlo como LUTRAM. En ese caso el atributo `ram_style = "block"` sigue siendo la defensa.

### 4.3 Skid buffers en ambos lados

`HsSkidBuf_dest` (copiado literalmente desde `P_3_stream_adder/src/`) se usa sin modificar:

- **Input skid**: rompe el camino combinacional de `s_axis_tvalid`/`s_axis_tready` entre el DMA (o el testbench) y la lógica del FSM. Sin esto, la `tready` del DMA dependería combinacionalmente de la `we` de la BRAM, generando caminos largos y malos timings en impl.
- **Output skid**: hace lo mismo del lado `m_axis`. Además, provee 2 niveles de buffering, que ayudan a absorber la latencia de 1 ciclo de la BRAM si alguna vez se pipeline-a el camino de lectura para 1 word/ciclo (hoy está a 2 word/ciclo).
- `DEST_WIDTH = 2` con `s_hs_tdest <= "00"` en ambos lados: el skid buffer genérico exige `DEST_WIDTH > 0`, así que se ata a cero como hace P_3.

**Tradeoff consciente**: podría haber usado un wrapper sin `tdest` (refactor del skid buffer), pero preferí reutilizar tal cual el fichero del repo para mantener consistencia con la infra existente y no tocar nada de P_3/P_4 que ya está verificado en hardware.

### 4.4 FSM de 3 estados (2 ciclos por palabra en lectura)

`S_WRITE → S_READ_ISSUE → S_READ_WAIT → (loop)`.

Se decidió mantener la FSM **simple** en lugar de pipeline-ar para 1 word/ciclo. Razones:

- El objetivo del proyecto es **demostrar inferencia de BRAM**, no maximizar throughput.
- Pipeline full-throughput requiere:
  - Tracking de "in-flight reads" con un FIFO pequeño entre BRAM y skid,
  - O condicionar `rd_en` a `(not stage_valid) or skid_tready`,
  - O una valid-shift-register para absorber la latencia de 1 ciclo de BRAM.
- Con 2 ciclos por word tenemos **correctness garantizada**, sin riesgo de perder datos por backpressure mal manejada.
- La BRAM se infiere **igual** con cualquiera de los dos esquemas — Vivado no distingue si la lectura es cada 1 o cada 2 ciclos.

Si en el futuro necesitas el 100% de throughput, el refactor es localizado al process del FSM y al esquema del `rd_en` (no toca ni `bram_sp.vhd` ni los skid buffers).

### 4.5 No se añadió XDC

- No hay `constrs/*.xdc`. La sección `[constraints]` del `project.cfg` está vacía.
- Sólo corremos **síntesis**, no implementación física — los pines no necesitan estar asignados.
- Timing constraint en `clk` tampoco es necesaria para un synth report; Vivado avisa de reloj no restringido pero sintetiza igual.
- El day-1 goal era: **¿aparece o no aparece una RAMB36 en el reporte?** Sí.

Para hacer una implementación completa + bitstream más adelante haría falta:
1. Un `clock.xdc` con `create_clock -period 10 [get_ports clk]`,
2. O (más probable en la práctica) integrar `bram_stream` dentro de un Block Design con Zynq + DMA, al estilo de P_4.

## 5. Metodología de verificación

El script `tcl/build_check.tcl` hace todo en una sola invocación de Vivado:

1. `create_project` con `part=xc7z020clg484-1`, `target_language=VHDL`.
2. Añade los 3 fuentes en orden bottom-up.
3. `launch_runs synth_1 -jobs 4` + `wait_on_run synth_1`.
4. `open_run synth_1`.
5. Cuenta primitivos con `get_cells -hier -filter {REF_NAME == RAMB36E1}` (y RAMB18E1, y los 4 tipos de LUTRAM distribuida).
6. Escribe `report_utilization` a `build/utilization.rpt`.
7. Imprime `BRAM_CHECK: RAMB36E1=... RAMB18E1=...` y `LUTRAM_CHECK: ...`.
8. Sale con código `0` si `ramb36+ramb18 > 0`, con `2` si no se infirió ninguna BRAM.

Las líneas clave del output en la ejecución que pasó:

```
OK: synthesis complete
BRAM_CHECK: RAMB36E1=1 RAMB18E1=0
LUTRAM_CHECK: RAM32X1S=0 RAM64X1S=0 RAM128X1S=0 RAM256X1S=0
PASS: Block RAM inferred
```

Tiempos aproximados:
- `create_project` + add sources: ~3 s
- `launch_runs synth_1`: ~27 s (cpu=24 s, elapsed=27 s)
- `wait_on_run` total: ~40 s
- `open_run` + `report_utilization`: ~5 s
- **Total round trip desde `ssh` hasta exit**: ~90 segundos.

## 6. Ejecución en el servidor remoto

### 6.1 Infra remota

- **Host**: `DESKTOP-16QCK7N` (Windows 10 Pro) vía Tailscale (`100.73.144.105`)
- **User**: `jce03`
- **SSH key**: `~/.ssh/pc-casa`
- **Vivado**: `E:\vivado-instalado\2025.2.1\Vivado\bin\vivado.bat` (2025.2.1 — hay que tener `E:` montada, si no, `vivado` no aparece en PATH)
- **Proyecto remoto**: `C:\Users\jce03\Desktop\claude\vivado-server\P_100_bram_stream\`

### 6.2 Comandos usados

Copia:
```bash
scp -i ~/.ssh/pc-casa \
    /c/project/vivado/P_100_bram_stream/src/HsSkidBuf_dest.vhd \
    /c/project/vivado/P_100_bram_stream/src/bram_sp.vhd \
    /c/project/vivado/P_100_bram_stream/src/bram_stream.vhd \
    jce03@100.73.144.105:"C:/Users/jce03/Desktop/claude/vivado-server/P_100_bram_stream/src/"

scp -i ~/.ssh/pc-casa \
    /c/project/vivado/P_100_bram_stream/tcl/build_check.tcl \
    jce03@100.73.144.105:"C:/Users/jce03/Desktop/claude/vivado-server/P_100_bram_stream/tcl/"

scp -i ~/.ssh/pc-casa \
    /c/project/vivado/P_100_bram_stream/project.cfg \
    jce03@100.73.144.105:"C:/Users/jce03/Desktop/claude/vivado-server/P_100_bram_stream/"
```

Build + check:
```bash
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 \
    "cd /d C:\Users\jce03\Desktop\claude\vivado-server && \
     vivado -mode batch -nojournal -nolog \
     -source P_100_bram_stream/tcl/build_check.tcl"
```

Descarga del reporte:
```bash
scp -i ~/.ssh/pc-casa \
    jce03@100.73.144.105:"C:/Users/jce03/Desktop/claude/vivado-server/P_100_bram_stream/build/utilization.rpt" \
    /c/project/vivado/P_100_bram_stream/build/utilization.rpt
```

### 6.3 Gotchas encontrados

- **`mkdir` por SSH con Command Extensions**: `mkdir C:\path\subpath\leaf` a través de `ssh ... "mkdir ..."` **no** crea rutas anidadas de forma fiable. Solución: usar `powershell -NoProfile -Command "New-Item -ItemType Directory -Force -Path '...'"`.
- **Unidad `E:` no siempre montada**: el PATH del usuario remoto apunta a `E:\vivado-instalado\...` pero si `E:` es un disco externo que no está conectado, `vivado` desaparece del PATH — hay que asegurarse de que está enchufado antes de lanzar builds.
- **`vivado -version`**: devuelve `exit code 1` aunque imprima la versión correctamente. No es un error real, sólo comportamiento idiosincrático del `.bat`.
- **`where /R C:\ vivado.bat`**: ¡tardaba una eternidad! Mejor buscar en las carpetas candidatas concretas (`C:\Xilinx`, `D:\Xilinx`, `E:\Xilinx`, `C:\Program Files\Xilinx`, etc.) o directamente leer `%PATH%`.
- **`HS_TDATA_WIDTH` + `DEST_WIDTH`**: el `HsSkidBuf_dest` genérico exige `DEST_WIDTH > 0` porque hace `std_logic_vector(DEST_WIDTH - 1 downto 0)`. Con `DEST_WIDTH=2` y atando `s_hs_tdest <= "00"` funciona sin tocar el componente.

## 7. Cómo replicar el test

Desde el host local, asumiendo que el disco con Vivado está montado en el servidor:

```bash
# 1) Editar el código en local si quieres cambiar algo
# 2) Sincronizar al servidor
scp -i ~/.ssh/pc-casa /c/project/vivado/P_100_bram_stream/src/*.vhd \
    jce03@100.73.144.105:"C:/Users/jce03/Desktop/claude/vivado-server/P_100_bram_stream/src/"

# 3) Build + check
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 \
    "cd /d C:\Users\jce03\Desktop\claude\vivado-server && \
     vivado -mode batch -nojournal -nolog -source P_100_bram_stream/tcl/build_check.tcl"

# 4) Buscar la línea "BRAM_CHECK: RAMB36E1=N RAMB18E1=M" en el output
# 5) Si N+M == 0 → fallo, revisar coding style y ram_style attribute
```

Para re-ejecutar sobre una máquina "virgen", basta con hacer `scp -r` de toda la carpeta `P_100_bram_stream/` y lanzar el mismo `vivado -source ... build_check.tcl`. El script es idempotente (`create_project ... -force`).

## 8. Próximos pasos posibles

1. **Simulación funcional** — añadir `sim/bram_stream_tb.vhd` que escriba N valores, reciba los N mismos, y compruebe igualdad. Sin tb real, este proyecto sólo verifica "Vivado infiere BRAM", no "el módulo funciona".
2. **Integrar en un BD con DMA + Zynq** — como P_4. Meter `bram_stream` como IP custom, conectar `s_axis` al `MM2S` de un `axi_dma`, conectar `m_axis` al `S2MM` del mismo DMA, y probar desde bare-metal/Linux que `memcpy`+DMA viaja a través de la BRAM.
3. **Pipeline full-throughput en el path de lectura** — refactor localizado al FSM para emitir 1 word/ciclo (ver §4.4).
4. **Profundidad variable vía genérico** — ya está parametrizado por `ADDR_WIDTH` y `DATA_WIDTH`, sólo falta testearlo con otros tamaños para ver cómo cambia el mapping a RAMB36/RAMB18/múltiples BRAMs.
5. **Dual-port BRAM** — si en el futuro quieres hacer lectura y escritura simultáneas (por ejemplo para `ping-pong`), `bram_sp` → `bram_tdp` (true dual-port), con 2 puertos clk/we/addr/din/dout independientes. Vivado lo infiere también con un patrón parecido pero con dos `process` o dos ramas dentro del mismo process.

## 9. Referencias útiles

- **Xilinx UG901 (Vivado Synthesis Guide)** — capítulo "RAM HDL Coding Techniques" es la biblia para saber qué patrones infieren BRAM/LUTRAM/FIFOs. Cubre single-port, dual-port, ROM, inicialización, etc.
- **UG473 (7 Series Memory Resources)** — especificaciones físicas de `RAMB36E1`/`RAMB18E1`: configuraciones de anchura, latencia, modos SP/SDP/TDP.
- **`ram_style` attribute**: valores admitidos son `block`, `distributed`, `registers`, `ultra` (este último sólo UltraScale+). Para 7-series (ZedBoard) los relevantes son `block` y `distributed`.
- **Internal HsSkidBuf_dest** — ver `P_3_stream_adder/src/HsSkidBuf_dest.vhd` y cómo se usa en `stream_adder.vhd`. Fichero copiado literal aquí; si cambia la versión "canónica" en P_3, hay que resincronizar.

---

## 10. Sesión 2: full HW stack + iteración 2

Después del check estructural de §1, se montó el stack completo para ejecutar en placa real:

### 10.1 Simulación funcional (xsim)

**Fichero**: `sim/bram_stream_tb.vhd`. 64 words con patrón `0xDEAD0000 + i`, tlast en el último, `m_axis_tready='1'` fijo, captura con índice + comparación. Usa `std.env.finish` para terminar limpio.

**Gotcha**: `16#DEAD0000#` como literal entero desborda el `integer` de 32-bit signed de VHDL (max = 0x7FFFFFFF). Solución: `unsigned'(x"DEAD0000") + to_unsigned(i, DATA_WIDTH)`. Con `xvhdl -2008` para soporte de `finish`.

**Comando** (se ejecutó en servidor vía PowerShell para evitar el quoting de `cd` con `&` en cmd de OpenSSH Windows):

```powershell
Set-Location C:\...\P_100_bram_stream\sim_work
xvhdl.bat -2008 ..\src\HsSkidBuf_dest.vhd ..\src\bram_sp.vhd ..\src\bram_stream.vhd ..\sim\bram_stream_tb.vhd
xelab.bat -debug typical bram_stream_tb -s tb_snap
xsim.bat tb_snap -runall
```

**Resultado**:
```
Note: SIM PASS: 64 words round-tripped via BRAM
Time: 2045 ns
$finish called at time : 2045 ns
```

Verificación funcional completa: 64 words entran, 64 salen con los mismos valores. El FSM de 3 estados (`S_WRITE → S_READ_ISSUE → S_READ_WAIT`) funciona correctamente incluyendo la transición WRITE→READ tras `tlast`.

### 10.2 Block Design completo (Zynq + DMA + bram_stream)

**Ficheros nuevos**:
- `src/create_bd.tcl` — adaptado de `P_4_zynq_adder/src/create_bd.tcl` con dos cambios clave:
  1. **Sin AXI-Lite en bram_stream**: se elimina la conexión `axi_ic_gp0/M01_AXI → stream_adder_0/S_AXI` porque `bram_stream` no tiene S_AXI. El `axi_ic_gp0` se configura con `NUM_MI=1` (sólo al DMA).
  2. **Fuentes RTL**: `read_vhdl` de `HsSkidBuf_dest.vhd`, `bram_sp.vhd`, `bram_stream.vhd` (en ese orden para compilación bottom-up). La celda BD se instancia con `create_bd_cell -type module -reference bram_stream`, que es la forma de meter VHDL crudo directamente (sin empaquetar IP).
- `sw/bram_stream_test.c` — bare-metal: rellena 256 words en DDR con `PATTERN(i) = 0xDEAD0000 + i`, cache flush, lanza S2MM + MM2S, poll-wait, compara identidad. PASS si todos los 256 words coinciden.
- `sw/create_vitis.py` — adaptado de P_4: renombra platform a `bram_stream_platform`, app a `bram_stream_test`, y crea workspace + compila FSBL + app ELF.
- `sw/run.tcl` — xsct script que programa bitstream, carga FSBL, carga app, lee DDR por JTAG con `mrd` y compara identidad beat-por-beat. **No depende de UART** — todo por JTAG.
- `project.cfg` — reescrito a formato BD: `top = bram_stream_bd_wrapper`, `[sources] = src/create_bd.tcl`.

**Arquitectura del BD**:
```
Zynq PS ──M_AXI_GP0──┐
                    axi_ic_gp0 (1 master)──► axi_dma_0/S_AXI_LITE (@0x40400000)
                                             
         axi_dma_0/M_AXIS_MM2S ──► bram_stream_0/s_axis
         bram_stream_0/m_axis  ──► axi_dma_0/S_AXIS_S2MM
         
         axi_dma_0/M_AXI_MM2S ─┐
                              axi_ic_hp0 (2 slaves, 1 master)──► ps7/S_AXI_HP0 ──► DDR
         axi_dma_0/M_AXI_S2MM ─┘
```

Reloj único: `ps7/FCLK_CLK0 = 100 MHz`. Reset via `proc_sys_reset_0`. Interrupts del DMA agregados con `xlconcat` al `IRQ_F2P` del PS. `apply_bd_automation` externaliza DDR + FIXED_IO automáticamente.

### 10.3 Build end-to-end en servidor

Comandos ejecutados (todos en remoto vía SSH, usando los scripts comunes de `/c/project/vivado/tcl/`):

```bash
# 1) Block Design
vivado -mode batch -nojournal -nolog \
    -source tcl/create_bd_project.tcl \
    -tclargs P_100_bram_stream bram_stream xc7z020clg484-1 src/create_bd.tcl
# → BD creado, validated, wrapper generado. ~2.5 min

# 2) Synthesis
vivado -mode batch -nojournal -nolog \
    -source tcl/synthesize.tcl \
    -tclargs P_100_bram_stream/build/bram_stream.xpr
# → 57 Infos, 131 Warnings, 0 Errors. 47 s CPU, 7 min elapsed. OK: Synthesis complete

# 3) Implementation + Bitstream
vivado -mode batch -nojournal -nolog \
    -source tcl/gen_bitstream.tcl \
    -tclargs P_100_bram_stream/build/bram_stream.xpr
# → 0 Errors, 0 Critical Warnings. ~3.5 min total.
# → bram_stream_bd_wrapper.bit generado

# 4) Export hardware → XSA
vivado -mode batch -nojournal -nolog \
    -source tcl/export_hw.tcl \
    -tclargs P_100_bram_stream/build/bram_stream.xpr \
             P_100_bram_stream/build/bram_stream.xsa
# → XSA generado. ~1 min

# 5) Vitis: platform + FSBL + app
"E:\vivado-instalado\2025.2.1\Vitis\bin\vitis.bat" -s sw/create_vitis.py \
    build/bram_stream.xsa vitis_ws sw/bram_stream_test.c
# → bram_stream_platform built (FSBL 91 KB)
# → bram_stream_test.elf built (38423 text + 1576 data + 24824 bss bytes)
# ~8 min total (primera vez; subsecuentes sólo re-compilan app)
```

### 10.4 Utilización post-implementación (BD completo)

```
2. Memory
+-------------------+------+-------+-----------+-------+
|     Site Type     | Used | Fixed | Available | Util% |
+-------------------+------+-------+-----------+-------+
| Block RAM Tile    |    6 |     0 |       140 |  4.29 |
|   RAMB36/FIFO     |    5 |     0 |       140 |  3.57 |
|     RAMB36E1 only |    5 |       |           |       |
|   RAMB18          |    2 |     0 |       280 |  0.71 |
|     RAMB18E1 only |    2 |       |           |       |
+-------------------+------+-------+-----------+-------+

Primitives (top 10):
  SRL16E:    186   Distributed Memory (shift-register FIFOs dentro del DMA)
  FDSE:      120
  CARRY4:    118
  LUT1:       86
  SRLC32E:    85   Distributed Memory
  FDCE:       69
  FDPE:       33
  RAMD32:     28   Distributed Memory
  RAMS32:      8   Distributed Memory
  RAMB36E1:    5   Block Memory
  RAMB18E1:    2   Block Memory
  PS7:         1   Zynq PS hard block
  BUFG:        1
```

Desglose de BRAMs en el BD completo:
- **1 RAMB36E1** pertenece a `bram_stream_0/bram_inst/ram` (nuestra BRAM, 1024×32).
- **4 RAMB36E1 + 2 RAMB18E1** son FIFOs internos del `axi_dma_0` (DataMover MM2S/S2MM — DMA buffers para desacoplar AXI-MM de AXI-Stream).

Comprobación independiente: síntesis standalone de `bram_stream` (sin DMA, §1) reporta exactamente **1 RAMB36E1, 0 LUT as Memory**. Consistencia confirmada.

### 10.5 Programación en HW — BLOQUEADA

`xsct` conecta correctamente al `hw_server` local pero `targets` devuelve vacío:

```
INFO: hw_server application started
>>> Listing targets ...
RAW_TARGETS:
FAIL_FILTER: no targets found with ...  available targets: none
```

Diagnóstico: no hay cable JTAG detectado. Causas probables (cualquier combinación):
1. La ZedBoard no está conectada al servidor por USB (puerto PROG).
2. La placa está apagada.
3. El driver de cable Digilent o Xilinx no está cargado.
4. Alguien la tenía enchufada a otra máquina.

**Sin conexión física no puedo proceder.** El resto del stack está listo:

```
P_100_bram_stream/
├── build/
│   ├── bram_stream.xpr                            (proyecto Vivado)
│   ├── bram_stream.xsa                            (export hw platform)
│   └── bram_stream.runs/impl_1/
│       └── bram_stream_bd_wrapper.bit             (BITSTREAM)
├── vitis_ws/
│   ├── bram_stream_platform/
│   │   └── zynq_fsbl/build/fsbl.elf               (FSBL)
│   └── bram_stream_test/
│       └── build/bram_stream_test.elf             (APP)
└── sw/
    └── run.tcl                                    (xsct script)
```

**Para lanzar cuando la placa esté conectada** (comando único):
```bash
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 \
    "cd /d C:\Users\jce03\Desktop\claude\vivado-server\P_100_bram_stream && \
     \"E:\vivado-instalado\2025.2.1\Vitis\bin\xsct.bat\" sw/run.tcl \
     build/bram_stream.runs/impl_1/bram_stream_bd_wrapper.bit \
     vitis_ws/bram_stream_test/build/bram_stream_test.elf \
     vitis_ws/bram_stream_platform/zynq_fsbl/build/fsbl.elf"
```

El `run.tcl` programa el bitstream, carga FSBL + app, espera 8 s, lee SRC (`0x01000000`) y DST (`0x01100000`) vía JTAG y compara beat por beat. Debe imprimir `RESULT: PASS (256/256 words OK)`.

## 11. Iteración 2 — bram_chain: 2 BRAMs en serie

Petición explícita: _"2 blockram en secuencial con backpressure, así hacemos como una FIFO, es como retardar una señal"_.

### 11.1 Diseño

Wrapper `bram_chain` que instancia **dos `bram_stream` cascadeadas**:

```
s_axis → [bram_stream u1] → mid_* → [bram_stream u2] → m_axis
```

Ambas instancias tienen sus propios skid buffers in/out y sus propias BRAMs. La backpressure se propaga de forma natural por el canal del medio (`mid_tvalid/tready`): cuando `u2` está en fase de lectura/replay su `s_axis_tready` baja → `u1` no puede avanzar su replay → `u1.m_axis_tready=0` estanca al upstream. Todo el chain se sincroniza sin control explícito.

Efecto end-to-end: cada word de `s_axis` se almacena en BRAM1, se replay-a a BRAM2, se replay-a a `m_axis`. **Es un delay line con dos BRAMs**, con profundidad efectiva = DEPTH1 + DEPTH2 = 2048 words.

**NO es un FIFO verdadero** (sin punteros concurrentes read/write independientes). Es un "batch delay": recibe N words, espera a tener todos, luego los reproduce. Si se quisiera un FIFO clásico con rd/wr concurrentes habría que escribir un módulo nuevo (true dual-port BRAM con dos punteros, ver §8.5). Este diseño es más sencillo y cumple con la descripción del usuario: "retardar una señal".

### 11.2 Resultado estructural

Script: `tcl/build_check_chain.tcl` (análogo al `build_check.tcl` de iteración 1).

```
BRAM_CHECK_CHAIN: RAMB36E1=2 RAMB18E1=0
PASS: 2 Block RAMs inferred for bram_chain

Memory:
  Block RAM Tile:    2 /140   (1.43%)
  RAMB36E1 only:     2
  RAMB18:            0

Primitives:
  FDRE:      340   (doble que iteración 1: 2 × 171 skid+FSM)
  LUT3:      164
  RAMB36E1:    2   <-- 2 Block RAMs, uno por bram_stream
  FDSE:        2
  CARRY4:      2
  LUT1:        1
```

Dos `RAMB36E1` inferidas, cero LUT as Memory. Síntesis limpia, 0 errores, 0 warnings críticos.

### 11.3 Ficheros añadidos

```
P_100_bram_stream/
├── src/
│   └── bram_chain.vhd                             (wrapper de 2 bram_stream)
├── tcl/
│   └── build_check_chain.tcl                      (synth + check)
└── build_chain/                                   (proyecto Vivado generado)
    └── utilization_chain.rpt
```

### 11.4 Próximo paso (pendiente)

Para probar la iteración 2 en HW: crear un `create_bd_chain.tcl` (igual que `create_bd.tcl` pero referenciando `bram_chain` en lugar de `bram_stream`) y repetir synth + impl + bitstream + vitis + xsct. Esto son otros ~15 min de build. Lo dejo preparado para una iteración 3 si se quiere ejecutar.

Alternativamente, si el interés real es un **FIFO verdadero** (no delay line batch), el camino sería escribir un `bram_fifo.vhd` con:
- True dual-port BRAM (`bram_tdp.vhd`): port A escribe, port B lee, clocks compartidos.
- Punteros `wr_ptr`, `rd_ptr`, contador `occupancy`.
- Flags `full`, `empty`.
- Handshake AXI-Stream con `tvalid = not empty`, `tready = not full`.

Ese sería el **iteración 3** si se decide ir por ahí.

