# Overnight run #1 — YOLOv4 full 255 layers (2026-04-15)

## Resultado

| Métrica | Valor |
|---|---:|
| Layers OK | **15 / 255** |
| Layers FAIL | **240 / 255** |
| Weights load JTAG | 142 s (mejor que estimado 30 min) |
| Input load | 2 s |
| Runtime total | < 60 s (mayoría fallos rápidos) |
| Heads dumpados | sí, basura |

## Causas probables

1. **Tiling con pad asimétrico falla** (~20 capas stride=2 con pad [1,1,0,0])
2. **MAXPOOL stub = skip** (3 capas, cascada de fails downstream)
3. **Memory pool slots 256 KB insuficientes** para layer 0 output 5.5 MB → buffer overflow
4. **Weights manifest offsets** no verificado capa-a-capa
5. **Layer 148 pesos 4.7 MB** no caben en 4 KB BRAM (requiere IC tiling no implementado)

## Para la próxima iteración

**Prioridad 1 (bugs obvios):**
- Memory pool real `mem_pool.c` con tamaños correctos
- Pad asimétrico en tiled conv (casos borde stride=2)
- Verificar weights manifest offsets

**Prioridad 2 (features):**
- MAXPOOL real (3 capas)
- UART capture para per-layer logs

**Prioridad 3 (arquitectura):**
- IC tiling para layer 148

## Heads dumpados (basura)

```
heads_overnight/
├── head_52.bin  689,520 B  (52*52*255)
├── head_26.bin  172,380 B  (26*26*255)
└── head_13.bin   43,092 B  (13*13*255)
```

`draw_bboxes.py` sobre estos generaría detecciones aleatorias.

## Estimación demo funcional

**~4-5 h debug + 1 overnight run.** Día 2 del roadmap planteado.
