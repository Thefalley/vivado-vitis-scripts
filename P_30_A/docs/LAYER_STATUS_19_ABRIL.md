# P_30_A Layer Status — 19 abril 2026

## 100% FUNCIONAN (37 layers verificadas)

### Bit-exact (24 layers)
| Layer | Op | k | c_in→c_out | Size |
|-------|------|---|------------|------|
| 0 | CONV | 3 | 3→32 | 416x416 |
| 1 | LEAKY | - | 32→32 | 416x416 |
| 2 | CONV | 3 | 32→64 | 208x208 |
| 3 | LEAKY | - | 64→64 | 208x208 |
| 7 | LEAKY | - | 64→64 | 208x208 |
| 9 | LEAKY | - | 32→32 | 208x208 |
| 11 | LEAKY | - | 64→64 | 208x208 |
| 12 | ADD | - | 64→64 | 208x208 |
| 13 | CONV | 1 | 64→64 | 208x208 |
| 14 | LEAKY | - | 64→64 | 208x208 |
| 17 | LEAKY | - | 64→64 | 208x208 |
| 19 | LEAKY | - | 128→128 | 104x104 |
| 22 | LEAKY | - | 64→64 | 104x104 |
| 23 | LEAKY | - | 64→64 | 104x104 |
| 25 | LEAKY | - | 64→64 | 104x104 |
| 27 | LEAKY | - | 64→64 | 104x104 |
| 28 | ADD | - | 64→64 | 104x104 |
| 29 | CONV | 1 | 64→64 | 104x104 |
| 30 | LEAKY | - | 64→64 | 104x104 |
| 32 | LEAKY | - | 64→64 | 104x104 |
| 33 | ADD | - | 64→64 | 104x104 |
| 34 | CONV | 1 | 64→64 | 104x104 |
| 35 | LEAKY | - | 64→64 | 104x104 |
| 38 | LEAKY | - | 128→128 | 104x104 |

### Rounding +-1 (13 layers) — max 0.001% bytes, cosmético
| Layer | Op | k | c_in→c_out |
|-------|------|---|------------|
| 4 | CONV | 1 | 64→64 |
| 5 | CONV | 1 | 64→64 |
| 6 | LEAKY | - | 64→64 |
| 8 | CONV | 1 | 64→32 |
| 10 | CONV | 3 | 32→64 |
| 16 | CONV | 1 | 128→64 |
| 18 | CONV | 3 | 64→128 |
| 20 | CONV | 1 | 128→64 |
| 21 | CONV | 1 | 128→64 |
| 24 | CONV | 1 | 64→64 |
| 26 | CONV | 3 | 64→64 |
| 31 | CONV | 3 | 64→64 |
| 37 | CONV | 1 | 128→128 |

## NO FUNCIONAN (2 layers — CONCAT requant)
| Layer | Issue |
|-------|-------|
| 15 | CONCAT 64→128: necesita requantización (inputs con diferentes scales) |
| 36 | CONCAT 64→128: mismo issue |

## NO PROBADAS (216 layers — crash en layer 39)

### Por categoría:
| Categoría | Count | Razón no probada | Fix necesario |
|-----------|-------|-------------------|---------------|
| CONV_IC_TILED | 39 | Timeout (1x1 tiles, >40000 CMDs) | RTL S_WAIT_WEIGHTS o TCP timeout largo |
| CONV_OC_GROUPS | 35 | Después del crash | Ya funciona (layer 18 verificada) |
| CONV_SIMPLE | 16 | Después del crash | Ya funciona (layers 0,2,13,29,34) |
| CONV_c255 | 3 | DRAIN fault | Fix DataMover alignment |
| LEAKY | 90 | Después del crash | Ya funciona (17 verificadas) |
| ADD | 20 | Después del crash | Ya funciona (3 verificadas) |
| CONCAT | 8 | Requant + después del crash | Fix requantization |
| POOL_SPP | 3 | Después del crash | Ya arreglado (ARM fallback) |
| RESIZE | 2 | Después del crash | Ya funciona (layer 194 en test anterior) |

## TESTS PARA VERIFICACIÓN COMPLETA

### Test 1: Verificar todas las categorías no-IC-tiled
Ejecutar layers que representan cada categoría pero no necesitan IC tiling:
```
python test_isolated.py 41 42 45 50 55 60 88 94 95
```
Esto verifica CONV_SIMPLE y CONV_OC_GROUPS adicionales.

### Test 2: Verificar IC-tiled con timeout largo
```
python test_isolated.py --timeout=300 47 52 100
```
Layer 47 ya verificada (1 diff +-1). Verificar 52 y 100.

### Test 3: Verificar POOL SPP
```
python test_isolated.py 182 183 184
```
Ya verificado OK con ARM fallback.

### Test 4: Verificar CONCAT con requant (cuando se implemente)
```
python test_isolated.py 15 36 87 140
```

### Test 5: Verificar c_out=255 (cuando se arregle DRAIN)
```
python test_isolated.py 225 240 254
```

### Test 6: Run completo secuencial
```
python run_all_layers.py 255
```
Esto verifica el flujo end-to-end con DDR allocator real.

### Test 7: Verificación de no-regresión
Después de cada fix, re-ejecutar layers 0-38 para confirmar que no se rompe nada.
