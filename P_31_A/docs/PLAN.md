# P_31_A -- Portar DPU de ZedBoard (Zynq-7020, bare-metal) a KV260 (K26, Linux)

## Estado actual

El DPU corre en ZedBoard (xc7z020clg484-1) en bare-metal (Cortex-A9, sin OS).
Arquitectura verificada bit-exact contra ONNX (255 capas YOLOv4 INT8):

- **RTL**: conv_engine_v3, leaky_relu, maxpool_unit, elem_add, dpu_stream_wrapper,
  dm_s2mm_ctrl, mac_array, mac_unit, requantize, mul_s32x32_pipe, mul_s9xu30_pipe
- **Block Design**: Zynq PS7 + AXI DMA (MM2S) + AXI DataMover (S2MM) +
  2x AXI GPIO + dpu_stream_wrapper + dm_s2mm_ctrl
- **Interfaces PS-PL**: M_AXI_GP0 (control), S_AXI_HP0 (datos)
- **Software**: bare-metal C en ARM, lwIP para Ethernet, PC controla via TCP
- **Memoria**: DDR3 512 MB, mapa fijo (input 0x10000000, weights 0x12000000, etc.)

El objetivo es hacer que exactamente el mismo RTL corra en la Kria KV260
(K26, xck26-sfvc784-2LV-c) bajo Linux Ubuntu, sin bare-metal.

---

## 1. Respuestas a las preguntas clave

### 1.1 No se necesita PetaLinux

La KV260 ya viene con Ubuntu (o se le instala una imagen Ubuntu de AMD).
El Ubuntu de la KV260 ya tiene todo lo necesario:

- `fpga-manager` (kernel module, habilitado por defecto)
- `fpgautil` (instalar con `sudo apt install fpga-manager-xlnx`)
- `xmutil` (pre-instalado en la imagen Kria Ubuntu)
- `dtc` (device tree compiler, `sudo apt install device-tree-compiler`)
- `bootgen` (instalar con `sudo apt install bootgen-xlnx`, o usar el de Vivado en el PC)

PetaLinux solo seria necesario si quisieramos reconstruir el kernel o el
rootfs completo. Para cargar un overlay custom con nuestro DPU, no hace falta.

### 1.2 Como cargar un bitstream custom en la KV260

Hay dos metodos. Ambos funcionan sin PetaLinux.

**Metodo A: fpgautil (mas simple, recomendado para desarrollo)**

```bash
# En la KV260 via SSH:

# 1. Convertir .bit a .bin (en el PC con Vivado, o en la KV260 con bootgen)
#    Crear archivo bootgen.bif:
#      all:{ design.bit }
#    Ejecutar:
bootgen -w -arch zynqmp -process_bitstream bin -image bootgen.bif
#    Genera: design.bit.bin

# 2. Copiar .bin y .dtbo a la KV260:
scp design.bit.bin ubuntu@kv260:/home/ubuntu/
scp dpu_overlay.dtbo ubuntu@kv260:/home/ubuntu/

# 3. Descargar cualquier app activa:
sudo xmutil unloadapp

# 4. Cargar el bitstream:
sudo fpgautil -b design.bit.bin -o dpu_overlay.dtbo
```

**Metodo B: xmutil (mas robusto, recomendado para produccion)**

```bash
# 1. Crear directorio de firmware:
sudo mkdir -p /lib/firmware/xilinx/p31a-dpu

# 2. Copiar archivos:
sudo cp design.bit.bin /lib/firmware/xilinx/p31a-dpu/p31a-dpu.bit.bin
sudo cp dpu_overlay.dtbo /lib/firmware/xilinx/p31a-dpu/p31a-dpu.dtbo
sudo cp shell.json /lib/firmware/xilinx/p31a-dpu/shell.json

# 3. shell.json minimo:
# {
#     "shell_type": "XRT_FLAT",
#     "num_slots": "1",
#     "dtbo_filename": "p31a-dpu.dtbo",
#     "bitstream_filename": "p31a-dpu.bit.bin"
# }

# 4. Cargar:
sudo xmutil unloadapp
sudo xmutil loadapp p31a-dpu

# 5. Verificar:
sudo xmutil listapps
```

### 1.3 Device tree overlay para el DPU

Se necesita un .dts que:
- Declare los perifericos PL (DMA, DataMover, GPIO, dpu_wrapper) con sus
  direcciones base (las mismas que Vivado asigna en el address editor)
- Asigne drivers: `generic-uio` para AXI-Lite slaves, y `xlnx,axi-dma-1.00.a`
  o `generic-uio` para el DMA

**NOTA IMPORTANTE sobre el target-path:**
- En la imagen Ubuntu de Kria, el bus AXI PL se llama `/amba` (no `/amba_pl`)
- Verificar con: `ls /proc/device-tree/amba/`
- El `#address-cells` y `#size-cells` son 2 (64-bit), asi que las direcciones
  van como dos valores de 32 bits: `<0x0 0xA0000000>`

```dts
/* dpu_overlay.dts -- Device tree overlay para DPU en KV260 */
/dts-v1/;
/plugin/;

/ {
    /* Los fragmentos apuntan al bus AXI del PS */

    fragment@0 {
        target-path = "/amba";
        __overlay__ {

            /* ================================================ */
            /* AXI DMA (MM2S only) -- cargar datos al DPU       */
            /* Direccion base: verificar en Vivado Address Editor */
            /* ================================================ */
            axi_dma_0: axi_dma@a0000000 {
                compatible = "generic-uio";
                reg = <0x0 0xa0000000 0x0 0x10000>;
                /* Si se quiere usar el driver kernel de DMA en vez de UIO:
                 * compatible = "xlnx,axi-dma-1.00.a";
                 * pero UIO es mas simple para userspace */
            };

            /* ================================================ */
            /* dpu_stream_wrapper -- registros AXI-Lite de config */
            /* ================================================ */
            dpu_wrapper: dpu_wrapper@a0010000 {
                compatible = "generic-uio";
                reg = <0x0 0xa0010000 0x0 0x10000>;
            };

            /* ================================================ */
            /* AXI GPIO addr -- dest_addr para DataMover         */
            /* ================================================ */
            gpio_addr: gpio_addr@a0020000 {
                compatible = "generic-uio";
                reg = <0x0 0xa0020000 0x0 0x10000>;
            };

            /* ================================================ */
            /* AXI GPIO ctrl -- ctrl/status para dm_s2mm_ctrl    */
            /* ================================================ */
            gpio_ctrl: gpio_ctrl@a0030000 {
                compatible = "generic-uio";
                reg = <0x0 0xa0030000 0x0 0x10000>;
            };
        };
    };
};
```

Compilar:
```bash
dtc -@ -I dts -O dtb -o dpu_overlay.dtbo dpu_overlay.dts
```

**Sobre CMA (Contiguous Memory Allocator):**

La imagen Ubuntu de la KV260 ya configura `cma=900M` en los bootargs por
defecto. Esto es mas que suficiente para los ~160 MB que usa el DPU
(64 MB pesos + 96 MB activaciones). No hay que cambiar nada.

Si se necesitara mas, se puede modificar en U-Boot:
```
setenv bootargs "... cma=1200M"
saveenv
```

Pero 900 MB deberia sobrar. La DDR4 del K26 es de 4 GB (vs 512 MB del ZedBoard),
asi que hay espacio de sobra.

### 1.4 Acceso a DMA y AXI-Lite desde Linux userspace

**Enfoque recomendado: UIO (generic-uio) para todo**

Es el enfoque mas simple y no requiere escribir un kernel driver.
Con el device tree de arriba, cada periferico aparece como `/dev/uioN`.

```c
/* Ejemplo: acceder al dpu_wrapper desde userspace */
#include <fcntl.h>
#include <sys/mman.h>
#include <stdint.h>

int fd = open("/dev/uio1", O_RDWR);  /* uio1 = dpu_wrapper */
volatile uint32_t *regs = mmap(NULL, 0x10000,
    PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);

/* Escribir registro: igual que en bare-metal pero sin Xil_Out32 */
regs[0x08/4] = c_in;      /* REG_C_IN */
regs[0x0C/4] = c_out;     /* REG_C_OUT */
regs[0x10/4] = h_in;      /* REG_H_IN */
regs[0x00/4] = 0x01;      /* CMD_LOAD */
```

**Para buffers DMA (acceso a DDR):**

Opciones de menor a mayor complejidad:

| Metodo | Complejidad | Rendimiento | Notas |
|--------|-------------|-------------|-------|
| `/dev/mem` + mmap | Minima | OK | No-cache, funciona directo |
| `udmabuf` | Baja | Bueno | Kernel module, buffers coherentes |
| `dma-proxy` | Media | Optimo | Kernel module de Xilinx |
| Driver custom | Alta | Optimo | Solo si lo anterior no basta |

**Recomendacion para P_31_A: empezar con `/dev/mem`**, que es lo mas parecido
al flujo bare-metal actual (donde escribimos directamente a direcciones fisicas).

```c
/* Ejemplo: escribir datos a DDR para que el DMA los lea */
int fd_mem = open("/dev/mem", O_RDWR | O_SYNC);
void *ddr = mmap(NULL, size,
    PROT_READ | PROT_WRITE, MAP_SHARED, fd_mem, phys_addr);
memcpy(ddr, data, size);
munmap(ddr, size);
```

**NOTA:** `/dev/mem` requiere `root` y que el kernel no tenga `CONFIG_STRICT_DEVMEM`
habilitado (en la imagen Kria Ubuntu esta deshabilitado por defecto).

**Para DMA scatter-gather o buffers grandes (>1 MB):**

Usar `udmabuf` (u-dma-buf). Es un modulo kernel que crea buffers DMA
contiguos accesibles desde userspace:

```bash
# Instalar (compilar modulo o usar DKMS):
sudo apt install linux-headers-$(uname -r)
git clone https://github.com/ikwzm/udmabuf.git
cd udmabuf && make && sudo insmod u-dma-buf.ko

# Crear buffer de 64 MB para pesos:
echo "u-dma-buf-mgr" | sudo tee /sys/class/u-dma-buf-mgr/create
echo "udmabuf0 67108864" | sudo tee /sys/class/u-dma-buf-mgr/u-dma-buf-mgr/create
```

### 1.5 Cambios en el proyecto Vivado

#### 1.5.1 Part number

```
ZedBoard:  xc7z020clg484-1
KV260:     xck26-sfvc784-2LV-c
```

En `project.cfg`:
```ini
[project]
name = p31a_dpu
part = xck26-sfvc784-2LV-c
top  = p31a_dpu_bd_wrapper
```

#### 1.5.2 PS IP: de processing_system7 a zynq_ultra_ps_e

Este es el cambio mas grande en el TCL. La tabla muestra el mapeo:

| Zynq-7000 (ZedBoard) | Zynq UltraScale+ (K26) | Notas |
|---|---|---|
| `processing_system7:5.5` | `zynq_ultra_ps_e:3.5` | IP diferente |
| `M_AXI_GP0` | `M_AXI_HPM0_FPD` | Master AXI (control) |
| `S_AXI_HP0` | `S_AXI_HP0_FPD` | Slave AXI (datos) |
| `FCLK_CLK0` | `pl_clk0` | Clock PL |
| `FCLK_RESET0_N` | `pl_resetn0` | Reset PL |
| `IRQ_F2P` | `pl_ps_irq0` | Interrupts PL->PS |
| `M_AXI_GP0_ACLK` | `maxihpm0_fpd_aclk` | Clock del master port |
| `S_AXI_HP0_ACLK` | `saxihp0_fpd_aclk` | Clock del slave port |
| DDR + FIXED_IO | Solo DDR (no hay FIXED_IO) | Pins fijos del SOM |
| `PCW_*` properties | `PSU_*` properties | Config namespace |

#### 1.5.3 Configuracion PS del K26

El K26 SOM tiene board files en Vivado que pre-configuran DDR4, eMMC, etc.
Usar el board preset simplifica enormemente la configuracion:

```tcl
# En create_bd.tcl para K26:
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ps]

# Aplicar preset del board K26 (si el board file esta instalado):
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ps]

# Habilitar interfaces necesarias:
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__S_AXI_HP0 {1} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
] $zynq
```

#### 1.5.4 AXI bus width

- Zynq-7000 GP0: 32-bit AXI
- Zynq US+ HPM0_FPD: 128-bit AXI (configurable a 32/64/128)
- Zynq US+ HP0_FPD: 128-bit AXI (configurable a 32/64/128)

Nuestro DPU usa AXI-Lite (32-bit) para control y AXI full (32-bit data)
para el DMA/DataMover. Los AXI interconnects que Vivado genera se
encargan de adaptar anchos automaticamente. No hay que cambiar el RTL.

#### 1.5.5 Interrupts

Zynq-7000 usa `IRQ_F2P[15:0]`. Zynq US+ usa `pl_ps_irq0[7:0]`.
Nuestro DPU usa 3 interrupts (DMA mm2s, dm_done, s2mm_err), asi que
no hay problema. El xlconcat se mantiene, solo cambia el pin destino.

#### 1.5.6 DDR

- ZedBoard: DDR3, 512 MB, dirrecion 0x00000000-0x1FFFFFFF
- K26: DDR4, 4 GB, direccion 0x00000000-0x7FFFFFFF (bajo) +
  0x800000000-0x87FFFFFFF (alto)

El mapa de memoria del DPU (0x10000000-0x1C000000) cabe en los primeros
512 MB, asi que las direcciones NO cambian. El DPU usa direcciones fisicas
de 32 bits en el DataMover (BTT 23-bit), que alcanza sin problema.

**IMPORTANTE:** El DataMover S2MM usa direcciones de 32 bits en el comando
de 72 bits. Si se quisieran usar direcciones altas (>4 GB) habria que
reconfigurar el DataMover con address width de 64 bits. Para P_31_A no
hace falta porque usamos la misma zona baja de DDR.

#### 1.5.7 Ethernet

En bare-metal: lwIP stack + TCP server en el ARM.
En Linux: no se necesita nada especial. Linux ya tiene Ethernet funcionando.
La comunicacion PC-KV260 es por SSH + SCP normal.
El software de control puede correr directamente en la KV260 (no necesita TCP).

#### 1.5.8 No hay cambios en el RTL

Los VHDL del DPU son 100% portatiles. Usan:
- AXI-Lite slave (dpu_stream_wrapper)
- AXI-Stream (s_axis, m_axis)
- BRAM inferido (arrays de std_logic_vector)
- DSP48 inferido (multiplicadores)
- Logica combinacional y registros

Nada de esto depende de la familia Zynq. El RTL se copia tal cual.

### 1.6 Enfoque mas simple (sin PetaLinux)

El flujo completo minimo es:

```
PC (Vivado)                              KV260 (Linux Ubuntu)
-----------                              --------------------
1. Crear proyecto Vivado (K26 part)
2. Block Design con zynq_ultra_ps_e
3. Sintetizar + Implementar
4. Generar .bit
5. Convertir .bit -> .bit.bin (bootgen)
6. Escribir .dts -> compilar .dtbo (dtc)
                                         7. scp .bit.bin + .dtbo
                                         8. fpgautil -b X.bit.bin -o X.dtbo
                                         9. Compilar app C con gcc nativo
                                         10. Ejecutar app (accede /dev/uio*)
```

No se necesita:
- PetaLinux (no reconstruimos kernel/rootfs)
- Vitis (no hacemos bare-metal)
- XSCT (no programamos por JTAG)
- FSBL (ya viene en el boot del K26)

---

## 2. Resumen de diferencias ZedBoard vs KV260

| Aspecto | ZedBoard (P_18) | KV260 (P_31_A) |
|---------|-----------------|-----------------|
| FPGA part | xc7z020clg484-1 | xck26-sfvc784-2LV-c |
| PS IP | processing_system7:5.5 | zynq_ultra_ps_e:3.5 |
| CPU | Cortex-A9 dual (32-bit) | Cortex-A53 quad (64-bit) |
| DDR | 512 MB DDR3 | 4 GB DDR4 |
| OS | Bare-metal (no OS) | Ubuntu Linux |
| Boot | JTAG (xsct) | SD card / eMMC (Linux ya corriendo) |
| Bitstream load | JTAG program | fpgautil / xmutil (overlay) |
| SW toolchain | arm-none-eabi-gcc (Vitis) | aarch64-linux-gnu-gcc (o gcc nativo en K26) |
| DPU control | Xil_Out32/In32 en bare-metal | mmap /dev/uio* o /dev/mem |
| DMA buffers | Direccion fisica directa | /dev/mem mmap o udmabuf |
| Ethernet | lwIP bare-metal TCP | Kernel networking (SSH/SCP) |
| Cache | Xil_DCacheFlush/Invalidate | No necesario si usamos O_SYNC mmap |
| Interrupts | GIC bare-metal (xscugic) | UIO interrupt o poll |
| Master AXI port | M_AXI_GP0 | M_AXI_HPM0_FPD |
| Slave AXI port | S_AXI_HP0 | S_AXI_HP0_FPD |
| PL clock | FCLK_CLK0 | pl_clk0 |
| PL reset | FCLK_RESET0_N | pl_resetn0 |
| IRQ PL->PS | IRQ_F2P | pl_ps_irq0 |

---

## 3. Plan de trabajo (fases)

### Fase 1: Vivado project para K26 (solo build, sin HW)

Archivos a crear:
- `P_31_A/project.cfg` -- part = xck26-sfvc784-2LV-c
- `P_31_A/src/create_bd.tcl` -- adaptado de P_18 con zynq_ultra_ps_e
- `P_31_A/src/*.vhd` -- copiados de P_30_A/src/ (o P_18/src/) sin cambios

Pasos:
1. Copiar todos los .vhd de P_30_A/src/ a P_31_A/src/
2. Crear create_bd.tcl nuevo con zynq_ultra_ps_e (ver seccion 4)
3. `python build.py P_31_A create` en el servidor
4. `python build.py P_31_A build` -- sintetizar + implementar
5. Verificar que pasa timing (WNS >= 0)
6. Generar .bit

**Criterio de exito:** bitstream generado sin errores, WNS positivo.

### Fase 2: Preparar firmware (archivos para la KV260)

Archivos a crear:
- `P_31_A/sw/dpu_overlay.dts` -- device tree source
- `P_31_A/sw/shell.json` -- para xmutil
- `P_31_A/sw/convert_bit.sh` -- script para bootgen .bit -> .bit.bin

Pasos:
1. Extraer las direcciones base del Address Editor de Vivado
2. Escribir el .dts con esas direcciones
3. Compilar .dtbo con `dtc`
4. Convertir .bit a .bit.bin con bootgen
5. Copiar .bit.bin + .dtbo + shell.json a la KV260

**Criterio de exito:** `fpgautil -b X.bit.bin -o X.dtbo` carga sin errores,
y `ls /dev/uio*` muestra los dispositivos esperados.

### Fase 3: Software userspace minimo (smoke test)

Archivos a crear:
- `P_31_A/sw/dpu_uio.h` -- funciones mmap para UIO
- `P_31_A/sw/dpu_test.c` -- test minimo: escribir/leer registros del wrapper
- `P_31_A/sw/Makefile` -- compilar con gcc nativo en la KV260

Test minimo:
1. Abrir /dev/uio* para cada periferico
2. Leer el registro de status del dpu_wrapper (debe dar IDLE)
3. Escribir un valor al GPIO_addr, leerlo de vuelta
4. Configurar el DMA MM2S con una transferencia de 1 palabra
5. Verificar que el dato llega al BRAM del wrapper

**Criterio de exito:** registros accesibles, dato de ida y vuelta OK.

### Fase 4: DMA funcional + primer layer

Archivos a crear/modificar:
- `P_31_A/sw/dpu_exec.c` -- adaptacion de P_18/sw/dpu_exec.c para Linux
- `P_31_A/sw/dpu_api.h` -- API comun (layer_cfg_t, etc.)

Cambios principales respecto al bare-metal:
- `Xil_Out32(addr, val)` -> `regs[offset/4] = val` (mmap)
- `Xil_In32(addr)` -> `regs[offset/4]` (mmap)
- `Xil_DCacheFlushRange` -> no necesario (O_SYNC mmap)
- `Xil_DCacheInvalidateRange` -> no necesario (O_SYNC mmap)
- `memcpy(DDR_ADDR, data, n)` -> `memcpy(mmap_ddr + offset, data, n)`
- `usleep(N)` -> `usleep(N)` (funciona igual en Linux)

**Criterio de exito:** Layer 0 (CONV 3->32, 416x416) produce el mismo
CRC que en ZedBoard: `0x8FACA837`.

### Fase 5: Pipeline completo + benchmark

- Cargar pesos (64 MB) via memcpy a DDR mapeada
- Ejecutar 255 capas secuencialmente
- Verificar CRC de cada capa contra ONNX
- Medir latencia total y comparar con ZedBoard

**Criterio de exito:** 255/255 capas bit-exact, mismos CRCs que P_30_A/P_18.

---

## 4. Esqueleto de create_bd.tcl para K26

```tcl
# ==============================================================
# create_bd.tcl -- DPU Block Design para Kria K26 (KV260)
# P_31_A: port de P_18/P_30_A de ZedBoard a KV260
# ==============================================================

create_bd_design "p31a_dpu_bd"

set proj_dir [get_property DIRECTORY [current_project]]
set src_dir [file normalize [file join $proj_dir ../src]]

# --- VHDL sources (identicos a P_30_A, copiados sin cambios) ---
read_vhdl [file join $src_dir mul_s32x32_pipe.vhd]
read_vhdl [file join $src_dir mul_s9xu30_pipe.vhd]
read_vhdl [file join $src_dir mac_unit.vhd]
read_vhdl [file join $src_dir mac_array.vhd]
read_vhdl [file join $src_dir requantize.vhd]
read_vhdl [file join $src_dir conv_engine_v4.vhd]
read_vhdl [file join $src_dir leaky_relu.vhd]
read_vhdl [file join $src_dir maxpool_unit.vhd]
read_vhdl [file join $src_dir elem_add.vhd]
read_vhdl [file join $src_dir fifo_weights.vhd]
read_vhdl [file join $src_dir dpu_stream_wrapper_v4.vhd]
read_vhdl [file join $src_dir dm_s2mm_ctrl.vhd]
update_compile_order -fileset sources_1

# ==============================================================
# 1. Zynq UltraScale+ PS (K26 SOM preset)
# ==============================================================
set zynq [create_bd_cell -type ip -vlnv xilinx.com:ip:zynq_ultra_ps_e:3.5 zynq_ps]

# Aplicar preset del K26 board file (configura DDR4, eMMC, MIO, etc.)
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {apply_board_preset "1"} [get_bd_cells zynq_ps]

# Habilitar interfaces PL necesarias
set_property -dict [list \
    CONFIG.PSU__USE__M_AXI_GP0 {1} \
    CONFIG.PSU__USE__S_AXI_HP0 {1} \
    CONFIG.PSU__USE__IRQ0 {1} \
    CONFIG.PSU__CRL_APB__PL0_REF_CTRL__FREQMHZ {100} \
    CONFIG.PSU__MAXIGP0__DATA_WIDTH {32} \
    CONFIG.PSU__SAXIGP2__DATA_WIDTH {32} \
] $zynq

# ==============================================================
# 2-7. AXI DMA, DataMover, dm_s2mm_ctrl, wrapper, GPIOs
#      (identico a P_18/P_30_A -- solo IPs, no PS-specific)
# ==============================================================
# ... (copiar textualmente de P_18 create_bd.tcl lineas 92-156) ...

# ==============================================================
# 8. Infrastructure
# ==============================================================
set rst [create_bd_cell -type ip -vlnv xilinx.com:ip:proc_sys_reset:5.0 proc_sys_reset_0]

set concat [create_bd_cell -type ip -vlnv xilinx.com:ip:xlconcat:2.1 xlconcat_0]
set_property CONFIG.NUM_PORTS {3} $concat

set ic_gp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_gp0]
set_property -dict [list CONFIG.NUM_MI {4} CONFIG.NUM_SI {1}] $ic_gp0

set ic_hp0 [create_bd_cell -type ip -vlnv xilinx.com:ip:axi_interconnect:2.1 axi_ic_hp0]
set_property -dict [list CONFIG.NUM_MI {1} CONFIG.NUM_SI {2}] $ic_hp0

# ==============================================================
# CONNECTIONS (cambios respecto a P_18 marcados con <<<)
# ==============================================================

# --- Clocks: todo en pl_clk0 (100 MHz) ---
connect_bd_net [get_bd_pins zynq_ps/pl_clk0] \
    [get_bd_pins zynq_ps/maxihpm0_fpd_aclk] \
    [get_bd_pins zynq_ps/saxihp0_fpd_aclk] \
    [get_bd_pins axi_dma_0/s_axi_lite_aclk] \
    [get_bd_pins axi_dma_0/m_axi_mm2s_aclk] \
    [get_bd_pins axi_datamover_0/m_axi_s2mm_aclk] \
    [get_bd_pins axi_datamover_0/m_axis_s2mm_cmdsts_awclk] \
    [get_bd_pins dm_s2mm_ctrl_0/clk] \
    [get_bd_pins dpu_stream_wrapper_0/clk] \
    [get_bd_pins gpio_addr/s_axi_aclk] \
    [get_bd_pins gpio_ctrl/s_axi_aclk] \
    [get_bd_pins axi_ic_gp0/ACLK] \
    [get_bd_pins axi_ic_gp0/S00_ACLK] \
    [get_bd_pins axi_ic_gp0/M00_ACLK] \
    [get_bd_pins axi_ic_gp0/M01_ACLK] \
    [get_bd_pins axi_ic_gp0/M02_ACLK] \
    [get_bd_pins axi_ic_gp0/M03_ACLK] \
    [get_bd_pins axi_ic_hp0/ACLK] \
    [get_bd_pins axi_ic_hp0/S00_ACLK] \
    [get_bd_pins axi_ic_hp0/S01_ACLK] \
    [get_bd_pins axi_ic_hp0/M00_ACLK] \
    [get_bd_pins proc_sys_reset_0/slowest_sync_clk]

# --- Resets ---                                      <<<
connect_bd_net [get_bd_pins zynq_ps/pl_resetn0] \
    [get_bd_pins proc_sys_reset_0/ext_reset_in]

# ... (resto de resets identico a P_18) ...

# --- AXI GP0 -> IC -> slaves ---                    <<<
connect_bd_intf_net [get_bd_intf_pins zynq_ps/M_AXI_HPM0_FPD] \
    [get_bd_intf_pins axi_ic_gp0/S00_AXI]

# ... (M00-M03 identico a P_18) ...

# --- HP0 -> PS DDR ---                              <<<
connect_bd_intf_net [get_bd_intf_pins axi_ic_hp0/M00_AXI] \
    [get_bd_intf_pins zynq_ps/S_AXI_HP0_FPD]

# --- Interrupts ---                                  <<<
connect_bd_net [get_bd_pins xlconcat_0/dout] \
    [get_bd_pins zynq_ps/pl_ps_irq0]

# --- DDR (sin FIXED_IO en US+) ---                   <<<
apply_bd_automation -rule xilinx.com:bd_rule:zynq_ultra_ps_e \
    -config {make_external "FIXED_IO, DDR"} [get_bd_cells zynq_ps]

# ==============================================================
# Address mapping + validate + wrapper
# ==============================================================
assign_bd_address
regenerate_bd_layout
validate_bd_design
save_bd_design

make_wrapper -files [get_files p31a_dpu_bd.bd] -top
set bd_dir [file dirname [get_files p31a_dpu_bd.bd]]
set wrapper_file [file normalize "$bd_dir/hdl/p31a_dpu_bd_wrapper.v"]
add_files -norecurse $wrapper_file
set_property top p31a_dpu_bd_wrapper [current_fileset]
update_compile_order -fileset sources_1
```

Las unicas lineas que cambian son:
1. El IP del PS: `zynq_ultra_ps_e:3.5` en vez de `processing_system7:5.5`
2. Los nombres de pines del PS: `pl_clk0`, `pl_resetn0`, `M_AXI_HPM0_FPD`,
   `S_AXI_HP0_FPD`, `pl_ps_irq0`, `maxihpm0_fpd_aclk`, `saxihp0_fpd_aclk`
3. Las properties del PS: `PSU__*` en vez de `PCW_*`
4. El `apply_bd_automation`: sin `FIXED_IO` (no existe en US+)

Todo lo demas (DMA, DataMover, GPIOs, wrapper, dm_s2mm_ctrl, interconnects,
conexiones de datos) queda identico.

---

## 5. Riesgos y mitigaciones

| Riesgo | Impacto | Mitigacion |
|--------|---------|------------|
| Board preset K26 no disponible en Vivado 2025.2 | No crea BD | Instalar board files: `xilinx.com:kv260_som:*` |
| Direcciones PL diferentes a las hardcodeadas en el SW | UIO falla | Leer direcciones del Address Editor, NO hardcodear |
| `/dev/mem` bloqueado por `CONFIG_STRICT_DEVMEM` | No accede DDR | Usar `udmabuf` en vez de `/dev/mem` |
| CMA insuficiente para 160 MB de datos DPU | DMA falla | Verificar `dmesg | grep cma` muestra >= 200 MB libre |
| DataMover address width 32-bit vs DDR4 4 GB | Acceso limitado | Usar zona baja (<4 GB). Si no basta, reconfigurar a 64-bit |
| AXI data width mismatch (128 vs 32) | Datos corruptos | Vivado auto-inserta width converter. Verificar en BD |
| Timing fail en K26 (diferente fabric) | No genera .bit | K26 es mas rapido que Z7020. Deberia pasar facil |
| UIO numbering no determinista | App abre UIO incorrecto | Usar sysfs para mapear nombre->uioN en runtime |

---

## 6. Checklist final antes de implementar

- [ ] Vivado 2025.2 tiene board files para K26 (`xilinx.com:kv260_som:*`)
- [ ] KV260 conectada por SSH, `uname -r` confirma kernel con fpga-manager
- [ ] `fpgautil` instalado en la KV260
- [ ] `dtc` instalado en la KV260 (o compilar .dtbo en el PC)
- [ ] `bootgen` disponible (PC con Vivado o KV260 con bootgen-xlnx)
- [ ] Copiar todos los .vhd de P_30_A/src/ a P_31_A/src/
- [ ] Verificar que el RTL copiado compila sin errores en XSIM
- [ ] Crear create_bd.tcl adaptado (seccion 4)
- [ ] Crear project.cfg con part xck26-sfvc784-2LV-c

---

## 7. Referencias

- Xilinx Kria firmware generation:
  https://xilinx.github.io/kria-apps-docs/kv260/2022.1/build/html/docs/generating_custom_firmware.html
- KR260 custom PL overlays con UIO:
  https://www.controlpaths.com/2025/12/21/enabling-custom-pl-overlays-kr260/
- Ubuntu overlays sin PetaLinux:
  https://www.controlpaths.com/2025/08/31/ubuntu-overlays-kria/
- Kria DMA userspace:
  https://github.com/OpenHardware-Initiative/kria_dma
- Zynq US+ DMA from userspace:
  https://xilinx-wiki.atlassian.net/wiki/spaces/A/pages/1027702787/Linux+DMA+From+User+Space+2.0
- udmabuf (u-dma-buf):
  https://github.com/ikwzm/udmabuf
- Zynq-7000 to US+ migration guide:
  https://static.eetrend.com/files/2020-01/wen_zhang_/100047000-88375-ug1213-zynq-migration-guide.pdf
- Kria board files / Vivado project:
  https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/Generate_vivado_project_from_boardfile.html
- Kria KR260 custom RTL:
  https://www.hackster.io/whitney-knitter/independent-custom-rtl-designs-on-kria-kr260-d5cd0b
- KR260 DMA dragon:
  https://www.hackster.io/yuricauwerts/slaying-the-dma-dragon-on-the-kria-kr260-a5046e
- Kria bitstream management:
  https://xilinx.github.io/kria-apps-docs/creating_applications/2022.1/build/html/docs/bitstream_management.html
