# Estudio de factibilidad: conv_engine con AXI-Stream directo (sin BRAM intermedia)

> Fecha: 2026-04-11
> Target: ZedBoard (xc7z020clg484-1), 140 BRAM36 disponibles
> Referencia: conv_engine_v3.vhd (P_13), conv_stream_wrapper.vhd (P_14)

---

## 1. Analisis del patron de acceso actual (conv_engine_v3)

### 1.1 Lectura de pesos (WL_EMIT / WL_WAIT / WL_CAPTURE)

Los pesos se leen **secuencialmente** desde DDR al `weight_buf` (BRAM interna de
32 KB). El orden de lectura es:

```
para cada i = 0..31 (oc dentro del tile):
  para cada kh = 0..kh_size-1:
    para cada kw = 0..kw_size-1:
      para cada j = 0..ic_in_tile_limit-1:
        leer DDR[base + offset]     -- stride 1 en j, saltos en kw/kh/i
```

Dentro de cada bloque (i, kh, kw), los bytes j se leen con **stride 1** (direcciones
consecutivas). Los saltos ocurren al cambiar kw/kh/i (skip de `c_in - ic_tile_size`
bytes). Total de bytes por tile: `N_MAC * ic_tile_size * kh * kw`.

**Conclusion:** La lectura de pesos es esencialmente secuencial con saltos
predecibles. Compatible con streaming.

### 1.2 Lectura de activaciones (MAC_EMIT / MAC_WAIT_DDR / MAC_CAPTURE)

Para cada pixel de salida (oh, ow), para cada ic_tile, el MAC loop lee:

```
para cada kh = 0..kh_size-1:
  para cada kw = 0..kw_size-1:
    para cada ic = 0..ic_in_tile_limit-1:
      act_addr = act_pixel_base + ic * hw_reg + kh * w_in + kw
```

Esto es **acceso random**. Para un kernel 3x3, un solo pixel lee 9 posiciones
espaciales, cada una separada por `w_in` en la dimension vertical y por 1 en la
horizontal. Los offsets para un pixel (oh=0, ow=0) con pad=1, stride=1 son:

```
Posicion (kh, kw) -> offset desde pixel base
(0,0) -> 0
(0,1) -> 1
(0,2) -> 2
(1,0) -> w_in
(1,1) -> w_in + 1
(1,2) -> w_in + 2
(2,0) -> 2*w_in
(2,1) -> 2*w_in + 1
(2,2) -> 2*w_in + 2
```

Cada posicion se multiplica por todos los canales (ic loop), y el canal avanza
con stride `hw_reg = h_in * w_in`.

**Crucialmente:** entre pixels adyacentes HAY SOLAPAMIENTO. El pixel (0,1) comparte
6 de las 9 posiciones espaciales con el pixel (0,0). Los datos NO se pueden
consumir y descartar despues de un solo pixel.

### 1.3 Lecturas por pixel

Para kernel 3x3 con ic_tile_size = T:

- Lecturas de activacion por pixel: `3 * 3 * T` = `9T`
- Cada lectura toma 5-7 ciclos (PAD_REG + WLOAD*32 + EMIT + WAIT + CAPTURE + FIRE)
- En realidad el cuello de botella es el WLOAD: 32 ciclos para cargar los 32 pesos
  del MAC array desde weight_buf, por cada posicion (kh, kw, ic)
- Total por pixel por ic_tile: ~`9 * T * 35` ciclos (aproximado)

### 1.4 Escritura de output (RQ_EMIT / RQ_CAPTURE)

La escritura es **secuencial**: 32 bytes por pixel, cada uno separado por
`hw_out_reg` en DDR (layout CHW). Esto es compatible con streaming si se
reorganiza a HWC, o si el DMA acepta scatter.

---

## 2. Analisis del handshake AXI-Stream (HsSkidBuf_dest)

El skid buffer de P_102 implementa un buffer de 1 posicion con backpressure
completo (tvalid/tready). Latencia: 1 ciclo de registro en el path directo,
+1 ciclo si hay conflicto (skid activo).

Esto es el patron estandar para interfaces AXI-Stream. Cualquier solucion
streaming necesitaria este tipo de handshake en las interfaces.

---

## 3. Evaluacion de los tres escenarios

### Escenario A: Stream de pesos solamente

**Idea:** Reemplazar `weight_buf` con un AXI-Stream input. Los pesos llegan
por DMA directamente al conv_engine.

**Problema fundamental: los pesos se RE-LEEN para cada pixel.**

El conv_engine_v3 carga los pesos del tile UNA VEZ en `weight_buf` (estados
WL_*) y luego los reutiliza para TODOS los pixels (h_out * w_out). En el MAC
loop, el peso se lee de `weight_buf` con acceso random:

```vhdl
-- MAC_WLOAD_CAP:
mac_b(wload_cnt) <= wb_dout;
wload_addr_r <= wload_addr_r + tile_filter_stride;
```

Cada paso MAC lee 32 pesos (uno por canal de salida) con stride
`tile_filter_stride`, que es un patron de acceso random dentro del buffer.

Para reemplazar esto con streaming, se necesitaria:

1. **Replay buffer:** Guardar los pesos del tile y re-leerlos para cada pixel.
   Esto ES exactamente lo que ya hace `weight_buf`. No ganamos nada.

2. **Re-enviar desde DDR:** El DMA re-envia los pesos para cada pixel.
   Para una capa con h_out=52, w_out=52, ic_tile_size=113, k=3x3:
   - Pesos por tile: 32 * 113 * 9 = 32,544 bytes
   - Pixels: 52 * 52 = 2,704
   - Total transferido: 32,544 * 2,704 = 88 MB por tile (!)
   - vs. actual: 32,544 bytes (1 vez) + acceso local
   - **Inaceptable.** Ancho de banda DDR en ZedBoard: ~2 GB/s teorico,
     ~800 MB/s practico. Una sola capa consumiria 88 MB = 110 ms solo
     de transferencia de pesos, vs. ~31 ms total actual.

**Veredicto Escenario A: NO VIABLE sin replay buffer. Con replay buffer,
es identico a la arquitectura actual. Ganancia neta: cero.**

---

### Escenario B: Stream de activaciones

**Idea:** Las activaciones llegan por AXI-Stream y se almacenan en un
line buffer de kh filas (3 filas para kernel 3x3).

**Arquitectura interna:**

```
s_axis_act --> [line buffer: 3 filas x w_in x c_in bytes] --> ventana 3x3
                                                               |
                                                            conv_core
```

El line buffer almacena las ultimas `kh` filas de la activacion. Cuando llega
una nueva fila, la mas antigua se descarta. Para cada pixel de salida, la
ventana 3x3 se extrae del line buffer.

**Calculo de memoria del line buffer:**

Para YOLOv4-tiny, los peores casos de 3x3 conv:

| Capa    | c_in | h_in | w_in | 3 filas (bytes)  | BRAMs (36Kb) |
|---------|------|------|------|------------------|--------------|
| layer_0 |    3 |  416 |  416 | 3*416*3 = 3,744  | 1            |
| layer_5 |   64 |  104 |  104 | 3*104*64 = 19,968 | 5           |
| layer_14|  128 |   52 |   52 | 3*52*128 = 19,968 | 5           |
| layer_25|  256 |   26 |   26 | 3*26*256 = 19,968 | 5           |
| layer_60|  128 |   26 |   26 | 3*26*128 = 9,984  | 3           |
| layer_90|  256 |   13 |   13 | 3*13*256 = 9,984  | 3           |
| layer_100| 256 |  13  |   13 | 3*13*256 = 9,984  | 3           |
| **PEOR: stride=2** |  |  |   |                  |              |
| layer_1 |   32 |  416 |  416 | 3*416*32 = 39,936 | 10          |
| layer_8 |  128 |  208 |  208 | 3*208*128 = 79,872 | **20**     |
| layer_148| 512 |  26  |   26 | 3*26*512 = 39,936 | 10          |

**Peor caso: layer_8 con c_in=128, w_in=208 necesita 80 KB = 20 BRAM36.**
Esto es el 14% del xc7z020.

**Problemas adicionales del Escenario B:**

1. **El conv_engine actual tiene ic_tiling.** El MAC loop procesa un
   ic_tile de tamano limitado (max ~113 para k=3x3 dado weight_buf=32KB).
   El line buffer necesitaria almacenar TODOS los canales de las 3 filas,
   no solo el tile actual, porque los datos del stream no se pueden
   "rebobinar" para el siguiente ic_tile.

   Solucion: O el line buffer guarda c_in completo (caro), o se hace
   un "double-pass" donde se re-streamean los datos para cada ic_tile
   (derrotando el proposito).

2. **Padding asimetrico.** Con pad_top/bottom/left/right independientes,
   la logica del line buffer se complica. Hay que generar zeros para
   posiciones fuera de la imagen, lo cual el conv_engine actual resuelve
   con un simple check en MAC_PAD_REG.

3. **Stride > 1.** Con stride=2, se saltan filas alternas. El line
   buffer necesita logica para avanzar 2 filas por pixel de salida en
   la dimension vertical, desperdiciando ancho de banda.

**Veredicto Escenario B: PARCIALMENTE VIABLE pero complejo. El line
buffer es un "mini-BRAM" que consume 5-20 BRAMs dependiendo de la capa.
Y no elimina el weight_buf (que sigue necesitando acceso random).
Ganancia neta: eliminar la BRAM grande de activaciones, pero se
reemplaza por un line buffer de tamano similar o mayor.**

---

### Escenario C: Full streaming pipeline

**Idea:** Todo por AXI-Stream. Tres interfaces:

```
DMA_weights (MM2S) --s_axis--> [weight FIFO/replay] --> conv_core
DMA_act (MM2S)     --s_axis--> [line buffer 3 rows]  --> conv_core
                                                          |
                                              conv_core --m_axis--> DMA_out (S2MM)
```

**Arquitectura detallada:**

```
                                    +---------------------------+
  s_axis_weight -->[ weight_fifo ]->|                           |
                   (replay cap.)    |      conv_core            |
                                    |   (MAC array + RQ)        |
  s_axis_act   -->[ line_buffer  ]->|                           |--> m_axis_out
                   (3 x w x cin)    |                           |
                                    +---------------------------+
                                           ^
                                    [config regs via AXI-Lite]
```

**Memoria interna requerida:**

| Componente        | Tamano (peor caso)           | BRAMs |
|-------------------|------------------------------|-------|
| Weight replay buf | 32 * ic_tile * 9 = 32 KB     | 8     |
| Line buffer       | 3 * 208 * 128 = 80 KB        | 20    |
| Output buffer     | minimo (FIFO 64 bytes)        | 0.5   |
| **Total**         | **~112 KB**                   | **29** |

**vs. arquitectura actual (P_14):**

| Componente        | Tamano                       | BRAMs |
|-------------------|------------------------------|-------|
| weight_buf        | 32 KB                        | 8     |
| BRAM compartida   | 4 KB (activaciones+output)   | 1     |
| **Total**         | **~36 KB**                   | **9** |

**Espera -- la BRAM de P_14 es solo 4 KB.** La arquitectura actual NO
guarda toda la activacion en FPGA. Funciona asi:

1. LOAD: DMA copia toda la activacion (hasta 512 KB) de DDR a BRAM (4 KB)
   -- ERROR: no cabe. En realidad, P_14 asume que la BRAM es suficiente
   para la capa completa o usa tiling espacial (strip mining).

Revisando P_14 con mas cuidado: el wrapper tiene una BRAM de 4 KB que
el conv_engine trata como si fuera DDR (lee/escribe via ddr_rd/wr).
Para capas grandes, el ARM carga los datos por partes (strips).

**Conclusion critica:** La arquitectura actual YA depende de una BRAM
de solo 4 KB + tiling espacial controlado por software. La propuesta
streaming Escenario C necesitaria 112 KB de buffers internos, que es
**3x mas BRAM** que la solucion actual.

---

## 4. Evaluacion de la ganancia potencial

### 4.1 Throughput

**Arquitectura actual (P_14, BRAM 4KB + strip mining):**
- El ARM ejecuta: LOAD_strip -> RUN_conv -> STORE_strip, secuencialmente
- No hay overlap entre DMA y compute
- Tiempo dominado por RUN_conv (~31 ms para layer_5)

**Arquitectura streaming:**
- Podria hacer pipeline: mientras procesa el pixel N, el line buffer
  se llena con datos del pixel N+kh
- Pero el cuello de botella no es la carga de datos, es el MAC loop
- MAC loop: 9 * ic_tile * ~35 ciclos/posicion = ~35,000 ciclos/pixel
  para ic_tile=113
- DMA puede entregar 1 word/ciclo (32 bits), pero el conv necesita
  ~35,000 ciclos por pixel y recibe solo 1 byte de activacion por pixel
- El overlap DMA/compute ahorra ~1% del tiempo total

**Ganancia en throughput: NEGLIGIBLE (<5%).**

### 4.2 Uso de BRAM

| Metrica          | Actual (P_14) | Streaming (Esc. C) |
|------------------|---------------|--------------------|
| Weight buf       | 32 KB (8 BR)  | 32 KB (8 BR)       |
| Act. storage     | 4 KB (1 BR)   | 80 KB (20 BR)      |
| Total            | 36 KB (9 BR)  | 112 KB (29 BR)     |
| % del xc7z020    | 6.4%          | **20.7%**           |

**Ganancia en BRAM: NEGATIVA. Usamos mas BRAM, no menos.**

### 4.3 Pipeline entre layers

La unica ganancia real seria hacer pipeline entre capas:
conv_layer_N produce output por stream que alimenta conv_layer_N+1
sin pasar por DDR. Pero esto requiere:

1. Dos instancias de conv_core (una por capa): 2x los recursos
2. O un conv_core que procesa ambas capas con time-multiplexing:
   requiere un scheduler complejo
3. El output de la capa N tiene layout CHW (canal-mayor), pero el
   input de la capa N+1 necesita acceso aleatorio por canal ->
   necesita un buffer de reorganizacion que es esencialmente otra BRAM

**Ganancia por pipelining: POSIBLE pero requiere 2x-3x recursos.**

---

## 5. Estimacion de complejidad (VHDL)

| Modulo               | Lineas estimadas | Complejidad |
|----------------------|------------------|-------------|
| line_buffer.vhd      | 300-400          | Media       |
| weight_replay.vhd    | 200-300          | Media       |
| conv_stream_core.vhd | 600-800          | Alta        |
| axi_stream_ifaces    | 200-300          | Baja        |
| Testbench            | 500-700          | Media       |
| **Total**            | **1800-2500**    | **Alta**    |

Para comparacion, conv_engine_v3.vhd tiene 943 lineas y fue desarrollo
iterativo de varias semanas con 3 versiones (v1, v2, v3).

---

## 6. Veredicto

### NO merece la pena para la arquitectura actual.

**Razones:**

1. **No se elimina BRAM, se usa mas.** El line buffer (20 BRAM peor caso)
   es mas grande que la BRAM actual de P_14 (1 BRAM + strip mining).
   El weight_buf se mantiene igual en todos los escenarios.

2. **No se gana throughput significativo.** El cuello de botella es el
   MAC loop (35 ciclos por posicion * 32 canales de weight load), no
   la carga de datos desde DDR/BRAM.

3. **Complejidad alta.** ~2000 lineas de VHDL nuevo, reescribiendo la
   FSM de conv_engine que ya esta verificada bit-exact en 21 capas.
   Riesgo alto de bugs sutiles en padding, stride, tiling.

4. **El acceso random a activaciones es irreducible.** Para kernel 3x3,
   se necesitan 3 filas simultaneamente, con solapamiento entre pixels.
   Un line buffer es la solucion clasica, pero ES una mini-BRAM. No hay
   forma de evitar almacenamiento local para las activaciones.

5. **Los pesos necesitan replay.** Se re-usan para cada pixel. Sin
   replay buffer = re-streaming desde DDR = explosion de ancho de banda.
   Con replay buffer = identical a weight_buf actual.

### Que SI podria tener sentido (futuro lejano):

- **Dataflow architecture completa (tipo Gemmini/TPU).** Un systolic
  array donde los pesos se cargan una vez y los datos fluyen por las
  PEs. Esto es un rediseno completo, no una modificacion de conv_engine.
  Escala: 6-12 meses de desarrollo.

- **Optimizar el MAC loop actual.** El cuello de botella real es cargar
  32 pesos desde weight_buf (32 ciclos secuenciales en MAC_WLOAD).
  Si weight_buf fuera wider (256 bits = 32 bytes/ciclo), cada paso MAC
  tomaria 1 ciclo en vez de 32. Esto 32x el throughput del MAC loop
  sin cambiar la arquitectura. Costo: ~4 BRAMs extra (dual-port wider).

- **DMA doble-buffer.** Mientras conv_engine procesa un strip, el DMA
  carga el siguiente strip en un segundo buffer. Esto oculta la latencia
  de LOAD sin necesitar streaming. Costo: +1 BRAM de 4 KB = 1 BRAM36.
  Ganancia: ~10-20% en capas donde LOAD es significativo.

### Recomendacion concreta:

1. **Mantener** la arquitectura P_14 (BRAM + strip mining).
2. **Optimizar** el MAC_WLOAD para carga paralela (wider BRAM read).
3. **Implementar** double-buffering de strips si se necesita mas rendimiento.
4. **NO** invertir en streaming directo: la relacion costo/beneficio es mala.

---

## Apendice: Datos de YOLOv4-tiny usados

Capas 3x3 representativas del batch_log.txt:

```
layer_0:   c_in=3,   w_in=416, k=3x3, s=1  -> line_buf = 3.7 KB
layer_1:   c_in=32,  w_in=416, k=3x3, s=2  -> line_buf = 39.9 KB
layer_5:   c_in=64,  w_in=104, k=3x3, s=1  -> line_buf = 19.5 KB
layer_8:   c_in=128, w_in=208, k=3x3, s=2  -> line_buf = 78.0 KB (!)
layer_14:  c_in=128, w_in=52,  k=3x3, s=1  -> line_buf = 19.5 KB
layer_25:  c_in=256, w_in=26,  k=3x3, s=1  -> line_buf = 19.5 KB
layer_90:  c_in=256, w_in=13,  k=3x3, s=1  -> line_buf = 9.8 KB
layer_148: c_in=512, w_in=26,  k=3x3, s=2  -> line_buf = 39.0 KB
```

xc7z020: 140 BRAM36 = 4,860 Kbit = 607.5 KB de Block RAM total.
Sistema base (Zynq PS + AXI + DMA): ~10-15 BRAMs.
conv_engine weight_buf: 8 BRAMs.
Disponible para line_buffer: ~115 BRAMs = ~460 KB (si no se usa nada mas).
Layer_8 (78 KB) cabria, pero consume el 14% del chip solo en line buffer.

Notas:
- Las capas 1x1 NO necesitan line buffer (kernel 1x1 = acceso puntual).
  Son ~60% de las capas de YOLOv4-tiny.
- El tamano del line buffer podria parametrizarse: pequeno para capas
  con w_in*c_in chico, grande para las peores. Pero la logica de control
  para manejar ambos casos anula la simplicidad.
