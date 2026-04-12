# P_200 - IRQ Test (Interrupciones Zynq)

## Que es esto
Modulo AXI-Lite + FSM que genera interrupciones controlables desde registros.
Verifica que desde el PS (Vitis bare-metal) puedes configurar, disparar y limpiar
interrupciones generadas en la PL.

## Arquitectura
```
PS (ARM) --AXI-Lite--> axi_lite_cfg --regs--> irq_fsm --irq_out--> GIC
```

### Mapa de registros AXI-Lite (base + offset)
| Offset | Nombre    | R/W | Descripcion                              |
|--------|-----------|-----|------------------------------------------|
| 0x00   | CTRL      | R/W | bit0=start, bit1=irq_clear               |
| 0x04   | THRESHOLD | R/W | Ciclos a contar antes de verificar cond.  |
| 0x08   | CONDITION | R/W | Valor que debe coincidir con el counter   |
| 0x0C   | STATUS    | R   | bit0=running, bit1=irq_pending, [7:4]=st  |
| 0x10   | COUNT     | R   | Valor actual del contador                 |
| 0x14   | IRQ_COUNT | R   | Total de interrupciones generadas         |

### Estados de la FSM
```
IDLE -> COUNTING -> CHECK_COND -> IRQ_FIRE (espera clear)
                       |
                       v (si condition != counter)
                    COUNTING (reinicia)
```

## Archivos
```
src/
  axi_lite_cfg.vhd    # Slave AXI-Lite con 8 registros (3 R/W + 3 R/O + 2 reserv.)
  irq_fsm.vhd         # FSM: cuenta, compara, dispara IRQ
  irq_top.vhd         # Top wrapper que conecta cfg + fsm
sim/
  tb_irq_top.vhd      # Testbench con 3 tests automaticos
  batch_sim.tcl        # Simulacion batch en servidor
  open_sim.tcl         # Simulacion con GUI Vivado
sim_local/
  run_gui.tcl          # Script para abrir xsim GUI local
```

## Como simular

### Opcion A: Batch en servidor (solo texto, rapido)
```bash
# Desde este PC:
scp -i ~/.ssh/pc-casa -r P_200_irq_test/ jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/

ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 "cd C:/Users/jce03/Desktop/claude/vivado-server/P_200_irq_test && E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source sim/batch_sim.tcl"
```
Resultado esperado en consola:
```
=== TEST 1: threshold=10, condition=10 (IRQ expected) ===
OK: IRQ fired
OK: IRQ cleared
=== TEST 2: threshold=10, condition=5 (no IRQ expected) ===
OK: no IRQ (correct)
=== TEST 3: restart with condition=10 (second IRQ) ===
OK: second IRQ fired
========== ALL TESTS PASSED ==========
```

### Opcion B: GUI local con xsim (ver formas de onda)
```bash
cd C:/project/vivado/P_200_irq_test/sim_local

# Compilar
C:/AMDDesignTools/2025.2/Vivado/bin/xvhdl.bat ../src/irq_fsm.vhd ../src/axi_lite_cfg.vhd ../src/irq_top.vhd ../sim/tb_irq_top.vhd

# Elaborar
C:/AMDDesignTools/2025.2/Vivado/bin/xelab.bat work.tb_irq_top -snapshot irq_sim -debug all

# Abrir GUI con ondas
C:/AMDDesignTools/2025.2/Vivado/bin/xsim.bat irq_sim -gui -wdb tb_irq_top.wdb -tclbatch run_gui.tcl
```

### Que verificar en la GUI
- `irq_out` sube en TEST 1 (~345 ns) y TEST 3 (~1255 ns)
- `counter` llega a 10 (threshold)
- `state` recorre: IDLE -> COUNTING -> CHECK_COND -> IRQ_FIRE
- `irq_count` incrementa: 0 -> 1 -> 2
- En TEST 2, `irq_out` se mantiene a '0' (condicion NO se cumple)

## Siguiente paso: Hardware real
Para pasar a la ZedBoard necesitas:
1. Block design Vivado con Zynq PS + este modulo como periferico AXI
2. Conectar irq_out al GIC del Zynq (IRQ_F2P)
3. Vitis bare-metal con handler de interrupcion que lea STATUS y limpie con CTRL
4. La app C escribiria THRESHOLD, CONDITION, y START via registros AXI
