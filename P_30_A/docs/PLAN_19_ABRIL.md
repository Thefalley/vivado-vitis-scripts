# Plan 19 abril 2026 — Resolver los 5 bugs pendientes

## Tarea 1: POOL grande (layers 182, 183, 184)
**Problema**: st=0x3 (TIMEOUT). El chunking en dpu_exec.c no se ejecuta.
**Investigar**: 
- ¿eth_server llama a dpu_exec_pool o a otra función?
- ¿El wrapper S_STREAM_MP soporta múltiples CMD_START para chunks?
- ¿reg_n_words overflow para POOL input grande?
**Fix**: Asegurar que dpu_exec_pool con chunking se llama y funciona.
**Test**: `python test_isolated.py 182 183 184`

## Tarea 2: c_out=255 (layers 225, 240, 254)
**Problema**: st=0x1 (INVALID_CMD) instantáneo, ni llega a ejecutar.
**Investigar**:
- ¿eth_server rechaza c_out=255? Puede ser overflow en layer_config_t
- ¿El campo c_out en LAYERS[] del firmware es uint8 (max 255)?
- ¿El fw recibe c_out=255 o 0?
**Fix**: Verificar tipos en layer_configs.h, ampliar si necesario.
**Test**: `python test_isolated.py 225 240 254`

## Tarea 3: CONCAT layout (~10 layers)
**Problema**: max_diff 65-160, datos parcialmente correctos.
**Investigar**:
- arm_concat en dpu_exec.c: ¿NCHW o NHWC?
- El CONCAT de YOLOv4 concatena por canales (axis=1 en NCHW)
- Verificar que c_a y c_b se pasan correctamente desde eth_server
**Fix**: Corregir layout en arm_concat si es NHWC→NCHW.
**Test**: `python test_isolated.py 15 36 87`

## Tarea 4: IC-tiled grandes timeout (layers 39, 90, 143+)
**Problema**: ARM crash por 40000+ CMD_STARTs con tiles 1x1.
**Opción A (firmware)**: Aumentar tile para IC-tiled layers sin OC+IC combo.
  Para layers donde N_MAC*kk*c_in ≤ 32KB (solo OC groups, sin IC split):
  ya funciona con tiles grandes (layer 18 OK con tile=8).
  Solo falla cuando N_MAC*kk*c_in > 32KB (necesita IC split real).
**Opción B (RTL futura)**: S_WAIT_WEIGHTS para pause+reload.
**Fix inmediato**: Aumentar timeout TCP del Python host a 600s.
  Verificar si el crash es TCP timeout o ARM crash real.
**Test**: `python test_isolated.py 39 90` con timeout largo

## Tarea 5: Rounding +-1 (27 layers)
**Problema**: max_diff=1, 0.001% bytes. No es bug de datos.
**Acción**: Documentar como limitación conocida. No fix por ahora.
**Test**: Ya verificado, no requiere acción.

## Verificación final
Después de resolver T1-T4:
1. Rebuild ELF (make clean && make all)
2. Hard reset + program ZedBoard
3. Test aislado de las 255 layers: clasificar OK/ROUNDING/FAIL/ERR
4. Commit + push con resultados
5. Actualizar PENDING_FIXES.md con estado final
