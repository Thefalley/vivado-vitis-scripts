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
- P_19 HDMI: 🔄 **3 agentes trabajando ahora mismo**
