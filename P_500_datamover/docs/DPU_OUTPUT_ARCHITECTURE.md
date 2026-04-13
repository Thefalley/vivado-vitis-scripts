# DataMover como Output Stage de la DPU

> Documento de referencia para la integración del AXI DataMover en la salida
> de la DPU. Verificado en HW con P_500_datamover (ZedBoard, Vivado 2025.2.1).

---

## 1. Problema

Cuando la DPU termina de procesar un layer (conv, relu, maxpool, bias...),
genera un flujo AXI-Stream con el tensor de salida. Ese tensor tiene que
acabar en DDR, en una dirección que el ARM decida, y el ARM necesita saber
cuándo ha terminado para programar el siguiente layer.

**Requisitos:**
- Escribir el output tensor en una dirección DDR configurable por software
- Interrupción al terminar → señal de "layer completado"
- Soporte para tiling (múltiples escrituras sin intervención del ARM)
- Máxima velocidad: el DataMover no debe ser el cuello de botella

---

## 2. Arquitectura

```
                         ARM (bare-metal)
                              │
                    AXI-Lite  │  Programa:
                    (GP0)     │  - dest_addr del output tensor
                              │  - byte_count (H×W×C × bytes)
                              │  - start
                              │
                              ▼
                    ┌─────────────────────┐
                    │   dpu_output_ctrl   │
                    │   (AXI-Lite slave)  │
                    │                     │
                    │  Registros:         │
                    │   0x00: dest_addr   │  ← dirección DDR destino
                    │   0x04: byte_count  │  ← tamaño del output tensor
                    │   0x08: control     │  ← start / auto-mode
                    │   0x0C: status      │  ← done, error, busy
                    │                     │
                    │  Genera cmd 72-bit  │
                    │  automáticamente    │
                    │  cuando recibe      │
                    │  datos del DPU      │
                    └──────┬────┬─────────┘
                      cmd  │    │ sts
                      72b  │    │ 8b
                           ▼    ▲
┌──────────┐     ┌─────────────────────────┐
│          │     │    AXI DataMover         │
│   DPU    │     │    (S2MM only)           │
│ Pipeline │     │                          │
│          │ AXI-│  S_AXIS     M_AXI_S2MM   │──── AXI4 ────► DDR
│ conv     │Stream  (data in)  (memory wr)  │              (HP port)
│ relu     ├────►│                          │
│ maxpool  │     │  Burst: 256 bytes        │
│ bias     │     │  BTT: hasta 8MB          │
│          │     └──────────────────────────┘
└──────────┘                │
                            │ done
                            ▼
                       IRQ → ARM
                       "layer terminado"
```

---

## 3. Formato del comando DataMover (72 bits)

Este es el corazón de la comunicación con el DataMover. El controlador
`dpu_output_ctrl` construye este comando y lo envía por AXI-Stream al
DataMover antes de que lleguen los datos.

```
Bit(s)    Campo     Valor              Descripción
───────   ───────   ────────────────   ──────────────────────────────────
[71:68]   RSVD      0000               Reservado
[67:64]   TAG       4-bit              Tag de transacción (eco en status)
[63:32]   SADDR     dest_addr          Dirección DDR destino (32-bit)
[31]      RSVD      0                  Reservado
[30]      TYPE      1                  1=INCR (incrementa dirección)
                                       0=FIXED (misma dirección siempre)
[29:24]   DSA       000000             DRE Stream Alignment
[23]      EOF       1                  End Of Frame (último cmd del frame)
[22:0]    BTT       byte_count         Bytes a transferir (max 8MB con 23-bit)
```

**Ejemplo para un output tensor de 64×64×16 en int8 (65536 bytes):**
```
cmd = 0x0000_<dest_addr>_4100_0000 | 65536
    = 0x0000_0200_0000_4101_0000   (si dest=0x02000000)
```

---

## 4. Formato del status DataMover (8 bits)

Cuando el DataMover termina una transferencia, devuelve un byte de status
por AXI-Stream:

```
Bit    Campo     Descripción
───    ───────   ──────────────────────────
[7]    DECERR    AXI Decode Error (dirección inválida)
[6]    SLVERR    AXI Slave Error
[5]    INTERR    DataMover Internal Error
[4]    OK        Transferencia completada OK
[3:0]  TAG       Echo del TAG del comando
```

**Chequeo rápido en C:**
```c
if (status & 0xE0) → error (bits 7:5)
if (status & 0x10) → OK (bit 4)
```

---

## 5. Flujo por layer

```
Para cada layer del modelo:

1. ARM calcula dest_addr para el output tensor
   - Layer 0 output → DDR[0x02000000]
   - Layer 1 output → DDR[0x02100000]
   - (ping-pong o secuencial, según convenga)

2. ARM programa dpu_output_ctrl via AXI-Lite:
   - dest_addr = dirección donde va el resultado
   - byte_count = OH × OW × OC × sizeof(pixel)
   - start = 1

3. ARM programa DPU para ejecutar el layer:
   - Input: DDR[src_addr] (via DataMover MM2S o DMA)
   - Weights: DDR[weight_addr]
   - El DPU procesa y genera AXI-Stream de salida

4. dpu_output_ctrl detecta primer dato válido en AXI-Stream
   → genera comando 72-bit automáticamente
   → DataMover empieza a escribir en DDR[dest_addr]

5. Cuando tlast llega (fin del tensor):
   → DataMover termina la escritura
   → Status OK → dpu_output_ctrl genera IRQ
   → ARM sabe que el layer terminó

6. ARM lee resultado o programa el siguiente layer
   (el output de este layer es el input del siguiente)
```

---

## 6. Diferencia clave: DataMover directo vs AXI DMA

| Aspecto | AXI DMA | DataMover directo |
|---------|---------|-------------------|
| Quién genera comandos | DMA internamente | Nuestro RTL |
| Cambiar dirección mid-transfer | No | Sí (nuevo comando) |
| Encadenar tiles sin ARM | No | Sí (cola de comandos) |
| Stride writes (saltar filas) | No | Sí (un cmd por fila) |
| Complejidad RTL | Baja (solo registros DMA) | Media (generar cmd 72-bit) |
| Control sobre bursts | Limitado | Total |
| Overhead SW por transfer | Alto (programar 3+ registros) | Bajo (solo addr+len+start) |

**¿Por qué DataMover directo para la DPU?**

El AXI DMA oculta el DataMover detrás de sus propios registros. Cada
transferencia requiere que el ARM programe múltiples registros del DMA.
Con el DataMover directo, nuestro controlador en hardware genera los
comandos sin intervención del ARM, lo que permite:

- **Tiling sin overhead**: la DPU puede procesar por tiles y el controlador
  genera un comando por tile automáticamente
- **Layouts flexibles**: soportar NHWC, NCHW, o layouts custom cambiando
  solo la lógica de cálculo de direcciones
- **Pipeline completo**: mientras un tile se escribe en DDR, el siguiente
  ya está siendo procesado por la DPU

---

## 7. Soporte para tiling

Cuando la DPU procesa por tiles (como ya hace conv_engine v2 con TILING),
el controlador puede generar múltiples comandos encadenados:

```
Output tensor 64×64, tiles de 8×8, 16 canales (int8):

  Tile(0,0) → cmd: addr = base,                    BTT = 8×8×16 = 1024
  Tile(0,1) → cmd: addr = base + 8*16,             BTT = 1024
  Tile(0,2) → cmd: addr = base + 16*16,            BTT = 1024
  ...
  Tile(7,7) → cmd: addr = base + 63*row + 56*16,   BTT = 1024

Cada tile es un comando separado al DataMover.
El DataMover los ejecuta en secuencia automáticamente.
Solo UNA interrupción al final del último tile (EOF=1 solo en el último).

El ARM NO interviene entre tiles → máxima velocidad.
```

**Señalización EOF:**
- Tiles intermedios: `EOF = 0` → DataMover no genera status
- Último tile: `EOF = 1` → DataMover genera status → IRQ → "layer done"

---

## 8. Arquitectura DPU completa con DataMover

```
                  DDR (512MB ZedBoard)
        ┌──────────┬──────────┬──────────┐
        │ Weights  │ Input    │ Output   │
        │ tensors  │ tensor   │ tensor   │
        └────┬─────┴────┬─────┴────▲─────┘
             │          │          │
        ┌────▼──┐  ┌────▼──┐  ┌───┴──────┐
        │ DMA   │  │ DMA   │  │DataMover │
        │ MM2S  │  │ MM2S  │  │  S2MM    │
        │weights│  │ input │  │ output   │
        └───┬───┘  └───┬───┘  └────▲─────┘
            │          │           │
            ▼          ▼           │
        ┌──────────────────────────────┐
        │         DPU Pipeline         │
        │  conv → relu → pool → bias  │
        └──────────────────────────────┘

Control:
  ARM ──AXI-Lite──► {DMA_weights, DMA_input, dpu_output_ctrl, DPU_config}
  ARM ◄──IRQ────── dpu_output_ctrl (layer done)
```

**Nota sobre la entrada:** La misma técnica se puede aplicar a la entrada.
Un DataMover MM2S con un controlador que genere los comandos de lectura
permitiría leer tiles del input tensor de DDR de forma óptima. Pero para
empezar, un AXI DMA MM2S estándar es suficiente para la entrada.

---

## 9. Verificación en HW (P_500)

El concepto está verificado en hardware con el proyecto P_500_datamover:

- **Placa:** ZedBoard (xc7z020clg484-1)
- **Vivado:** 2025.2.1
- **Test:** 256 bytes (64 words) transferidos via DataMover S2MM
- **Resultado:** PASS - datos idénticos en source y destination DDR
- **Recursos:** 2809 LUTs (5.3%), 3800 FFs (3.6%), 4.5 BRAM (3.2%)
- **Timing:** WNS = +1.234 ns @ 100 MHz

**Componentes verificados:**
- `dm_s2mm_ctrl.vhd` → prototipo del `dpu_output_ctrl`
- Comando 72-bit generado correctamente
- Status 8-bit consumido correctamente
- Interrupción de "done" funcional
- DataMover IP v5.1 conectado en block design

---

## 10. Pasos para integrar en la DPU

1. **Reemplazar GPIO por AXI-Lite** en `dm_s2mm_ctrl` → crear `dpu_output_ctrl`
   con registros propios accesibles por el ARM

2. **Añadir soporte multi-comando** para tiling:
   - Registro de tile_stride y n_tiles
   - FSM que genera N comandos con direcciones incrementales
   - EOF=1 solo en el último

3. **Conectar al stream de salida del DPU** en vez del DMA MM2S de test

4. **Integrar en el block design final** junto con el DPU pipeline,
   DMAs de entrada, y el bus AXI-Lite de control

---

*Proyecto de referencia: `P_500_datamover/`*
*RTL de referencia (Ikerlan): `P_500_datamover/src/ref_rtl/`*
*Fecha de verificación HW: 2026-04-12*
