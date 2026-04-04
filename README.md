# Vivado Projects - ZedBoard (Zynq-7020)

## Requisitos

- Vivado 2025.2 (`C:\AMDDesignTools\2025.2\Vivado\bin` en PATH)
- Python 3
- ZedBoard conectada por USB-JTAG (para `program`)

## Comandos

```powershell
python build.py <proyecto> <comando>
```

| Comando   | Descripcion                          |
|-----------|--------------------------------------|
| `create`  | Crear proyecto Vivado desde project.cfg |
| `synth`   | Sintetizar                           |
| `impl`    | Implementar (place & route)          |
| `bit`     | Generar bitstream                    |
| `program` | Cargar bitstream en la FPGA          |
| `build`   | synth + impl + bit                   |
| `all`     | create + synth + impl + bit          |
| `gui`     | Abrir proyecto en Vivado GUI         |

## Ejemplos

```powershell
# Crear proyecto y compilar todo
python build.py P_1_blink_led all

# Solo compilar (proyecto ya creado)
python build.py P_1_blink_led build

# Cargar en la ZedBoard
python build.py P_1_blink_led program

# Abrir en Vivado GUI
python build.py P_1_blink_led gui

# Pasos sueltos encadenados
python build.py P_1_blink_led synth impl
```

## Estructura

```
vivado/
├── build.py                    # Script principal
├── tcl/                        # Scripts Vivado TCL
│   ├── create_project.tcl
│   ├── synthesize.tcl
│   ├── implement.tcl
│   ├── gen_bitstream.tcl
│   └── program.tcl
├── P_1_blink_led/              # Practica 1: Blink LED
│   ├── project.cfg             # Config: top, sources, constraints, sim
│   ├── src/                    # RTL sources
│   ├── constrs/                # Constraints (.xdc)
│   └── sim/                    # Testbenches
├── P_2_.../                    # Practica 2: ...
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
src/modulo_top.v

[constraints]
constrs/zedboard.xdc

[simulation]
top = modulo_top_tb
sim/modulo_top_tb.v
```

3. `python build.py P_N_nombre all`
