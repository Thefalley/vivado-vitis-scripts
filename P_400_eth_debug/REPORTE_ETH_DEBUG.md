# Ethernet Debug para ZedBoard - Reporte Completo

## Estado: VERIFICADO EN HARDWARE (12 abril 2026)
- Ping: 10/10 paquetes, 0% perdidos, media 6ms
- UDP debug: ping/read/write/dump funcionando
- DDR: OK (verificado via JTAG y via Ethernet)

## Que es
Canal de debug por Ethernet para ZedBoard (Zynq-7020). Reemplaza printf por
UDP. Desde Python en el PC puedes leer/escribir cualquier registro del Zynq
sin JTAG ni UART.

## Para otros agentes: como usar en tu proyecto

### Archivos necesarios (copiar a tu src/)
```
lib/
  eth_debug.h       # API publica: eth_debug_init, eth_printf, eth_debug_poll
  eth_debug.c       # Implementacion: lwIP, UDP, TCP echo, read/write commands
  platform_eth.h    # Platform init header
  platform_eth.c    # GIC, SCU timer, caches para lwIP
```

### Requisitos del BSP (Vitis)
El BSP debe incluir lwip220. En el script XSCT de creacion:
```tcl
bsp setlib -name lwip220
bsp config api_mode          RAW_API
bsp config lwip_dhcp         false
bsp config lwip_udp          true
bsp config lwip_tcp          true
bsp config mem_size           262144
bsp config memp_n_pbuf        1024
bsp config n_rx_descriptors   64
bsp config n_tx_descriptors   32
bsp config pbuf_pool_size     2048
bsp config phy_link_speed     CONFIG_LINKSPEED_AUTODETECT
```

### Codigo minimo en tu main.c
```c
#include "eth_debug.h"

int main(void) {
    eth_debug_init();                        // una vez al arrancar
    eth_printf("Mi proyecto arranco!\n");     // printf por Ethernet

    while (1) {
        eth_debug_poll();                    // OBLIGATORIO en el loop
        // ... tu codigo ...
        eth_printf("resultado = %d\n", val); // usar en cualquier sitio
    }
}
```

### En el PC (Windows)
```bash
# Configurar IP del adaptador Ethernet (una vez, como admin):
netsh interface ipv4 set address "Ethernet" static 192.168.1.100 255.255.255.0 192.168.1.1

# Herramienta interactiva:
python P_400_eth_debug/pc/eth_debug.py

# Comandos one-shot:
python eth_debug.py ping
python eth_debug.py read 0xF8000530       # lee PSS_IDCODE
python eth_debug.py dump 0x43C00000 16    # dump 16 registros AXI
python eth_debug.py write 0x43C00000 0x01 # escribe registro
```

### Forzar ping por el adaptador correcto
Si tu PC tiene Wi-Fi en la misma subred 192.168.1.x:
```bash
ping -S 192.168.1.100 192.168.1.10
```

## Configuracion de red
| Dispositivo | IP | Mascara | Puerto |
|-------------|-----|---------|--------|
| ZedBoard | 192.168.1.10 | 255.255.255.0 | UDP 7777, TCP 7 |
| PC | 192.168.1.100 | 255.255.255.0 | - |

MAC address de la placa: 00:0a:35:00:01:02

## Como programar la ZedBoard

### CRITICO: Secuencia FSBL (la unica que funciona)
```tcl
# program.tcl - ejecutar con: xsct program.tcl
connect
after 2000
# 1. Programar FPGA
targets -set -nocase -filter {name =~ "*7z*" || name =~ "*PL*" || name =~ "*xc7z*"}
fpga <bitstream.bit>
after 2000
# 2. Cargar y ejecutar FSBL (inicializa DDR, clocks, PHY)
targets -set -nocase -filter {name =~ "*A9*#0" || name =~ "*Cortex*#0"}
rst -processor
dow <fsbl.elf>
con
after 5000
stop
# 3. Cargar y ejecutar aplicacion
rst -processor
dow <app.elf>
con
```

### NUNCA hacer esto (no funciona en esta ZedBoard):
- `ps7_init.tcl` directamente sin FSBL -> DDR no se inicializa
- Programar solo el PS sin bitstream -> "End of startup: LOW"
- Usar `rst -system` -> DAP sticky errors, ARM cores desaparecen

### XSA que funciona
La XSA DEBE tener la config DDR correcta para ZedBoard (MT41J128M16HA-15E).
Si el servidor no tiene board files de ZedBoard, usar la XSA de P_101:
`P_101_bram_ctrl/build/bram_ctrl.xsa`

## Archivos del proyecto P_400
```
P_400_eth_debug/
  lib/                     # LIBRERIA REUTILIZABLE
    eth_debug.h            #   API: eth_debug_init, eth_printf, eth_debug_poll
    eth_debug.c            #   Implementacion lwIP + UDP commands
    platform_eth.h         #   Platform init header
    platform_eth.c         #   GIC + SCU timer + caches
    example_main.c         #   Ejemplo minimo de uso
  sw/                      # FUENTES ORIGINALES DEL DEMO
    main.c                 #   App completa con TCP echo + UDP debug
    platform_eth.c/.h      #   Platform init
    create_vitis.tcl       #   Script para crear workspace Vitis
  vivado/
    create_bd.tcl          #   Block design Zynq PS (necesita board files)
  pc/
    eth_debug.py           #   Herramienta Python para PC
  hw_p101/                 # BITSTREAM + PS_INIT DE P_101 (funciona)
    bram_ctrl.bit          #   Bitstream con DDR correcto
    ps7_init.tcl           #   PS init script
  p101_working.xsa         # XSA de P_101 (DDR verificado)
  fsbl.elf                 # First Stage Boot Loader
  p400_eth.elf             # Aplicacion lwIP compilada
  program.tcl              # Script XSCT para programar
  GUIA_OPERATIVA.md        # Guia paso a paso
```

## Protocolo UDP (puerto 7777)
| Comando | Respuesta | Ejemplo |
|---------|-----------|---------|
| `ping` | `pong` | `ping` -> `pong` |
| `read <hex>` | `<addr> = <value>` | `read 0xF8000530` -> `0xF8000530 = 0x03B27093` |
| `write <hex> <hex>` | `W [addr] <- val OK` | `write 0x43C00000 0x01` |
| `dump <hex> [n]` | N lineas addr=val | `dump 0xE000B000 4` |
| (otro) | lista de comandos | |

## Troubleshooting
| Problema | Causa | Solucion |
|----------|-------|----------|
| Ping va por Wi-Fi (responde .122) | Wi-Fi en misma subred | `ping -S 192.168.1.100 <ip>` |
| DDR lee 0xFFFFFFFF | XSA sin board files ZedBoard | Usar XSA de P_101 |
| DAP sticky errors | Intentos fallidos previos | Power cycle + secuencia FSBL |
| "End of startup: LOW" | Bitstream PS-only sin PL | Usar bitstream de P_101 |
| No hay ARM cores en XSCT | DAP corrupto | Power cycle, NO usar rst -system |
| Firewall bloquea UDP | Windows Firewall | Crear regla para puerto 7777 |

## Adaptador JTAG
- Tipo: FTDI FT232H (Digilent)
- VID:PID = 0403:6014
- Serial: 210248452501
- Nota: XSCT a veces no lo detecta. Vivado hw_manager siempre lo ve.
