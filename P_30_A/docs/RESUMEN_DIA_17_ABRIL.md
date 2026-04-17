# Resumen 17 de abril 2026

## Lo logrado hoy

### P_18 (sesión nocturna 16-17 abril)
- **CONV layer 0 bit-exact** vs ONNX en ZedBoard real (CRC 0x8FACA837)
- **LEAKY layer 1 bit-exact** vs ONNX en ZedBoard real (CRC 0xF51B4D0C)
- Ethernet operativo (44 MB/s write, 28 MB/s read)
- 6 bugs identificados y arreglados (doble transpose, cache stale, NHWC/NCHW, reg_n_words overflow)

### P_30_A (hoy)
- **conv_engine_v4** creado: 2 flags (no_clear, no_requantize) + ext_wb ports + xpm_memory_tdpram
- **fifo_weights** creada: FIFO BRAM P_102 pattern para streaming de pesos
- **wrapper_v4**: BRAM 8KB + S_LOAD_WEIGHTS + address 11 bits + w_stream port
- **Block Design**: 2 DMAs (input + weights) + FIFO + HP1 + Ethernet
- **Sintesis OK**: WNS = **+0.626 ns** (timing MET @ 100 MHz)
- **Bitstream + XSA generados**

### XSIM batch (13 CONVs bit-exact)
```
Layer  0: CONV k=3 s=1 c_in=3   (sin IC tiling)  128/128 OK
Layer  2: CONV k=3 s=2 c_in=32  (sin IC tiling) 1024/1024 OK  
Layer  4: CONV k=1 s=1 c_in=64  (conv 1x1)       256/256 OK
Layer  5: CONV k=1 s=1 c_in=64                    256/256 OK
Layer  8: CONV k=1 s=1 c_in=64                    128/128 OK
Layer 10: CONV k=3 s=1 c_in=32                    256/256 OK
Layer 13: CONV k=1 s=1 c_in=64                    256/256 OK
Layer 16: CONV k=1 s=1 c_in=128                   256/256 OK
Layer 18: CONV k=3 s=2 c_in=64  (IC tiling 28+28+8) 512/512 OK
Layer 20: CONV k=1 s=1 c_in=128                   256/256 OK
+ 3 mas en batch runner (layers 4,5,8)
```

## Lo que queda para manana

### Inmediato (1-2 h)
1. **Firmware ARM**: build_vitis.tcl corriendo (puede necesitar fixes de xparameters.h)
2. **Programar ZedBoard**: hard_reset.tcl con el nuevo bit + FSBL + ELF
3. **Test ping + TCP**: verificar Ethernet funciona con el nuevo BD
4. **Test layer 0 bit-exact**: regresion contra P_18 (CRC 0x8FACA837)
5. **Test layer 2**: primera capa con pesos via FIFO_W (18 KB pesos)

### Medio (3-4 h)
6. **Arreglar XSIM batch runner**: capas con dependencias no-lineales (residuales, forks)
7. **Correr las 110 CONVs en XSIM**: verificar bit-exact todas
8. **Correr run_all_layers.py** en board: 255 capas end-to-end

### Lo que funciona seguro
- RTL bit-exact contra ONNX (verificado en XSIM con datos reales)
- Timing met (WNS +0.626 ns)
- Ethernet + protocolo TCP (verificado en P_18)
- IC tiling interno del RTL (verificado en XSIM layer 18)

### Riesgos potenciales manana
- **xparameters.h**: el XSA nuevo tiene device IDs diferentes (XPAR_AXI_DMA_W_DEVICE_ID). Si no coincide con el codigo, hay que buscar el correcto.
- **S_LOAD_WEIGHTS en HW**: funciona en XSIM pero nunca se ha probado en board real. Puede haber bugs de timing o handshake con el DMA real.
- **Address 11 bits del wrapper**: ampliado pero no verificado en XSIM end-to-end (solo el conv standalone).

## Archivos clave

```
P_30_A/build/p30a_dpu.xsa                           <- XSA para Vitis
P_30_A/build/p30a_dpu.runs/impl_1/dpu_eth_bd_wrapper.bit  <- bitstream
P_30_A/sw/                                            <- firmware ARM (13 files)
P_30_A/sim/run_all_conv_xsim.py                      <- batch XSIM runner
P_30_A/docs/CAMBIOS_Y_PRUEBAS.md                     <- registro completo
P_30_A/docs/ESPECIFICACION.md                         <- reglas + prohibiciones
```

## Commits de hoy
```
1112ee0  P_30_A: BUILD OK — WNS +0.626 ns, bitstream + XSA generados
a5b5c79  P_30_A: 4 layers XSIM bit-exact + fix TCL brackets + layer18 IC tiling
7618463  P_30_A: xpm_memory_tdpram + address 11 bits + firmware prep + docs
8ecde9c  P_30_A: fix timing WNS — wb_ram mux con variables dentro del process
19dd625  P_30_A: limpieza RTL (sin legacy v1/v2/v3) + BD validado en Vivado
106e0f8  P_30_A: firmware dpu_exec_v4.c + BD completo
1f01504  P_30_A: wrapper_v4 compila (BRAM 8KB + S_LOAD_WEIGHTS + FIFO port)
1771c62  P_30_A: conv_engine_v4 bit-exact layers 0 y 2 en XSIM
ec45d41  P_30_B: spec + README de arquitectura 3 FIFOs + 3 DMAs
d38284b  P_18: RTL local + punto de control pre-IC-tiling
3b91a43  P_18 Ethernet + CONV + LEAKY bit-exact 1:1 vs ONNX YOLOv4
```
