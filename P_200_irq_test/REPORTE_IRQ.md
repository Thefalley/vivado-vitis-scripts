# P_200: Interrupciones PL -> PS en Zynq-7000 (ZedBoard)

## Objetivo

Verificar el camino completo de interrupción desde la lógica programable (PL) hasta el procesador ARM (PS) en un Zynq-7000, incluyendo:
- FSM en VHDL que genera una interrupción registrada (level-sensitive)
- Registros AXI-Lite para controlar la FSM y leer estado
- Conexión de la interrupción al GIC del ARM vía `IRQ_F2P[0]`
- Programa bare-metal en C que configura el GIC, registra un ISR, y verifica el funcionamiento
- Verificación por JTAG (sin UART) leyendo registros HW

**Resultado: PASS** - 2 interrupciones generadas, recibidas por el ARM, y limpiadas por el ISR.

---

## Arquitectura

```
 +---------------------------+
 |     Zynq PS (ARM A9)      |
 |                            |
 |  irq_test.c (bare-metal)  |
 |    - Configura GIC         |
 |    - Registra ISR          |
 |    - Escribe AXI-Lite regs |
 |    - Espera IRQ            |
 |    - ISR lee status y      |
 |      limpia IRQ            |
 |                            |
 |  M_AXI_GP0    IRQ_F2P[0]  |
 +------+----------+---------+
        |          ^
        | AXI-Lite | IRQ (level-high)
        v          |
 +------+----------+---------+
 |          irq_top           |
 |   (AXI-Lite + FSM + IRQ)  |
 |                            |
 |  +--------+  +---------+  |
 |  |axi_lite|  | irq_fsm |  |
 |  |  _cfg  +->+         |  |
 |  | (regs) |  | FSM +   |  |
 |  |        |<-+ counter +--+--> irq_out
 |  +--------+  +---------+  |
 +----------------------------+
        PL (FPGA fabric)
```

## Mapa de Registros AXI-Lite

Base address: `0x40000000` (asignada por Vivado en M_AXI_GP0)

| Offset | Nombre     | R/W | Bits | Descripción |
|--------|-----------|-----|------|-------------|
| 0x00   | CTRL      | R/W | bit[0]=start, bit[1]=irq_clear | Control de la FSM |
| 0x04   | THRESHOLD | R/W | [31:0] | Ciclos a contar antes de comparar |
| 0x08   | CONDITION | R/W | [31:0] | Valor que debe coincidir con el contador |
| 0x0C   | STATUS    | R/O | bit[0]=running, bit[1]=irq_pending, [7:4]=state | Estado de la FSM |
| 0x10   | COUNT     | R/O | [31:0] | Valor actual del contador |
| 0x14   | IRQ_COUNT | R/O | [31:0] | Total de interrupciones generadas |

### Bits de CTRL
- `bit[0]` **start**: Escribe 1 para arrancar la FSM. Escribe 0 para pararla (la FSM se detiene en el siguiente ciclo de COUNTING).
- `bit[1]` **irq_clear**: Escribe 1 para limpiar la interrupción y volver a IDLE.

### Codificación de STATUS[7:4] (estado FSM)
- `0x0` = S_IDLE
- `0x1` = S_COUNTING  
- `0x2` = S_CHECK_COND
- `0x3` = S_IRQ_FIRE

---

## Máquina de Estados (irq_fsm)

```
  IDLE ──(start=1)──> COUNTING ──(count>=threshold)──> CHECK_COND
   ^                     |                                |
   |              (start=0 -> abort)             (count == condition?)
   |                                              /            \
   |                                            NO              YES
   |                                             |                |
   |                                    (reset counter,       IRQ_FIRE
   |                                     volver a COUNTING)      |
   |                                                       (irq_clear=1)
   +-------------------------------------------------------------+
```

### Comportamiento clave
1. **Interrupción registrada**: `irq_out` es un flip-flop (no combinacional), level-sensitive HIGH
2. **Auto-restart**: Si la condición no se cumple, la FSM vuelve a contar automáticamente
3. **Abort**: Si `start` baja a 0 durante COUNTING, la FSM para
4. **IRQ_COUNT**: Se incrementa cada vez que la FSM entra en IRQ_FIRE (hardware counter)
5. **Clear**: Solo el ISR del ARM (o quien escriba `irq_clear=1`) saca a la FSM de IRQ_FIRE

### Por qué IRQ_COUNT es la prueba definitiva

Si `IRQ_COUNT = 2` al final del test, significa que:
1. La FSM entró en IRQ_FIRE 2 veces (generó la interrupción)
2. La FSM fue sacada de IRQ_FIRE 2 veces (alguien escribió `irq_clear`)
3. El único código que escribe `irq_clear` es el ISR del ARM
4. El ISR solo se ejecuta si el GIC entregó la interrupción al ARM
5. **Por tanto: el camino completo PL -> GIC -> ISR -> AXI-Lite -> PL funciona**

---

## Ficheros del Proyecto

```
P_200_irq_test/
├── project.cfg                 # Config para build_remote.py
├── src/
│   ├── irq_fsm.vhd            # FSM + contador + interrupción
│   ├── axi_lite_cfg.vhd       # Slave AXI4-Lite (8 registros)
│   ├── irq_top.vhd            # Top: conecta axi_lite_cfg + irq_fsm
│   └── create_bd.tcl          # Block Design TCL (Zynq PS + irq_top)
├── sim/
│   ├── tb_irq_top.vhd         # Testbench con BFM AXI-Lite
│   ├── open_sim.tcl            # Para Vivado GUI (proyecto temporal)
│   └── batch_sim.tcl           # Para servidor (batch mode)
├── sim_local/
│   └── run_gui.tcl             # Waves para xsim standalone
├── sw/
│   ├── irq_test.c              # Bare-metal: 3 tests de IRQ
│   ├── create_vitis.py         # Crea workspace Vitis + compila ELF
│   └── run.tcl                 # Programa ZedBoard + verifica JTAG
└── remote_output/
    ├── irq_test_bd_wrapper.bit # Bitstream
    ├── irq_test.xsa            # Hardware export
    ├── irq_test_app.elf        # ELF bare-metal
    ├── fsbl.elf                # First Stage Boot Loader
    ├── ps7_init.tcl            # Init PS7 desde JTAG
    └── timing.rpt              # Reporte de timing
```

---

## Código VHDL Detallado

### irq_fsm.vhd

La FSM tiene 4 estados. El proceso principal es síncrono con reset activo bajo.

```vhdl
entity irq_fsm is
    port (
        clk       : in  std_logic;
        rst_n     : in  std_logic;
        ctrl      : in  std_logic_vector(31 downto 0);  -- bit0=start, bit1=irq_clear
        threshold : in  std_logic_vector(31 downto 0);
        condition : in  std_logic_vector(31 downto 0);
        status    : out std_logic_vector(31 downto 0);
        count_out : out std_logic_vector(31 downto 0);
        irq_count : out std_logic_vector(31 downto 0);
        irq_out   : out std_logic                       -- level-sensitive HIGH
    );
end irq_fsm;
```

Puntos importantes:
- El contador se compara con `threshold` usando `>=` (unsigned)
- La condición compara `counter = condition` cuando el contador alcanza threshold
- `irq_reg` es un flip-flop registrado - la interrupción no es combinacional
- `irq_cnt` nunca se resetea (solo con reset global) - cuenta total de IRQs

### axi_lite_cfg.vhd

Adaptado del template estándar de Xilinx. Cambios respecto al original de 32 registros:

1. **Reducido a 8 registros** (`OPT_MEM_ADDR_BITS = 2`, `ADDR_WIDTH = 5`)
2. **Registros 3, 4, 5 son read-only**: En el write process, los cases `"011"`, `"100"`, `"101"` están omitidos. En el read mux, leen de `status_in`, `count_in`, `irq_count_in` (señales externas desde la FSM)
3. **Puertos renombrados**: `ctrl_out`, `threshold_out`, `condition_out` (salidas R/W), `status_in`, `count_in`, `irq_count_in` (entradas R/O)

### irq_top.vhd

Simple wrapper que conecta `axi_lite_cfg` con `irq_fsm`:

```
axi_lite_cfg.ctrl_out      -> irq_fsm.ctrl
axi_lite_cfg.threshold_out -> irq_fsm.threshold
axi_lite_cfg.condition_out -> irq_fsm.condition
irq_fsm.status             -> axi_lite_cfg.status_in
irq_fsm.count_out          -> axi_lite_cfg.count_in
irq_fsm.irq_count          -> axi_lite_cfg.irq_count_in
irq_fsm.irq_out            -> irq_top.irq_out (pin externo)
```

---

## Block Design (create_bd.tcl)

### Componentes
1. **processing_system7** (ps7): Zynq PS configurado para ZedBoard
   - DDR3: MT41J128M16HA-15E, 512MB
   - UART1: MIO 48..49 (para debug futuro)
   - FCLK_CLK0: 100 MHz
   - M_AXI_GP0: habilitado (acceso AXI-Lite al PL)
   - IRQ_F2P: habilitado (1 interrupción fabric)

2. **irq_top** (irq_top_0): Nuestro módulo RTL, añadido como module reference
   ```tcl
   create_bd_cell -type module -reference irq_top irq_top_0
   ```

3. **axi_interconnect** (axi_ic_gp0): 1 master, 1 slave
   - S00: PS7 M_AXI_GP0
   - M00: irq_top S_AXI

4. **proc_sys_reset**: Genera resets sincronizados

### Conexión de interrupción
```tcl
connect_bd_net [get_bd_pins irq_top_0/irq_out] [get_bd_pins ps7/IRQ_F2P]
```

La señal `irq_out` (1 bit, level-high) va directamente a `IRQ_F2P[0]` del PS7. No hace falta `xlconcat` porque solo hay 1 fuente de interrupción.

### Mapa de direcciones
Vivado asigna automáticamente con `assign_bd_address`. El irq_top quedó en:
- **Base: 0x40000000** (espacio GP0)
- **Rango: 4K** (solo usamos 32 bytes: 0x00-0x1C)

---

## Código C (irq_test.c)

### Inicialización del GIC (Generic Interrupt Controller)

```c
XScuGic_Config *cfg = XScuGic_LookupConfig(XPAR_SCUGIC_SINGLE_DEVICE_ID);
XScuGic_CfgInitialize(&Intc, cfg, cfg->CpuBaseAddress);

// IRQ_F2P[0] = SPI ID 61, level-sensitive high, prioridad 0xA0
XScuGic_SetPriorityTriggerType(&Intc, 61, 0xA0, 0x1);

// Conectar handler
XScuGic_Connect(&Intc, 61, (Xil_InterruptHandler)IrqHandler, NULL);
XScuGic_Enable(&Intc, 61);

// Habilitar excepciones ARM
Xil_ExceptionInit();
Xil_ExceptionRegisterHandler(XIL_EXCEPTION_ID_INT,
    (Xil_ExceptionHandler)XScuGic_InterruptHandler, &Intc);
Xil_ExceptionEnable();
```

### Parámetros clave de la interrupción

| Parámetro | Valor | Explicación |
|-----------|-------|-------------|
| IRQ ID | 61 | IRQ_F2P[0] en Zynq-7000 = SPI 61 |
| Trigger | 0x1 | Level-sensitive high (coincide con irq_fsm que mantiene irq_out=1) |
| Prioridad | 0xA0 | 160/255 (menor número = mayor prioridad) |

### ISR (Interrupt Service Routine)

```c
static void IrqHandler(void *CallbackRef)
{
    u32 status = Xil_In32(IRQ_BASE + REG_STATUS);
    
    // Clear: escribir irq_clear=1, luego 0
    Xil_Out32(IRQ_BASE + REG_CTRL, 0x2);  // irq_clear=1
    Xil_Out32(IRQ_BASE + REG_CTRL, 0x0);  // release
    
    g_irq_count++;
}
```

El ISR debe limpiar la interrupción escribiendo `irq_clear=1` en CTRL. Si no lo hace, la interrupción se queda activa (level-high) y el GIC la vuelve a entregar inmediatamente.

### Los 3 tests

| Test | threshold | condition | Esperado | Resultado |
|------|-----------|-----------|----------|-----------|
| 1 | 100 | 100 | IRQ dispara (100==100) | PASS |
| 2 | 100 | 50 | Sin IRQ (100!=50, auto-restart) | PASS |
| 3 | 100 | 100 | 2do IRQ, irq_count=2 | PASS |

---

## Simulación

### Testbench (tb_irq_top.vhd)

Incluye procedimientos AXI-Lite write/read completos:

```vhdl
-- AXI-Lite write: drive AW+W channels, wait for B response
procedure axi_write(addr, data) is
begin
    awaddr <= addr; awvalid <= '1';
    wdata <= data; wstrb <= x"F"; wvalid <= '1';
    bready <= '1';
    loop
        wait until rising_edge(clk);
        exit when bvalid = '1';
    end loop;
    awvalid <= '0'; wvalid <= '0';
    wait until rising_edge(clk);
    bready <= '0';
end procedure;
```

### Ejecución

**Opción A: Vivado GUI (local)**
```
vivado -source P_200_irq_test/sim/open_sim.tcl
```

**Opción B: Batch en servidor**
```bash
ssh servidor "vivado -mode batch -source sim/batch_sim.tcl"
```

**Opción C: xsim standalone (local)**
```bash
cd P_200_irq_test/sim_local
xvhdl --relax ../src/axi_lite_cfg.vhd ../src/irq_fsm.vhd ../src/irq_top.vhd ../sim/tb_irq_top.vhd
xelab --debug all --relax --snapshot irq_sim work.tb_irq_top
xsim irq_sim -gui -tclbatch run_gui.tcl
```

### Resultado de simulación
```
TEST 1: threshold=10, condition=10 -> OK: IRQ fired, IRQ_COUNT=1, cleared
TEST 2: threshold=10, condition=5  -> OK: no IRQ (correct)
TEST 3: restart condition=10       -> OK: 2nd IRQ, IRQ_COUNT=2
========== ALL TESTS PASSED ==========
```

---

## Build y Deployment

### Build en servidor remoto

```bash
# 1. Subir fuentes
scp -i ~/.ssh/pc-casa src/*.vhd project.cfg jce03@servidor:P_200_irq_test/

# 2. Crear proyecto + Block Design
ssh servidor "vivado -mode batch -source tcl/create_bd_project.tcl \
    -tclargs P_200_irq_test irq_test xc7z020clg484-1 src/create_bd.tcl"

# 3. Sintetizar
ssh servidor "vivado -mode batch -source tcl/synthesize.tcl \
    -tclargs P_200_irq_test/build/irq_test.xpr"

# 4. Implementar
ssh servidor "vivado -mode batch -source tcl/implement.tcl \
    -tclargs P_200_irq_test/build/irq_test.xpr"

# 5. Bitstream
ssh servidor "vivado -mode batch -source tcl/gen_bitstream.tcl \
    -tclargs P_200_irq_test/build/irq_test.xpr"

# 6. Export XSA
ssh servidor "vivado -mode batch -source tcl/export_hw.tcl \
    -tclargs P_200_irq_test/build/irq_test.xpr P_200_irq_test/build/irq_test.xsa"

# 7. Vitis (crear platform + app + compilar ELF)
ssh servidor "vitis -s sw/create_vitis.py build/irq_test.xsa vitis_ws sw/irq_test.c"

# 8. Descargar resultados
scp servidor:P_200_irq_test/build/*.bit P_200_irq_test/build/*.xsa \
    P_200_irq_test/vitis_ws/irq_test_app/build/irq_test_app.elf ./remote_output/
```

### Programar la ZedBoard (JTAG, sin UART)

```bash
xsct sw/run.tcl remote_output/irq_test_bd_wrapper.bit \
     remote_output/irq_test_app.elf \
     remote_output/fsbl.elf
```

### Secuencia JTAG correcta para Zynq

Este fue el punto más delicado. La secuencia que funciona:

```
1. connect                    # Conectar a hw_server
2. targets ARM_CORE           # Seleccionar ARM Cortex-A9 #0
3. rst -processor             # Reset del procesador
4. source ps7_init.tcl        # Cargar funciones de init
5. ps7_init                   # Configurar clocks, DDR, MIO
6. targets FPGA               # Seleccionar xc7z020
7. fpga bitstream.bit         # Programar PL (DESPUES de ps7_init)
8. targets ARM_CORE           # Volver a ARM
9. ps7_post_config            # Habilitar level shifters PS-PL
10. rst -processor            # Reset limpio
11. dow app.elf               # Cargar ELF
12. con                       # Ejecutar
```

**Errores comunes y soluciones:**

| Error | Causa | Solución |
|-------|-------|----------|
| "APB AP transaction error" | ARM no accesible | `rst -srst` (system reset) y esperar 5s |
| "Cannot halt processor" | ARM ejecutando basura | `rst -processor` antes de `stop` |
| "Memory write error at 0x0" | DDR no inicializada | Ejecutar `ps7_init` primero |
| "Channel closed" al hacer fpga | ps7_init cambió estado JTAG | Hacer fpga ANTES de ps7_init, o reconectar |
| "PL AXI slave ports blocked" | xsct no conoce el mapa PL | Usar `mrd -force` para leer registros PL |
| Bitstream borrado tras rst -srst | System reset borra PL | Re-programar fpga después del rst -srst |

### Verificación por JTAG (sin UART)

```tcl
# Leer registros del PL (necesita -force)
mrd -force 0x40000014 1   ;# IRQ_COUNT -> debe ser 2
mrd -force 0x4000000C 1   ;# STATUS -> debe ser 0 (IDLE)
mrd -force 0x00100000 1   ;# DDR marker -> debe ser 0xDEADBEEF
```

---

## Resultado Final en Hardware

```
=========================================
  VERIFICACION POR JTAG
=========================================

  CTRL       = 0x00000000
  THRESHOLD  = 100
  CONDITION  = 100
  STATUS     = 0x00000000
  COUNT      = 0
  IRQ_COUNT  = 2
  DDR marker = 0xDEADBEEF

=========================================
  App completada:       OK
  IRQ_COUNT >= 2:       OK (2 interrupciones)
  STATUS = IDLE:        OK
=========================================
  RESULTADO: PASS
  Interrupciones PL->PS VERIFICADAS!
=========================================
```

---

## Cómo Adaptar para Tu Proyecto

### Añadir más registros
En `axi_lite_cfg.vhd`, añadir puertos y mapear en el write/read mux. Para más de 8 registros, subir `OPT_MEM_ADDR_BITS` (3 para 16 regs, 4 para 32 regs).

### Cambiar la condición de interrupción
Modificar el estado `S_CHECK_COND` en `irq_fsm.vhd`. La comparación actual (`counter = condition`) puede cambiarse por cualquier lógica: señales externas, umbrales, comparadores de patrones, etc.

### Múltiples interrupciones
1. Añadir más señales `irq_out` al módulo
2. En el Block Design, usar `xlconcat` para juntar las señales
3. Conectar `xlconcat/dout` a `ps7/IRQ_F2P`
4. En C, registrar handlers con IDs 61, 62, 63... (IRQ_F2P[0], [1], [2]...)

### Edge-triggered en vez de level
1. En `irq_fsm.vhd`, hacer que `irq_reg` solo suba 1 ciclo (pulse)
2. En C, cambiar trigger type: `XScuGic_SetPriorityTriggerType(&Intc, 61, 0xA0, 0x3)` (0x3 = rising edge)

---

## Plataforma y Herramientas

- **FPGA**: Zynq-7000 XC7Z020 (ZedBoard)
- **Vivado**: 2025.2 / 2025.2.1
- **Vitis**: 2025.2.1
- **xsct**: 2025.2.0
- **Compilación**: Servidor remoto via SSH (Tailscale)
- **Ejecución HW**: Local via JTAG USB
