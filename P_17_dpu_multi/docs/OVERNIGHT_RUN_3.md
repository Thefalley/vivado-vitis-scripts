# Overnight run #3 — YOLOv4 255 layers v3

## Resultado

| Run | OK | FAIL | Notas |
|---|---:|---:|---|
| #1 | 15 | 240 | Sin chunking, sin pool real |
| #2 | 10 | 245 | Chunking + pool (regresión NULL deref) |
| **#3** | **11** | **244** | + pad asim tiling + DMA wait + status diag |

## Breakdown v3 (status_table.bin)

```
           OK    PRM    TMO    TIL
CONV        2    51      0     57    (110 total)
LEAKY       6    51     50      0    (107 total)
ADD         0     6     17      0     (23 total)
CONCAT      3     7      0      0     (10 total)
POOL        0     3      0      0      (3 total)
RESIZE      0     2      0      0      (2 total)
─────────────────────────────────────
Total      11  120     67     57
```

## Causa raíz por tipo de fail

- **CONV TIL (57)**: pesos > 4 KB BRAM. Layer 148: 4.7 MB weights. **Requiere IC tiling** (no implementado).
- **CONV PRM (51)**: DMA errors entre sub-tiles.
- **LEAKY TMO (50)**: wrapper stall tras N chunks. Sin UART imposible debug.
- **ADD TMO (17)**: similar al LEAKY.

## Lo que funciona
- Infraestructura end-to-end: bit → weights → ELF → 255 iter → heads → status
- Pad asimétrico tiling compila/ejecuta
- JTAG 61 MB en ~140 s
- Status mailbox permite post-mortem

## Bugs residuales
1. IC tiling no existe → layers grandes imposibles
2. Wrapper stall entre cmd_start consecutivos
3. DataMover back-to-back cmds posible race

## Recomendación
**Cerrar overnight hoy.** Iteración más rápida necesita:
- UART capture (serial USB) o Ethernet live
- IC tiling (~4 h RTL work)
- Refactor wrapper reset

Día 1 con cable = 10× más productivo.

## Commits del ciclo

```
5410a11  runtime v3: pad asim + DMA wait + status diag
faf20fa  runtime v2: chunking + pool + maxpool
7d104e5  overnight run #1
b01cdfc  runtime full: orchestrator + tiling + XSCT
```

Status tables en `heads_overnight_v3/status_table.bin`.
