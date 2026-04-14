# Auditoría de `variable`s en el RTL del DPU

Las variables en VHDL sintetizan, pero son peligrosas porque:
- Se actualizan **inmediatamente** dentro del proceso (no en el siguiente flanco)
- Si se **leen antes de escribir** en algún camino → inferencia de latch/FF espurio
- Si se usan para "pasar estado entre ciclos" → comportamiento sim ≠ synth

Regla segura: **toda variable debe escribirse antes de leerse en cada invocación del proceso**. Si es así, sintetiza como expresión combinacional (equivalente a inlinearla).

## Inventario (DPU core)

### `conv_engine_v3.vhd` (5 variables — todas en `p_fsm`)

| # | Variable | Tipo | Líneas decl. | Declaración |
|---|---|---|---|---|
| 1 | `v_ih` | signed(10 downto 0) | 391 | `variable v_ih : signed(10 downto 0);` |
| 2 | `v_iw` | signed(10 downto 0) | 392 | — |
| 3 | `v_h_dim` | signed(10 downto 0) | 393 | — |
| 4 | `v_w_dim` | signed(10 downto 0) | 394 | — |
| 5 | **`v_limit`** | unsigned(9 downto 0) | 395 | **el nuestro** |

### Análisis uno a uno

#### ✅ `v_h_dim`, `v_w_dim` (`CALC_HOUT_1`, líneas 459-468)
```vhdl
v_h_dim := signed('0' & std_logic_vector(cfg_h_in))
         + signed('0' & std_logic_vector(pad_top_val))
         + signed('0' & std_logic_vector(pad_bottom_val))
         - signed('0' & std_logic_vector(kh_size));
v_w_dim := ...
h_dim_r <= unsigned(v_h_dim(9 downto 0));
w_dim_r <= unsigned(v_w_dim(9 downto 0));
```
**Patrón:** escribe → escribe → lee → lee en el mismo estado. **SAFE** — combinacional puro, equivalente a inlinear la suma.

#### ✅ `v_ih`, `v_iw` (`MAC_PAD_REG`, líneas 766-770)
```vhdl
v_ih := ih_base_r + signed('0' & std_logic_vector(kh));
v_iw := iw_base_r + signed('0' & std_logic_vector(kw));
if v_ih < 0 or v_ih >= signed('0' & std_logic_vector(cfg_h_in))
   or v_iw < 0 or v_iw >= signed('0' & std_logic_vector(cfg_w_in)) then
    pad_saved <= '1';
else
    pad_saved <= '0';
end if;
```
**Patrón:** escribe → escribe → lee en condición, SAFE — combinacional.

#### ⚠️ `v_limit` (`WL_NEXT`, líneas 647-653) — **LA DEL FIX**
```vhdl
if (cfg_c_in - ic_tile_base) < cfg_ic_tile_size then
    v_limit := cfg_c_in - ic_tile_base;
else
    v_limit := cfg_ic_tile_size(9 downto 0);
end if;
ic_in_tile_limit <= v_limit;
```
**Patrón:** if/else cubre los dos caminos (ambos escriben), luego se lee. SAFE en principio.

**Pero hay un matiz:** `v_limit` es una **variable declarada en el proceso**, no en la arquitectura. Variables declaradas en procesos **retienen su valor entre invocaciones** del proceso salvo que se inicialicen explícitamente cada vez. En la práctica, cada ciclo de reloj invoca el proceso una vez; si el camino de ejecución NO llega al estado WL_NEXT, `v_limit` no se toca, mantiene el valor anterior. En esos ciclos **no hay lectura** de `v_limit`, así que no importa.

Pero es un **anti-patrón de estilo RTL**: mezclar variable + signal en un proceso clocked hace el código más difícil de razonar. Sería más limpio computar el valor directamente en la asignación del signal:
```vhdl
if (cfg_c_in - ic_tile_base) < cfg_ic_tile_size then
    ic_in_tile_limit <= cfg_c_in - ic_tile_base;
else
    ic_in_tile_limit <= cfg_ic_tile_size(9 downto 0);
end if;
```

Esto elimina la variable y deja todo en signals, patrón inequívoco.

### `conv_engine_v2.vhd` (5 variables, mismas que v3 — **NO INTERESAN** porque no se usa)

### `conv_engine.vhd` v1 (4 variables — sin v_limit, sin tiling — **NO INTERESA**)

### `conv_test_wrapper.vhd` (2 variables, `v_addr`)
- En `p_axi_wr` (línea 333) y `p_axi_rd` (línea 392)
- Escritas con `s_axi_awaddr`/`s_axi_araddr` inmediatamente antes del `case`
- **SAFE** — combinacional intermedia pura

### `mul_s32x32_pipe.vhd` (6 variables)
- Usadas como intermedios del pipeline de 5 stages
- Escritas y leídas en cada ciclo de cada etapa
- **SAFE** — patrón standard

### `requantize.vhd` (3 variables + 2 en función)
- `shift_amount`, `shifted_full` en `p_etapa7`: escritas antes de leer. **SAFE**
- `with_zp` en `p_etapa8`: escrita antes de leer. **SAFE**
- `result`, `pos` en `make_round_val` (función pura): inicializada + bucle. **SAFE**

## Conclusión del audit

**Ninguna variable es causa del bug**. Todas siguen el patrón seguro (escribir-antes-de-leer). La variable más sospechosa era `v_limit` pero su uso es textbook-correct.

El bug de HW NO viene de las variables. Viene de:

### El absorbed-DSP issue

```
Vivado DSP Report:
  register tile_filter_stride_reg is absorbed into DSP wload_addr_r0.
  operator tile_filter_stride0  is absorbed into DSP wload_addr_r0.
```

Vivado empaquetó la multiplicación `ic_in_tile_limit × kk_reg` + suma `wload_addr_r + tile_filter_stride` en **un solo DSP48E1** usando el patrón `A + B × C`:
- A = `wload_addr_r`
- B = `ic_in_tile_limit`
- C = `kk_reg`
- P = A + B×C → se reasigna a `wload_addr_r`

El registro `tile_filter_stride` visible en el RTL **desapareció** — su valor vive dentro del **MREG** interno del DSP. Dos drivers FSM (`CALC_TILE_STRIDE` + `WL_STRIDE`) escriben al mismo registro, pero al absorberlo en el DSP, el enable/mux del driver nuevo (WL_STRIDE) puede haberse perdido.

**Evidencia circunstancial:** los errores HW son **idénticos** antes y después del fix (31, 478, 1735, 1864) → el comportamiento HW efectivo no cambió → WL_STRIDE no llega al DSP.

## Fix propuesto

Reemplazar el registro por una señal **combinacional** — Vivado puede seguir empaquetándolo en DSP pero ya no habrá ambigüedad de drivers:

```vhdl
-- ELIMINAR:
signal tile_filter_stride : unsigned(19 downto 0);
-- ELIMINAR estado WL_STRIDE y el estado CALC_TILE_STRIDE si solo escribía esto.

-- AÑADIR (fuera del proceso, continuous assign combinacional):
signal tile_filter_stride : unsigned(19 downto 0);
tile_filter_stride <= resize(ic_in_tile_limit * kk_reg, 20);
```

Así:
- No hay registro que absorber con "semántica de múltiples drivers"
- El DSP puede seguir packaging `A + B*C` con B=ic_in_tile_limit, C=kk_reg
- En cada ciclo la señal refleja el valor correcto del tile (porque ic_in_tile_limit es registrado y estable por tile)
- Es el patrón canónico VHDL/Verilog para operaciones DSP-fused

**Coste:** 0 ciclos (elimina el estado WL_STRIDE que añadió latencia). La multiplicación 10×20 es combinacional pero cabe en el slack de timing actual (+0.609 ns de WNS).

Si esto no cuadra con el esquema "1 mult por ciclo" de diseño, alternativa: mantener el registro pero usar `attribute keep = "true"` para prevenir absorción:

```vhdl
attribute keep : string;
attribute keep of tile_filter_stride : signal is "true";
```

Esto fuerza a Vivado a mantener el registro user-visible fuera del DSP, con sus dos drivers FSM explícitos.
