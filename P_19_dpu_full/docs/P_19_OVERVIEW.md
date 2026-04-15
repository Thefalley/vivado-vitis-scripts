# P_19 — DPU YOLOv4 full stack: DPU + Ethernet + HDMI

Objetivo final: demo end-to-end con **un solo botón**:
1. PC envía imagen + pesos via Ethernet (P_18)
2. ZedBoard corre YOLOv4 completo (DPU P_17)
3. ARM decodifica bounding boxes + dibuja overlay en framebuffer DDR
4. VDMA lee framebuffer y emite **HDMI 720p** con la imagen + bboxes dibujadas

## Estructura

```
P_19_dpu_full/
├── src/                     RTL + create_bd.tcl
│   ├── dpu_stream_wrapper   (reutiliza P_17/P_18)
│   ├── dm_s2mm_ctrl         (reutiliza P_17)
│   └── create_bd.tcl        BD que fusiona P_17+P_18+P_401 HDMI
├── sw/                      Código ARM bare-metal
│   ├── main.c               entry: init eth + dpu + hdmi
│   ├── dpu_exec.c           (reutiliza P_17)
│   ├── mem_pool.c           (reutiliza P_17)
│   ├── eth_server.c         (reutiliza P_18)
│   ├── bbox_decoder.{c,h}   NUEVO: decode 3 heads + NMS
│   ├── framebuffer.{c,h}    NUEVO: primitivas 2D (line, rect, text)
│   ├── font8x8.h            NUEVO: font para labels
│   ├── hdmi_driver.{c,h}    NUEVO: init VDMA + ADV7511 I2C
│   └── yolov4_pipeline.c    NUEVO: orchestrator completo
├── host/                    PC side
│   └── yolov4_host.py       (reutiliza P_18)
└── docs/
    ├── P_19_OVERVIEW.md     este archivo
    └── P_19_HDMI_PLAN.md    plan detallado HDMI (agente A)
```

## Flujo end-to-end

```
PC                                ZedBoard
│                                 │
├── yolov4_host.py                │
│   load image.jpg                │
│   load weights.blob (60 MB)     │
│   TCP send via eth_server ────► DDR @ 0x12000000 (weights)
│                                 DDR @ 0x10000000 (input image)
│                                 │
│   run_network() TCP ──────────► yolov4_pipeline():
│                                   for i in 0..254:
│                                     dpu_exec_<op>(LAYERS[i])
│                                   └─► 3 heads en DDR
│                                 │
│                                 ARM bbox_decoder():
│                                   decode + NMS → dets[]
│                                 │
│                                 ARM framebuffer:
│                                   fb_clear()
│                                   fb_draw_image_rgb(input 416×416)
│                                   for det in dets:
│                                     fb_draw_rect(det.xywh)
│                                     fb_draw_text("person 0.95")
│                                   Xil_DCacheFlushRange(fb)
│                                 │
│                                 VDMA escanea framebuffer 60 Hz
│                                 └────► ADV7511 ──► HDMI out ──► monitor
│                                 │
│   opcional: read heads via TCP ◄ (para verificacion bit-exact)
```

## Fases de implementación

| Fase | Trabajo | Sin HW? |
|---|---|:---:|
| 1 | Agent A: plan BD + resource budget | ✓ |
| 2 | Agent B: `bbox_decoder.c` bare-metal | ✓ (valida vs Python) |
| 3 | Agent C: `framebuffer.c` + font + demo PPM | ✓ (valida con PPM) |
| 4 | BD merge P_17+P_18+P_401 HDMI | requiere Vivado local |
| 5 | `hdmi_driver.c`: I2C ADV7511 + VDMA setup | requiere HW test |
| 6 | `yolov4_pipeline.c`: orchestrator completo | requiere HW |
| 7 | Demo final: imagen→bbox→HDMI | requiere HW + cable eth |

Fases 1-3 se pueden hacer HOY en paralelo sin tocar HW.
Fases 4-7 requieren cable Ethernet + build + HW test (mañana).

## Recursos estimados P_19 (encima de P_18)

Del plan HDMI del turno nocturno (`P_17/docs/HDMI_INTEGRATION_PLAN.md`):
- +3.5k LUT (~7%)
- +3.9k FF
- +6 BRAM (framebuffer NO en BRAM, solo línea buffer del VDMA)
- +4 DSP
- +1 MMCM (74.25 MHz pixel clock)
- +1 ODDR (HDMI clock forwarding)

Cabe holgado en Z-7020 (20% LUT total después de P_19).

## Memory map

| Addr | Tamaño | Uso |
|---|---:|---|
| 0x10000000 | 1 MB | DPU_SRC |
| 0x10100000 | 1 MB | DPU_DST |
| 0x10200000 | 64 KB | RESULT mailbox |
| 0x11000000 | 16 MB | Pool activaciones |
| 0x12000000 | 64 MB | Weights YOLOv4 |
| 0x16000000 | 32 MB | Bias / configs |
| 0x18000000 | 4 MB | 3 heads output |
| **0x1A000000** | **2.76 MB** | **Framebuffer 720p RGB888** |
| 0x1B000000 | resto | libre |

## Status actual

- P_17 DPU: ✅ 4 primitivas HW verified
- P_18 Ethernet: ✅ protocolo offline validated
- P_19 HDMI: ✅ **3 agentes completaron — fases 1-3 listas, 4-7 requieren HW**

### Entregables de los agentes consolidados

**Agent A — HDMI BD plan** (`docs/P_19_HDMI_PLAN.md`, ~750 palabras):
- Análisis P_401: 720p@60Hz verificado, MMCM 100→74.2268 MHz, ADV7511 vía I2C PL (AA18/Y16)
- **Plan B recomendado**: RGB→YCbCr 4:2:2 para reutilizar I2C de P_401 ya verificada
- VDMA sobre HP1 (HP0 saturado con DMA+DM del DPU)
- Framebuffer XRGB 1280×720 @ 0x1B000000 (3.51 MB)
- Recursos extra: ~4.1k LUT, ~4.6k FF, 6 BRAM, 0 DSP, 1 MMCM, 1 ODDR
- Snippet TCL listo para aplicar sobre `P_18/src/create_bd.tcl`

**Agent B — bbox_decoder bare-metal** (`sw/bbox_decoder.{c,h}` + anchors + coco_classes, ~19 KB):
- Port byte-a-byte de `draw_bboxes.py`
- 9 anchors YOLOv4-416 Darknet order
- NMS greedy per-class, sort insertion (n≤256)
- Pre-filtro obj<0.125 recorta ~98% cells
- Validador `host/validate_bbox_decoder.py` compila a .so y compara vs Python reference
- Compile clean con gcc -O2 -Wall -Wextra

**Agent C — framebuffer primitives** (`sw/framebuffer.{c,h}` + font8x8 + clip_helpers, 1138 LOC):
- fb_clear / set_pixel / draw_line (Bresenham) / draw_rect con thickness / fill_rect / draw_text / draw_image_rgb
- font8x8 con 95 glyphs ASCII printable
- Bug encontrado y fixado: macro font horizontal mirror
- demo_test.c genera PPM validado con réplica Python (toolchain MinGW local rota)
- Todo integer-only sin malloc

**Glue nuevo — `sw/yolov4_pipeline.c`**:
- `pipeline_init()` — inicializa framebuffer
- `yolov4_pipeline_run()`:
  1. ~~Loop 255 layers dpu_exec_*~~ (TODO, stub)
  2. Cache invalidate + `decode_heads()` → detections
  3. `nms(iou=0.45)` → filtradas
  4. `draw_input_image()` (416×416 centrada en 1280×720)
  5. `draw_detections()` (rects + labels "person 0.95" con color por clase vía hash LCG)
  6. DCache flush framebuffer para VDMA

### Commits de hoy sin HW

```
6bcdab7  P_19 HDMI plan + bbox decoder + framebuffer + pipeline glue
dafedd0  P_19 skeleton para demo HDMI bbox end-to-end
891ae4f  P_18 socket PC<->ZedBoard infraestructura (offline validated)
5019506  P_17 runtime: dpu_exec_* + mem_pool + smoke test HW 32/32 PASS
```

## Lo que queda (mañana con cable Ethernet)

| Tarea | Dificultad | Tiempo |
|---|---|---|
| Aplicar snippet TCL Agent A sobre P_18 create_bd.tcl | baja | 30 min |
| Escribir `hdmi_driver.c`: I2C ADV7511 + VDMA setup (reutiliza P_401 i2c_init) | media | 1-2 h |
| Build P_19 (synth+impl+bit+export) | auto | 30 min |
| Test network accept + echo simple | baja | 15 min |
| Test lwIP WRITE_DDR + READ_DDR con cliente Python | media | 30 min |
| Extender `yolov4_pipeline_run()` loop 255 layers con tiling ARM | alta | 2-4 h |
| Test imagen completa → bbox → HDMI monitor | alta | 1-2 h |

**Total estimado para demo end-to-end funcional: ~6-10 h de trabajo** con HW verification.
