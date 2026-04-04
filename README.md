# Vivado Projects - ZedBoard (Zynq-7020)

## Requisitos

- Vivado 2025.2 + Vitis 2025.2 (`C:\AMDDesignTools\2025.2\`)
- Python 3
- ZedBoard: USB-JTAG (J17) + USB-UART (J14) con 2 cables micro-USB

## Comandos

```powershell
python build.py <proyecto> <comando>
```

| Comando   | Descripcion                              |
|-----------|------------------------------------------|
| `create`  | Crear proyecto (RTL o Block Design)      |
| `synth`   | Sintetizar                               |
| `impl`    | Implementar (place & route)              |
| `bit`     | Generar bitstream                        |
| `export`  | Exportar .xsa para Vitis (Zynq)          |
| `vitis`   | Crear workspace Vitis + compilar app     |
| `run`     | Programar bitstream + ejecutar ELF       |
| `program` | Cargar solo bitstream en la FPGA         |
| `build`   | synth + impl + bit                       |
| `all`     | create + synth + impl + bit              |
| `gui`     | Abrir proyecto en Vivado GUI             |

## Proyectos

| Proyecto | Descripcion |
|----------|-------------|
| `P_1_blink_led` | Hello world: LED rotando por 8 LEDs (RTL puro) |
| `P_2_zynq_dma` | Zynq PS + AXI DMA loopback + DDR (Block Design + bare-metal C) |
| `P_3_stream_adder` | Modulo AXI-Stream con suma configurable via AXI-Lite + skid buffers |

## Estructura

```
vivado/
├── build.py                        # Script principal
├── tcl/                            # Scripts Vivado TCL
│   ├── create_project.tcl          # Crear proyecto RTL
│   ├── create_bd_project.tcl       # Crear proyecto Block Design
│   ├── synthesize.tcl
│   ├── implement.tcl
│   ├── gen_bitstream.tcl
│   ├── export_hw.tcl               # Exportar .xsa
│   └── program.tcl                 # Programar FPGA
├── ref/                            # Modulos VHDL de referencia
│   ├── HsSkidBuf_dest.vhd         # Skid buffer AXI-Stream
│   ├── axi_lite_OffSet.vhd        # AXI-Lite slave (4 registros)
│   └── S00_AXI_32_reg.vhd         # AXI-Lite slave (32 registros)
├── P_1_blink_led/
│   ├── project.cfg
│   ├── src/blink_led.v
│   ├── constrs/zedboard.xdc
│   └── sim/blink_led_tb.v
├── P_2_zynq_dma/
│   ├── project.cfg
│   ├── src/create_bd.tcl           # Block design TCL
│   └── sw/                         # Bare-metal C + Vitis scripts
├── P_3_stream_adder/
│   ├── project.cfg
│   ├── src/
│   │   ├── HsSkidBuf_dest.vhd     # Skid buffer
│   │   ├── axi_lite_cfg.vhd       # AXI-Lite 32 regs (basado en S00_AXI_32_REG)
│   │   └── stream_adder.vhd       # Top: SkidBuf + Suma + SkidBuf
│   └── sim/stream_adder_tb.vhd
└── ...
```

## Crear nueva practica

1. Crear carpeta `P_N_nombre/` con `src/`, `constrs/`, `sim/`
2. Crear `project.cfg`:

```ini
[project]
name = nombre
part = xc7z020clg484-1
top  = modulo_top

[sources]
src/modulo_top.vhd

[constraints]
constrs/zedboard.xdc

[simulation]
top = modulo_top_tb
sim/modulo_top_tb.vhd
```

3. `python build.py P_N_nombre all`
