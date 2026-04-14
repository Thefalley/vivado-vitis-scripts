# Analisis de Calidad de Tests -- conv_engine YOLOv4

## Veredicto

Los tests demuestran que la aritmetica del conv_engine (MAC + requantize) es
bit-exact para configuraciones pequenas con ic_tile = c_in. Eso es real y no
esta inflado. Sin embargo, **los tests son insuficientes para reclamar que el
conv_engine funciona correctamente para YOLOv4**. Las razones son concretas:
(1) hay 6 capas que FALLAN en HW y no se han investigado, (2) el IC tiling
--requerido por la mayoria de capas reales-- no se ha probado en HW, (3) el
OC tiling tampoco, (4) las 110 capas se reducen a solo 4 configuraciones HW
distintas, y (5) 44 capas ni siquiera se han ejecutado. Un ingeniero que mire
esto y diga "funciona" estaria mintiendo. Funciona la aritmetica basica; no
se ha demostrado que el sistema completo funcione.


## 1. Los expected values: son de fiar?

### Fuente: Python manual, NO onnxruntime

Los expected values se calculan con `compute_expected()` en gen_layer_tests.py,
que implementa la convolucion con nested for-loops en Python puro. NO usa
onnxruntime. La formula es:

```
acc = bias[oc]
for (kh, kw, ic): acc += (x[ic,ih,iw] - x_zp) * (w[oc,ic,kh,kw] - w_zp)
prod = acc * M0 + 2^(n-1)
result = clamp(prod >> n + y_zp, -128, 127)
```

### Verificacion contra onnxruntime: SOLO 1 CAPA

ONNXRT_VERIFICATION.txt muestra que se verifico **unicamente la capa 0**
(layer 0, c_in=3, 3x3 s=1 p=1) contra onnxruntime. Resultado: 2048/2048
bytes identicos. Esto confirma que la formula Python es correcta para ESA
capa.

Pero SOLO se verifico 1 de 110 capas contra onnxruntime. Las otras 109
confian exclusivamente en que la formula Python es universalmente correcta.

### Riesgo de bug compartido Python-VHDL

La formula Python fue escrita para replicar exactamente el VHDL. Si hay un
bug en ambos (ej: manejo incorrecto de w_zp != 0, o overflow en un caso
particular de M0 * acc), ambos darian el mismo resultado incorrecto y los
tests pasarian. La verificacion contra onnxruntime mitiga esto, pero solo
se hizo para 1 capa con w_zp=0 y c_in=3.

**Mitigacion parcial**: los stress tests en simulacion (STRESS_TEST_RESULTS.txt)
prueban extremos (M0=2^31-1, acc overflow, MIN_INT32 bias), pero tambien
comparan contra la misma formula Python. No hay un oraculo independiente
para esos casos.

**Veredicto**: La formula es correcta para la capa verificada. Para las demas,
es *muy probable* que sea correcta (la matematica es simple), pero no esta
DEMOSTRADO.


## 2. Los inputs son representativos?

### Tipo: SINTETICOS, formula determinista

```python
val = ((c * 37 + r * 17 + col * 7 + c * r * 3) % 256) - 128
```

Esto produce el MISMO patron para todas las capas con el mismo c_in_test/crop.
Se confirmo que layers 014, 050, 100 empiezan con la misma secuencia
(-128, -121, -114, ...).

### Cobertura del rango

La formula genera valores en todo el rango [-128, 127] (confirmado en los
archivos .c). Esto es aceptable para verificar aritmetica.

### Distribucion: NO representativa de datos reales

Datos reales de YOLOv4 tienen distribucion aproximadamente gaussiana centrada
en el zero-point, con la mayoria de activaciones cerca de 0 despues de ReLU
(o Leaky ReLU). El patron sintetico tiene distribucion uniforme, lo cual
significa:
- Los acumuladores en el test alcanzan valores diferentes a los reales
- Con c_in_test=5 y pesos reales (calibrados para c_in=256), el acumulador
  es ~50x mas pequeno que en produccion
- El bias (real, del ONNX) domina el resultado, enmascarando posibles errores
  de la convolucion

### Pesos: REALES del ONNX

Los pesos SI son reales, extraidos de yolov4_int8_qop.onnx. Verificado por
spot-check en el audit. Esto es lo unico que conecta estos tests con YOLOv4.

**Veredicto**: Los inputs son un placeholder. Verifican aritmetica pero no
representan una inferencia real.


## 3. El crop es suficiente?

### Tamano: 8x8 siempre (4x4 output para stride=2)

Una imagen real es 416x416. Los tests usan 8x8 crop.

### Bugs que solo aparecerian con dimensiones grandes

- **Address computation**: Para pixel (200, 300), la direccion de activacion
  es `base + (200 * w_in + 300) * c_in`. Con 8x8, el maximo offset es
  `(7 * 8 + 7) * 20 = 1260`. Con 416x416x512, el offset es
  `(200 * 416 + 300) * 512 = 42,726,400`. Esto requiere 26 bits de direccion.
  El conv_engine_v3 usa `unsigned(24 downto 0)` para direcciones = 25 bits =
  32 MB max. Con c_in=512 y h_in=416, el input ocupa 416*416*512 = 88 MB.
  **El campo de direccion es INSUFICIENTE para feature maps grandes**. Esto
  es un bug real que los tests de 8x8 NUNCA detectarian.

- **Stride=2 con dimensiones impares**: No testeado (8/2=4, siempre par).

- **Counter overflow**: El FSM usa senales de 10 bits para oc, ic, etc.
  c_in=2048 (layer 109) desbordaria 10 bits (max 1023). Los tests usan
  c_in_test=20, asi que nunca tocan este limite.

### Tiling espacial (strip de 3 filas)

El conv_engine_v3 procesa toda la imagen pixel a pixel. No hay strip tiling
en el engine -- eso seria responsabilidad del DataMover (P_16, futuro). Los
tests de 8x8 son coherentes con el engine, pero no prueban la integracion
con el sistema de memoria.

**Veredicto**: 8x8 verifica la logica de padding de bordes y la aritmetica.
NO verifica que el engine funcione con dimensiones reales (address overflow
probable).


## 4. El tiling de IC se testa de verdad?

### En HW (layer tests): NO

Confirmado en AUDIT_REPORT.txt y en gen_layer_tests.py linea 14:
```
ic_tile_size = c_in_test  (one IC tile, no tiling needed)
```

Todos los 110 .c files usan IC_TILE_SIZE = C_IN. El estado IC_TILE_ADV del
FSM NUNCA se ejecuta en HW.

### En simulacion: SI, parcialmente

STRESS_TEST_RESULTS.txt Test 5: ic_tile=1, c_in=32, 1x1 conv, 2 pixels.
32 tile passes. Resultado correcto. Pero:
- Solo probado con 1x1 conv (no 3x3)
- Solo c_in=32 (no c_in=256 o 512)
- Solo datos sinteticos triviales (input=5 o 10, weight=3)
- La carga de pesos entre tiles (con ic_skip_reg) no se estresa con
  layouts complejos

### Lo que no se probo

- ic_tile=8 con 3x3 conv y pesos reales del ONNX
- ic_tile donde c_in no es multiplo de ic_tile_size (ultimo tile parcial)
- ic_tile con multiples OC tiles (oc > 32)
- El address computation para pesos en DDR con tile_base > 0

**Veredicto**: IC tiling es el gap MAS CRITICO. En produccion, TODAS las
capas con c_in > 113 (3x3) o c_in > 1024 (1x1) necesitan IC tiling. Eso
es la MAYORIA de YOLOv4. Si hay un bug en IC_TILE_ADV, el modelo completo
falla.


## 5. Las 110 capas son realmente 110 tests distintos?

### NO. Son esencialmente 4 configuraciones HW.

Del AUDIT_REPORT.txt:

| Config | c_in_test | c_out_test | crop | Capas |
|--------|-----------|------------|------|-------|
| 1x1 s=1 p=0 | 20 | 32 | 8x8->8x8 | 66 |
| 3x3 s=1 p=1 | 5  | 32 | 8x8->8x8 | 36 |
| 3x3 s=2 p=[1,1,0,0] | 9 | 32 | 8x8->4x4 | 7 |
| 3x3 s=1 (layer 0) | 3 | 32 | 8x8->8x8 | 1 |

Dentro de cada grupo, la unica diferencia son:
- Los pesos (distintos por capa)
- Los parametros de quantizacion (x_zp, w_zp, y_zp, M0, n_shift)

Los inputs son IDENTICOS dentro de cada grupo (misma formula, mismo c_in_test).

### Valores unicos de c_in_test: SOLO 4

- c_in_test = 3 (1 capa)
- c_in_test = 5 (36 capas)
- c_in_test = 9 (7 capas)
- c_in_test = 20 (66 capas)

### Valores unicos de c_out_test: SOLO 1

- c_out_test = 32 (TODAS las capas)

Nunca se prueba c_out = 64, 128, 256, 512, 1024. Nunca se prueba c_out = 255
(las detection heads). (NOTA: layer 109 dice c_out_orig=255 pero c_out_test=32.)

### Son esencialmente 4 tests repetidos?

Mas o menos. Lo que cambia entre capas del mismo grupo son los pesos y M0/n_shift.
Esto SI tiene valor: verifica que distintos valores de M0 y n_shift producen
resultados correctos, y que pesos con distintos rangos funcionan. Pero el
datapath HW es identico. Si funciona con unos pesos, deberia funcionar con
otros (a menos que haya un bug dependiente de datos).

**Y DE HECHO HAY UN BUG DEPENDIENTE DE DATOS**: 6 capas FALLAN (038, 043,
045, 047, 049, 057), todas 3x3 con la misma config HW que otras 3x3 que
SI pasan (051, 053, 055). Esto demuestra que los tests con distintos pesos
SI tienen valor diagnostico.

**Veredicto**: 110 capas suena impresionante pero son ~4 configs HW. El
valor real es la cobertura de distintos M0/n_shift/pesos.


## 6. Que NO se ha testeado?

### CRITICA

1. **6 capas FALLAN en HW y no se han investigado**: Layers 038, 043, 045,
   047, 049, 057 fallan con ~98% de errores. Esto es un BUG REAL no resuelto.
   Las capas que pasan y las que fallan tienen la misma config HW (3x3 s=1 p=1
   c_in=5 c_out=32). La diferencia son los pesos/quant params. No hay
   ninguna nota de que se haya hecho root cause analysis.

2. **IC tiling en HW**: Nunca ejecutado. Requerido por >80% de las capas
   reales. Ver seccion 4.

3. **OC tiling en HW**: Nunca ejecutado. c_out_test siempre = 32 = N_MAC.
   Capas con c_out=64,128,256,512,1024 necesitarian multiples OC tiles.
   El estado OC_TILE_ADV existe en el FSM pero nunca se activa.

4. **44 capas no ejecutadas**: El board se colgo antes de completar. 44/110
   capas no tienen resultado.

### ALTA

5. **Dimensiones reales**: Nunca testeado >8x8. Address overflow probable
   para feature maps grandes (ver seccion 3).

6. **c_in real**: Maximo testeado = 20 (c_in_test). Capas reales tienen
   c_in hasta 2048. Aunque sin IC tiling, c_in_test > ~100 no cabe.

7. **Group convolution (group > 1)**: El VHDL no tiene soporte para group
   conv. El gen_layer_tests.py lee el atributo group pero no lo maneja
   especialmente. Si alguna capa de YOLOv4 usa group > 1, el engine daria
   resultados incorrectos. (YOLOv4-tiny NO usa depthwise, pero YOLOv4 full
   podria -- no verificado.)

### MEDIA

8. **Capas con bias = 0**: No testeado en HW con pesos reales. Stress test 4
   tiene un caso con bias=0 para canales auxiliares, pero no es representativo.

9. **Todos los weights = 0 para un filtro**: Podria ocurrir despues de
   quantizacion agresiva. No testeado.

10. **Requantize con M0 cerca de 2^31**: Stress test 1 usa M0=2^31-1, pero
    en simulacion, no en HW. En los layer tests, el M0 maximo es ~2.01*10^9
    (layer 043, M0=2010962079), que es 93.6% de 2^31. Curiosamente, esta
    es una de las capas que FALLA.

11. **Overflow del acumulador con datos reales**: Con c_in=256 y pesos/inputs
    de rango completo, acc puede alcanzar 256*9*255*255 = 149,552,640 (para
    3x3). Esto cabe en 32 bits (max ~2.1*10^9). Con c_in=2048 y 1x1:
    2048*255*255 = 133,169,280. Tambien cabe. Pero con bias grande podria
    acercarse al limite. No testeado con acumuladores reales.

12. **Asymmetric padding en HW para stride=2**: Testeado (layers 1, 8, 17, 60
    usan pad=[1,1,0,0]), pero solo con crop 8x8. No se verifica que el output
    tenga la dimension correcta para la imagen completa (ej: (416+1+0-3)/2+1=208).

### BAJA

13. **DataMover path (P_16)**: No existe aun. Todos los tests usan BRAM
    directo via AXI-Lite.

14. **Timing a frecuencia maxima**: Los tests corren a la frecuencia default
    del bitstream. No hay analisis de timing closure.


## 7. Que pasaria si corremos el YOLO completo?

### Layer chaining: NO VERIFICADO

Nunca se ha testeado que la salida de layer N sea el input correcto de layer
N+1. Cada test usa input sintetico independiente. En un modelo real:
- El output de conv_layer_0 (range [-128, 93] segun ONNXRT verification)
  seria el input de Leaky ReLU, luego de conv_layer_1
- Los zero-points de entrada/salida deben ser consistentes entre capas
- Cualquier error de 1 bit en una capa se propaga y amplifica

### Padding asimetrico con stride=2

Las capas stride=2 en YOLOv4 usan pad=[1,1,0,0] (top=1, left=1, bottom=0,
right=0). Con input 416x416: output = (416+1+0-3)/2+1 = 208. Esto da una
dimension correcta. Pero si el engine interpreta los pads incorrectamente
para alguna posicion de borde, el resultado estaria mal solo para ciertos
pixeles -- y con crop 8x8, esos pixeles podrian no existir.

### Concat (concatenar feature maps)

YOLOv4 usa Concat extensivamente (SPP block, FPN). El conv_engine no maneja
Concat -- seria responsabilidad del software/DataMover reorganizar feature
maps en memoria. Esto no se ha disenado ni testeado.

### Route layers

YOLOv4 usa Route layers para split/concatenate tensors. Requiere que el
layout en memoria sea compatible. No disenado.

**Veredicto**: Correr YOLOv4 completo requiere: (1) resolver los 6 FAIL,
(2) IC tiling funcionando, (3) OC tiling funcionando, (4) DataMover para
DDR, (5) software para Concat/Route, (6) layer chaining verificado.
Estamos a MESES de distancia.


## 8. Comparacion con estandares industriales

### Xilinx DPU (DPUCZDX8G)

El Xilinx DPU incluye:
- **Compilador** (xcompiler) que mapea todo el grafo ONNX al hardware
- **Test suite end-to-end**: corren modelos completos (ResNet, YOLO, etc.)
  y verifican accuracy top-1/top-5 contra la referencia floating-point
- **Bit-accurate C model** (xmodel) que replica exactamente el hardware,
  verificado contra RTL con millones de vectores aleatorios
- **Regression tests** automatizados para cada release, cubriendo:
  - Todas las combinaciones de kernel size (1x1, 3x3, 5x5, 7x7)
  - Todos los strides, paddings, dilations
  - Channel counts de 1 a 4096
  - Feature map sizes de 1x1 a 512x512
  - Group convolution, depthwise conv
  - Batch normalization fusionada
- **Formal verification** de componentes criticos (acumulador, requantize)

### FINN (Xilinx Research)

- **Verificacion end-to-end**: compilan modelo completo, corren en FPGA,
  comparan salida contra PyTorch bit por bit
- **Randomized testing**: generan miles de tests con dimensiones aleatorias
- **Corner case tests**: dimensiones primas, c_in=1, c_out=1, 1x1 feature
  maps
- **CI/CD pipeline**: cada commit corre toda la suite de tests

### hls4ml

- **Emulacion C++**: el HLS tiene un csim que es bit-accurate con el RTL
- **Pytest suite**: cientos de tests automatizados con distintas configs
- **Verificacion de accuracy**: comparan accuracy del modelo completo
  (MNIST, jets, etc.) entre software y hardware

### Donde estamos nosotros

| Aspecto | Xilinx DPU | FINN | hls4ml | Nosotros |
|---------|-----------|------|--------|----------|
| End-to-end model test | Si | Si | Si | **No** |
| Bit-accurate reference model | Si (xmodel) | Si (PyTorch) | Si (csim) | Parcial (Python, 1 capa vs onnxrt) |
| IC tiling test | Si | N/A | N/A | **No (HW)** |
| OC tiling test | Si | N/A | N/A | **No** |
| Random dimensions | Si | Si | Si | **No (solo 4 configs)** |
| Full-size feature maps | Si | Si | Si | **No (solo 8x8)** |
| Group/depthwise conv | Si | Si | Si | **No soportado** |
| CI/CD automatizado | Si | Si | Si | **No** |
| Formal verification | Parcial | No | No | **No** |

**Resumen brutal**: Estamos al nivel de "prototipo de laboratorio verificado
con smoke tests". Los proyectos industriales estan 10x-100x por encima en
cobertura de testing. Esto es aceptable para un proyecto educativo/hobby,
pero no para produccion.


## Lo que SI esta bien probado

- Aritmetica MAC (multiplicacion y acumulacion): bit-exact para 56 capas
  con pesos reales
- Requantize pipeline (M0 * acc, round, shift, clamp): verificada con
  multiples valores de M0/n_shift incluyendo extremos en simulacion
- 3 configuraciones de convolucion: 1x1 s=1, 3x3 s=1, 3x3 s=2
- Padding asimetrico [1,1,0,0] para stride=2: verificado en 4 capas HW
- Pesos reales del ONNX: no son inventados, son del modelo real
- Formula Python vs onnxruntime: match perfecto para capa 0 (2048 bytes)
- Stress tests en simulacion: overflow, extremos negativos, ic_tile=1,
  16x16 feature map, asymmetric padding
- Saturacion (clamp a [-128, 127]): verificada en stress tests


## Lo que NO esta probado (gaps)

| # | Gap | Severidad |
|---|-----|-----------|
| 1 | **6 capas FALLAN sin root cause analysis** | **CRITICA** |
| 2 | **IC tiling en HW (ic_tile < c_in)** | **CRITICA** |
| 3 | **OC tiling en HW (c_out > 32)** | **CRITICA** |
| 4 | **44 capas sin ejecutar** | **ALTA** |
| 5 | **Dimensiones >8x8 en HW** | **ALTA** |
| 6 | **c_in real (>20) en HW** | **ALTA** |
| 7 | **Layer chaining (output N -> input N+1)** | **ALTA** |
| 8 | **End-to-end model accuracy** | **ALTA** |
| 9 | Address overflow para feature maps grandes | ALTA |
| 10 | Group convolution | MEDIA |
| 11 | Onnxruntime verification para >1 capa | MEDIA |
| 12 | Datos de imagen real como input | MEDIA |
| 13 | Concat/Route layer support | MEDIA |
| 14 | c_out != 32 (255 para detection heads) | MEDIA |
| 15 | DataMover / DDR path | MEDIA |
| 16 | Timing closure analysis | BAJA |


## Recomendaciones

Para reclamar "el conv_engine funciona para YOLOv4", se necesita AL MINIMO:

### Inmediato (bloquea todo lo demas)

1. **Investigar los 6 FAIL**: Root cause de layers 038, 043, 045, 047, 049,
   057. Comparar output HW byte-a-byte con expected. Identificar patron
   (que pixeles fallan, que canales, off-by-one vs basura). Esto podria
   revelar un bug sistematico.

2. **Test IC tiling en HW**: Crear un test manual con c_in=32, ic_tile=8
   (4 tiles), 3x3 conv, pesos reales. Verificar que los partial sums se
   acumulan correctamente entre tiles. Si no pasa, hay un bug en IC_TILE_ADV.

3. **Test OC tiling en HW**: Crear un test con c_out=64, c_in=3, 3x3 conv.
   Verificar que el segundo tile (oc 32-63) produce resultados correctos.

### Corto plazo

4. **Verificar contra onnxruntime para AL MENOS 1 capa de cada tipo**: Una
   3x3 s=1, una 3x3 s=2, una 1x1. No solo capa 0.

5. **Completar las 44 capas restantes**: Aunque son configs repetidas, los 6
   FAIL demuestran que distintos pesos/M0 SI pueden revelar bugs.

6. **Test con feature map 32x32 o 64x64**: Aunque sea en simulacion, para
   verificar que el address computation no tiene overflow.

### Medio plazo

7. **Test end-to-end de 2-3 capas encadenadas**: Output de capa 0 como input
   de capa 1, comparar contra onnxruntime.

8. **Input de imagen real**: Usar una imagen de COCO dataset cuantizada,
   correr capa 0, comparar output contra onnxruntime.

9. **Fuzzing de configuraciones**: Tests con dimensiones aleatorias
   (c_in, c_out, h, w, ksize, stride, pad) en simulacion.


## Comparacion con la industria

Estamos en la fase de "unit test del datapath". La industria no shippea
hardware sin al menos un test end-to-end del modelo completo. Nuestra
verificacion es equivalente a probar que un procesador puede sumar y
multiplicar correctamente, sin haber corrido un solo programa real.

Para un proyecto educativo/investigacion, lo logrado es solido: se demostro
que la aritmetica funciona y que el approach de HW-exact testing es correcto.
Pero hay un trecho enorme entre "la ALU funciona" y "el acelerador puede
correr YOLOv4 y detectar objetos".

La distancia estimada:
- **Hoy**: conv_engine arithmetica verificada (con 6 bugs pendientes)
- **Para "IC/OC tiling funciona"**: ~2-4 semanas
- **Para "una capa real (416x416) funciona end-to-end"**: ~1-2 meses
- **Para "YOLOv4 completo corre en el FPGA"**: ~4-8 meses
- **Para "production ready"**: no aplica en ZedBoard (recursos insuficientes
  para modelo completo sin time-multiplexing extremo)
