# P_400 - Ethernet Debug Channel (ZedBoard)

## Que es esto
Canal de debug por Ethernet: desde un script Python en el PC puedes leer/escribir
cualquier registro de memoria del Zynq (PS + PL) sin usar JTAG.

Tambien incluye TCP echo server para verificar conectividad basica (ping).

## Arquitectura
```
PC (Python)                    ZedBoard (bare-metal)
eth_debug.py  ---UDP:7777--->  lwIP app
              <--respuesta---   lee/escribe Xil_In32/Out32
                                sobre cualquier direccion AXI
```

## Configuracion de red

### PC (Windows)
Adaptador Ethernet: IP estatica
```
IP:      192.168.1.100
Mascara: 255.255.255.0
Gateway: 192.168.1.1
```
Comando para configurar (PowerShell como admin):
```powershell
netsh interface ipv4 set address "Ethernet" static 192.168.1.100 255.255.255.0 192.168.1.1
```
Verificar:
```
netsh interface ipv4 show addresses "Ethernet"
```

### ZedBoard
Configurado en el firmware (main.c):
```
IP:      192.168.1.10
Mascara: 255.255.255.0
MAC:     00:0a:35:00:01:02
```

### Conexion fisica
Cable Ethernet directo: PC <-> ZedBoard (puerto Ethernet, no USB).
No necesita switch ni router.

## Archivos
```
vivado/
  create_bd.tcl        # Crea block design Zynq PS (GEM0 + UART) -> XSA
sw/
  main.c               # App lwIP: TCP echo + UDP debug con read/write memoria
  platform_eth.c       # Init: caches, GIC, timer SCU para lwIP
  platform_eth.h       # Header
  create_vitis.tcl     # Script XSCT para crear workspace Vitis + build
pc/
  eth_debug.py         # Herramienta Python para el PC
```

## Como compilar (en el servidor)

### Paso 1: Subir archivos
```bash
scp -i ~/.ssh/pc-casa -r P_400_eth_debug/ jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/
```

### Paso 2: Generar XSA (Vivado)
```bash
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 "cd C:/Users/jce03/Desktop/claude/vivado-server/P_400_eth_debug && E:/vivado-instalado/2025.2.1/Vivado/bin/vivado.bat -mode batch -source vivado/create_bd.tcl"
```
Resultado: `system.xsa` en la raiz del proyecto.

### Paso 3: Compilar app (Vitis/XSCT)
```bash
ssh -i ~/.ssh/pc-casa jce03@100.73.144.105 "cd C:/Users/jce03/Desktop/claude/vivado-server/P_400_eth_debug && E:/vivado-instalado/2025.2.1/Vitis/bin/xsct.bat sw/create_vitis.tcl"
```
Resultado: `vitis_ws/p400_eth/Debug/p400_eth.elf`

### Paso 4: Traer resultados al PC local
```bash
scp -i ~/.ssh/pc-casa jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/P_400_eth_debug/system.xsa ./
scp -i ~/.ssh/pc-casa jce03@100.73.144.105:C:/Users/jce03/Desktop/claude/vivado-server/P_400_eth_debug/vitis_ws/p400_eth/Debug/p400_eth.elf ./
```

## Como programar la placa

### Con XSCT (linea de comandos)
```bash
# Desde el PC local (ZedBoard conectada por USB-JTAG)
C:/AMDDesignTools/2025.2/Vitis/bin/xsct.bat

# Dentro de XSCT:
connect
targets -set -filter {name =~ "ARM*#0"}
rst -system
fpga system.xsa
# O si tienes el .bit extraido:
# fpga system_wrapper.bit
dow p400_eth.elf
con
```

### Con Vivado Hardware Manager (GUI)
1. Abrir Vivado -> Open Hardware Manager -> Auto Connect
2. Program device con el .bit
3. Desde XSCT o System Debugger, cargar el .elf

## Como usar el debug Ethernet

### Verificar conexion basica
```bash
ping 192.168.1.10
```
Debe responder. Si no:
- Verifica cable Ethernet
- Verifica IP del PC (192.168.1.100)
- Mira la consola UART (115200 baud) para ver mensajes de arranque

### Herramienta Python - Modo interactivo
```bash
cd P_400_eth_debug/pc
python eth_debug.py
```
```
ETH Debug Shell -> 192.168.1.10:7777
Commands: ping, read <addr>, write <addr> <val>, dump <addr> [n], quit

zed> ping
pong

zed> read 0xF8000000
0xF8000000 = 0x00000011   (SLCR device ID: Zynq 7020)

zed> dump 0xF8000000 4
0xF8000000 = 0x00000011
0xF8000004 = 0x00000000
0xF8000008 = 0x00000000
0xF800000C = 0x00000000

zed> write 0x43C00000 0x00000001
W [0x43C00000] <- 0x00000001 OK

zed> quit
```

### Modo one-shot (para scripts)
```bash
python eth_debug.py ping
python eth_debug.py read 0xF8000000
python eth_debug.py dump 0x43C00000 16
python eth_debug.py write 0x43C00000 0x01
```

### Direcciones utiles
| Direccion    | Que es                          |
|--------------|---------------------------------|
| 0xF8000000   | SLCR base (PS config)           |
| 0xF8000110   | ARM_PLL_CTRL                    |
| 0xE0001000   | UART1 base                      |
| 0x43C00000   | AXI GP0 periferico (si existe)  |
| 0xF8F00200   | GIC distributor                 |

## Consola UART (debug serie)
Puerto: USB-UART de la ZedBoard (aparece como COM port)
Config: 115200 baud, 8N1

Al arrancar veras:
```
========================================
  P_400 ETH Debug - ZedBoard
========================================
Board IP: 192.168.1.10
  TCP echo   -> port 7
  UDP debug  -> port 7777
----------------------------------------
Ready! From PC run:
  ping 192.168.1.10
  python eth_debug.py ping
  python eth_debug.py read 0xF8000000
========================================
```

## Troubleshooting

| Problema | Causa probable | Solucion |
|----------|---------------|----------|
| No hay ping | Cable, IP mal, app no arrancó | Verificar UART, revisar IP del PC |
| Timeout en eth_debug.py | Firewall Windows bloquea UDP | Deshabilitar firewall o crear regla para puerto 7777 |
| "xemac_add failed" en UART | GEM0 no configurado en XSA | Regenerar block design con GEM0 habilitado |
| Link no sube | PHY no negocia | Probar cable cruzado, verificar LEDs del conector RJ45 |
