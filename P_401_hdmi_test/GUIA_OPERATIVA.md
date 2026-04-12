# P_401 - HDMI Test (Barras de Color en ZedBoard)

## Que es esto
Proyecto PL-only (sin Zynq PS ni Vitis) que genera barras de color 720p
por la salida HDMI de la ZedBoard. El ADV7511 se configura automaticamente
con una maquina de estados I2C en la PL.

Solo necesitas programar el .bit y conectar un monitor HDMI.

## Arquitectura
```
100 MHz --MMCM--> 74.25 MHz (pixel clock)
                      |
              video_timing (720p@60Hz)
                      |
              color_bars (8 barras)
                      |
              hdmi_top -> HD_D[15:0], DE, HSYNC, VSYNC, CLK -> ADV7511 -> HDMI
                      |
              i2c_init -> HD_SCL, HD_SDA (configura ADV7511 al arrancar)
```

### Que se ve en la pantalla
8 barras verticales: Blanco | Amarillo | Cyan | Verde | Magenta | Rojo | Azul | Negro

Nota: Como usamos 16 bits de datos (R en D[15:8], G en D[7:0]), el canal azul
no se transmite. Las barras seran visibles pero el azul puro aparecera negro.
Para color completo se necesita modo DDR de 24 bits (mejora futura).

### LEDs de debug (en la placa)
| LED | Significado                    |
|-----|--------------------------------|
| LD0 | MMCM locked (debe estar ON)    |
| LD1 | I2C config hecha (ON = OK)     |
| LD2 | ADV7511 interrupt (estado HPD) |
| LD3 | VSYNC (parpadea a 60 Hz)       |

## Archivos
```
src/
  video_timing.vhd   # Generador de timing 720p (1280x720, 60Hz)
  color_bars.vhd     # 8 barras verticales, 24-bit RGB
  i2c_init.vhd       # Master I2C que configura ADV7511 (12 registros)
  hdmi_top.vhd       # Top: MMCM + timing + barras + I2C + ODDR clk
vivado/
  zedboard_hdmi.xdc  # Constraints: pines HDMI, LEDs, reloj 100 MHz
  build.tcl          # Script batch: synth + impl + bitstream
sim/
  tb_hdmi_top.vhd    # Testbench (solo timing + barras, sin MMCM)
  batch_sim.tcl      # Simulacion batch
  open_sim.tcl       # Simulacion con GUI
```

## Como simular

### Batch en servidor
```bash
scp -i ~/.ssh/pc-casa -r P_401_hdmi_test/ jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/

ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 "cd C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test && E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source sim/batch_sim.tcl"
```

### GUI local con xsim
```bash
cd C:/project/vivado/P_401_hdmi_test/sim_local
C:/AMDDesignTools/2025.2/Vivado/bin/xvhdl.bat ../src/video_timing.vhd ../src/color_bars.vhd ../sim/tb_hdmi_top.vhd
C:/AMDDesignTools/2025.2/Vivado/bin/xelab.bat work.tb_hdmi_top -snapshot hdmi_sim -debug all
C:/AMDDesignTools/2025.2/Vivado/bin/xsim.bat hdmi_sim -gui -tclbatch ../sim/open_sim.tcl
```

### Que verificar
- hsync pulsa cada 1650 pixeles (~22.2 us)
- vsync pulsa cada 750 lineas (~16.7 ms = 60 Hz)
- data_enable activo durante 1280 pixeles por linea
- pixel_x cuenta 0..1279, pixel_y cuenta 0..719
- rgb cambia de color cada 160 pixeles (8 barras)

## Como compilar (en el servidor)

### Paso 1: Subir archivos
```bash
scp -i ~/.ssh/pc-casa -r P_401_hdmi_test/ jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/
```

### Paso 2: Synth + Impl + Bitstream
```bash
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 "cd C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test && E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source vivado/build.tcl"
```
Resultado: `hdmi_top.bit` en la raiz del proyecto.

### Paso 3: Traer bitstream al PC
```bash
scp -i ~/.ssh/pc-casa jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test/hdmi_top.bit ./
```

## Como programar la placa

### Conexion fisica
1. USB-JTAG: conectar ZedBoard al PC (cable micro-USB al conector PROG)
2. HDMI: conectar cable HDMI al conector de salida de la ZedBoard -> monitor
3. Encender la ZedBoard

### Programar con Vivado GUI
```bash
C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat
```
1. Open Hardware Manager -> Open Target -> Auto Connect
2. Program Device -> seleccionar hdmi_top.bit -> Program

### Programar por linea de comandos
```tcl
# Crear archivo program.tcl:
open_hw_manager
connect_hw_server
open_hw_target
set_property PROGRAM.FILE {hdmi_top.bit} [get_hw_devices xc7z020_1]
program_hw_devices [get_hw_devices xc7z020_1]
close_hw_manager
```
```bash
C:/AMDDesignTools/2025.2/Vivado/bin/vivado.bat -mode batch -source program.tcl
```

## Que esperar al programar

### Secuencia de arranque (observar LEDs)
1. **LD0 se enciende** (1-2 ms): MMCM ha bloqueado a 74.25 MHz
2. **Pausa ~100 ms**: i2c_init espera estabilizacion del ADV7511
3. **LD1 se enciende** (~200 ms): 12 registros I2C escritos correctamente
4. **LD3 parpadea** (60 Hz): VSYNC activo, video saliendo
5. **Monitor muestra barras de color**

### Si algo no funciona

| Sintoma | LED estado | Causa probable | Solucion |
|---------|-----------|----------------|----------|
| Pantalla negra, LD0 OFF | LD0=OFF | MMCM no bloquea | Verificar reloj 100 MHz, revisar constraints |
| Pantalla negra, LD0 ON, LD1 OFF | LD0=ON, LD1=OFF | I2C falla | Verificar pines SCL/SDA en XDC |
| Pantalla negra, LD1 ON | LD0=ON, LD1=ON | HSYNC/VSYNC pin incorrecto | Probar intercambiar HSYNC<->VSYNC en XDC |
| Colores raros | Todo ON | Mapping de datos incorrecto | Ajustar registros ADV7511 o mapping en hdmi_top |
| Imagen estable pero sin azul | Todo OK | Normal: 16 bits, sin canal B | Esperado en esta version |

## Configuracion ADV7511 (referencia)
La maquina de estados i2c_init escribe estos registros en orden:

| Reg  | Valor | Funcion                    |
|------|-------|----------------------------|
| 0x41 | 0x10  | Power up                   |
| 0x98 | 0x03  | Required (datasheet)       |
| 0x9A | 0xE0  | Required                   |
| 0x9C | 0x30  | Required                   |
| 0x9D | 0x01  | Required                   |
| 0xA2 | 0xA4  | Required                   |
| 0xA3 | 0xA4  | Required                   |
| 0xAF | 0x06  | HDMI mode enable           |
| 0x15 | 0x00  | Input: 24-bit RGB 4:4:4    |
| 0x16 | 0x30  | Output: RGB, 8-bit depth   |
| 0x48 | 0x08  | Right-justified data       |
| 0xD6 | 0xC0  | HPD always high (override) |

Direccion I2C del ADV7511: 0x72 (8-bit write) / 0x39 (7-bit)
