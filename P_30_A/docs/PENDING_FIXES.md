# P_30_A: Estado de verificación 18 abril 2026

## Resultados (255 layers, test aislado con input ONNX)

| Categoría | Count | % |
|-----------|-------|---|
| BIT-EXACT | 121 | 47% |
| ROUNDING +-1 | 27 | 11% |
| REAL FAIL | 42 | 16% |
| ERROR | 65 | 25% |

## Problemas pendientes

### 1. CONV k=3 con IC+OC tiling simultáneo (42 layers)
- **Síntoma**: max_diff 100-243, output masivamente incorrecto
- **Afecta**: layers con c_out*kk*c_in > 32KB Y N_MAC*kk*c_in > 32KB
  (necesitan BOTH OC groups AND IC tiles)
- **Ejemplo**: layer 47 (k=3 c=128->128): 4 OC groups × 2 IC tiles
- **Causa**: investigando. Los pesos y layout parecen correctos.
  Posible issue: los acumuladores MAC se corrompen entre IC tiles
  aunque no_clear=1 debería preservarlos.
- **Prioridad**: ALTA

### 2. c_out no múltiplo de 32 (layers 225, 240, 254)
- **Síntoma**: ERR status=0x1 (INVALID_CMD)
- **Afecta**: layers con c_out=255 (detección heads de YOLOv4)
- **Causa**: firmware asume c_out % 32 == 0
- **Solución**: padding de canales a múltiplo de 32 con pesos=0/bias=0.
  Descartar el canal extra al copiar output.
- **Prioridad**: MEDIA

### 3. POOL grande sin tiling (3 layers)
- **Síntoma**: ERR status=0x3 (TIMEOUT)
- **Afecta**: MAXPOOL 2x2 con input > 8KB BRAM
- **Causa**: igual que ADD — necesita chunking
- **Solución**: partir input en chunks como dpu_exec_add
- **Prioridad**: MEDIA

### 4. Rounding +-1 en requantize (27 layers)
- **Síntoma**: max_diff=1, 0.001% de bytes afectados
- **Causa**: diferencia de rounding mode DPU vs ONNX Runtime
- **Solución**: futuro — no afecta funcionalidad
- **Prioridad**: BAJA
