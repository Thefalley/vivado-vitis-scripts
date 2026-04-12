# P_401 - HDMI Output desde PL (ZedBoard) - VERIFICADO EN HW

## Estado: FUNCIONA (12 abril 2026)
720p @ 60Hz visible en monitor HDMI. Sin licencias. PL-only.

## Que hemos demostrado
1. El HDMI de la ZedBoard es **libre de licencias** - usa el chip externo ADV7511
2. Se puede generar video **solo desde la PL** sin necesitar Zynq PS ni Vitis
3. El ADV7511 se configura automaticamente via I2C desde una FSM en la PL
4. La MMCM genera 74.25 MHz desde los 100 MHz del oscilador (error 0.031%)

## Arquitectura (todo en PL, cero software)
```
 100 MHz        MMCM         74.25 MHz
  Y9  -------> (x9/12.125) -------+-----> video_timing (720p counters)
                                   |              |
                                   |         pixel_x, pixel_y, DE, HSYNC, VSYNC
                                   |              |
                                   |         color_bars (8 barras RGB)
                                   |              |
                                   |         R[7:0] -> hdmi_d[15:8]
                                   |         G[7:0] -> hdmi_d[7:0]
                                   |
                                   +-----> ODDR -> hdmi_clk (W18)
                                   
 100 MHz -----> i2c_init ---------> SCL/SDA -> ADV7511 (31 registros config)
                  |
                  +---> done (LD1)
```

## Especificaciones
| Parametro | Valor |
|-----------|-------|
| Resolucion | 1280x720 (720p) |
| Frecuencia | 60 Hz |
| Pixel clock | 74.2268 MHz (0.031% error) |
| Bits de color | 16-bit (R+G, sin azul en esta version) |
| Formato ADV7511 | YCbCr 4:2:2 con CSC -> RGB |
| I2C address | 0x72 (write) / 0x39 (7-bit) |
| Registros escritos | 31 |
| Tiempo init | ~200ms (100ms delay + 31 writes I2C) |
| FPGA resources | Minimo (1 MMCM, ~200 LUTs, 1 BRAM=0) |

## LEDs de diagnostico
| LED | Significado | Esperado |
|-----|-------------|----------|
| LD0 | MMCM locked | ON |
| LD1 | I2C config completa | ON (tras ~200ms) |
| LD2 | ADV7511 interrupt | variable |
| LD3 | VSYNC (60Hz) | parpadeo rapido |

## Pinout correcto (ZedBoard Rev D) - VERIFICADO
```
HDMI Data:
  hdmi_d[0]  = Y13      hdmi_d[8]  = AA17
  hdmi_d[1]  = AA13     hdmi_d[9]  = Y15
  hdmi_d[2]  = AA14     hdmi_d[10] = W13
  hdmi_d[3]  = Y14      hdmi_d[11] = W15
  hdmi_d[4]  = AB15     hdmi_d[12] = V15
  hdmi_d[5]  = AB16     hdmi_d[13] = U17
  hdmi_d[6]  = AA16     hdmi_d[14] = V14
  hdmi_d[7]  = AB17     hdmi_d[15] = V13

HDMI Control:
  hdmi_clk   = W18      (pixel clock via ODDR)
  hdmi_de    = U16      (data enable)
  hdmi_hsync = V17      (horizontal sync)
  hdmi_vsync = W17      (vertical sync)
  hdmi_int_n = W16      (interrupt, active low)
  hdmi_spdif = U15      (audio, no usado)

HDMI I2C:
  hdmi_scl   = AA18     (con pull-up)
  hdmi_sda   = Y16      (con pull-up)
```

## Registros ADV7511 (configuracion completa que funciona)
```
Reg   Val   Proposito
0x41  0x10  Power up
0xD6  0xC0  HPD always high (override hot-plug detect)
0x98  0x03  ADI Required
0x99  0x02  ADI Required
0x9A  0xE0  ADI Required
0x9C  0x30  PLL filter
0x9D  0x61  Clock divide (CRITICO: 0x01 NO funciona!)
0xA2  0xA4  ADI Required
0xA3  0xA4  ADI Required
0xA5  0x44  ADI Required
0xAB  0x40  ADI Required
0xBA  0xA0  Clock delay +0.8ns
0xD0  0x00  DDR negative edge disable
0xD1  0xFF  ADI Required
0xDE  0x9C  ADI Required (TMDS clock)
0xE0  0xD0  ADI Required
0xE4  0x60  VCO swing reference
0xF9  0x00  VCO swing reference
0x15  0x01  Input ID=1: 16-bit YCbCr 4:2:2, separate sync
0x16  0x38  Output: 4:4:4, 8-bit, Style 1
0x17  0x02  16:9 aspect, DE-based timing
0x18  0xC6  CSC enable (YCbCr input -> RGB output)
0x40  0x80  General Control packet enable
0x48  0x10  Video input justification
0x49  0xA8  Dither 4:2:2 to 4:4:4
0x4C  0x00  Color depth not indicated
0x55  0x00  RGB in AVI InfoFrame
0x56  0x08  Aspect ratio
0xAF  0x04  HDMI mode, HDCP disabled
0x96  0x20  HPD interrupt clear
```

## Lo que aprendimos (errores que cometimos)
1. **Pines cruzados**: DE, HSYNC, VSYNC, INT estaban todos en pines incorrectos.
   La fuente fiable es el [Digilent Master XDC](https://github.com/Digilent/digilent-xdc/blob/master/Zedboard-Master.xdc).
2. **Registro 0x9D**: DEBE ser 0x61. Con 0x01 el PLL TMDS del ADV7511 no bloquea.
3. **Registros "ADI Required"**: Son ~10 registros sin documentacion publica pero
   obligatorios. Estan en el kernel Linux (`adv7511_drv.c`) y en la referencia Avnet.
4. **16-bit != 24-bit**: Con 16 pines de datos no puedes hacer RGB 4:4:4 directo.
   Configuras como YCbCr 4:2:2 y dejas que el CSC del ADV7511 convierta.

## Como programar
```bash
# Desde este PC (ZedBoard conectada por JTAG USB):
xsct P_401_hdmi_test/program.tcl
```

Si hay dos targets en la cadena JTAG (dos placas), el script usa `targets -set 4`.

## Como compilar (servidor)
```bash
scp -i ~/.ssh/pc-casa -r P_401_hdmi_test/ jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 "E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test/vivado/build.tcl"
scp -i ~/.ssh/pc-casa jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/P_401_hdmi_test/hdmi_test.bit ./
```

## Mejoras futuras
- **Color correcto**: Convertir RGB a YCbCr en PL antes de enviar al ADV7511
- **24-bit DDR**: Usar DDR clocking para enviar 24 bits por ciclo (color completo)
- **Texto en pantalla**: Añadir font ROM y character buffer para imprimir texto
- **Framebuffer**: Conectar con PS via AXI para enviar imagenes desde DDR
- **Audio**: El SPDIF pin esta disponible para audio digital
