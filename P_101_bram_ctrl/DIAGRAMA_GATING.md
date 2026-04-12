# Diagrama de gating (bloqueo) del bram_ctrl_top

## Idea clave

El control de flujo se implementa con **puertas AND** en las senales
`tvalid` y `tready` del AXI-Stream. La FSM genera una senal de
habilitacion (`gate`) que abre o cierra el paso de datos:

```
tvalid_real = tvalid_dma  AND  gate_enable
tready_real = tready_fifo AND  gate_enable
```

Cuando `gate_enable = 0`: tvalid y tready son 0 → no hay handshake
→ los datos NO pasan. El productor (DMA) ve tready=0 y se detiene.
El consumidor ve tvalid=0 y espera.

Cuando `gate_enable = 1`: tvalid y tready pasan tal cual → los datos
fluyen normalmente.

---

## Diagrama de la entrada (s_axis → FIFO)

```
                        FSM
                    +--------+
  ctrl_cmd -------->| S_IDLE |
  n_words  -------->| S_LOAD |----> gate_load = '1' solo en S_LOAD
                    | S_DRAIN|                    '0' en todo lo demas
                    | S_STOP |
                    +--------+


  Desde el DMA (MM2S)              Hacia el FIFO interno
  =====================            ========================

  s_axis_tvalid ----+
                    |    +-----+
                    +--->| AND |---> fi_s_tvalid  (al FIFO)
                         |     |
  gate_load  ----------->|     |
                         +-----+
                                    Solo pasa tvalid cuando
                                    gate_load = 1 (estado S_LOAD)


  fi_s_tready  ----+
  (del FIFO)       |    +-----+
                   +--->| AND |---> s_axis_tready (al DMA)
                        |     |
  gate_load ----------->|     |
                        +-----+
                                    DMA ve tready=0 cuando
                                    gate_load = 0 → se para


  s_axis_tdata  ========================> fi_s_tdata
  (dato pasa directo, sin puerta — solo el handshake se bloquea)


  s_axis_tlast  ----+
                    |    +-----+
                    +--->| OR  |---> fi_s_tlast (al FIFO)
                         |     |
  inject_tlast --------->|     |    Cuando n_words > 0, la FSM
                         +-----+    inyecta tlast sintetico en
                                    el beat N para que el FIFO
                                    cambie a modo replay
```

### Codigo VHDL correspondiente

```vhdl
-- gate_load es implicito: "state = S_LOAD"

fi_s_tvalid   <= s_axis_tvalid  when state = S_LOAD else '0';
                 --  tvalid      AND    gate_load
                 --  (del DMA)         (de la FSM)

s_axis_tready <= fi_s_tready    when state = S_LOAD else '0';
                 --  tready      AND    gate_load
                 --  (del FIFO)        (de la FSM)

fi_s_tdata    <= s_axis_tdata;   -- dato pasa siempre (sin gate)

fi_s_tlast    <= inject_tlast OR s_axis_tlast  when S_LOAD else '0';
```

---

## Diagrama de la salida (FIFO → m_axis)

```
  Desde el FIFO interno             Hacia el DMA (S2MM)
  ========================          =====================

  fi_m_tvalid ------+
  (del FIFO)        |    +-----+
                    +--->| AND |---> m_axis_tvalid (al DMA)
                         |     |
  gate_drain ----------->|     |    Solo pasa tvalid cuando
                         +-----+    gate_drain = 1 (estado S_DRAIN)


  m_axis_tready ----+
  (del DMA S2MM)    |    +-----+
                    +--->| AND |---> fi_m_tready (al FIFO)
                         |     |
  gate_drain ----------->|     |    FIFO ve tready=0 cuando
                         +-----+    gate_drain = 0 → no avanza


  fi_m_tdata  ========================> m_axis_tdata
  (dato pasa directo)

  fi_m_tlast  ------+
                    |    +-----+
                    +--->| AND |---> m_axis_tlast
                         |     |
  gate_drain ----------->|     |
                         +-----+
```

### Codigo VHDL correspondiente

```vhdl
-- gate_drain es implicito: "state = S_DRAIN"

m_axis_tvalid <= fi_m_tvalid    when state = S_DRAIN else '0';
m_axis_tlast  <= fi_m_tlast     when state = S_DRAIN else '0';
fi_m_tready   <= m_axis_tready  when state = S_DRAIN else '0';
m_axis_tdata  <= fi_m_tdata;    -- dato pasa siempre
```

---

## Vista completa del data path

```
                     AXI-Lite (ARM)
                         |
                    ctrl_cmd, n_words
                         |
                         v
                    +---------+
                    |   FSM   |
                    |---------|
                    | S_IDLE  |---> gate_load  = 0, gate_drain = 0
                    | S_LOAD  |---> gate_load  = 1, gate_drain = 0
                    | S_DRAIN |---> gate_load  = 0, gate_drain = 1
                    | S_STOP  |---> gate_load  = 0, gate_drain = 0
                    +---------+
                      |     |
            gate_load |     | gate_drain
                      v     v
 DMA       +-----+       +----------------------------+       +-----+      DMA
 MM2S ---->| AND |------>|     fifo_2x40_bram          |------>| AND |----> S2MM
 tvalid    | AND |  fi_s |                             | fi_m  | AND | tvalid
 tdata     +-----+  tval |  Chain A: 40 x bram_sp     | tval  +-----+ tdata
 tready<---| AND |<------| (pares)                     |------>| AND |---->tready
           | AND |  fi_s |                             | fi_m  | AND |
           +-----+  trdy |  Chain B: 40 x bram_sp     | trdy  +-----+
              ^           | (impares)                   |          ^
              |           |                             |          |
         gate_load        | Ping-pong: 1 word/ciclo     |     gate_drain
                          +----------------------------+


 Leyenda:
   ----> = direccion del dato
   AND   = puerta logica (gate controlado por FSM)
   fi_s  = FIFO side entrada (slave)
   fi_m  = FIFO side salida (master)
```

---

## Tabla de verdad del gating

| Estado FSM | gate_load | gate_drain | s_axis | m_axis | Efecto |
|---|---|---|---|---|---|
| **S_IDLE** | 0 | 0 | BLOQ | BLOQ | Todo parado, esperando comando |
| **S_LOAD** | 1 | 0 | ABIERTO | BLOQ | Datos entran al FIFO, nada sale |
| **S_DRAIN** | 0 | 1 | BLOQ | ABIERTO | Datos salen del FIFO, nada entra |
| **S_STOP** | 0 | 0 | BLOQ | BLOQ | Emergencia, todo congelado |

### Por que se bloquean AMBAS senales (tvalid Y tready)

Si solo bloqueamos tvalid pero dejamos tready libre:
- El productor ve tready=1 y piensa "puedo mandar"
- Pero nadie recibe (tvalid=0 del lado del FIFO)
- El productor podria avanzar su puntero interno → datos perdidos

Si solo bloqueamos tready pero dejamos tvalid libre:
- El FIFO dice "tengo dato" (tvalid=1)
- Pero el consumidor no puede aceptar (tready=0)
- El FIFO se bloquea internamente → correcto pero innecesario

Bloqueando AMBOS garantizamos: **0 handshakes = 0 transferencias**.

---

## El inject_tlast (detalle)

Cuando el ARM usa `n_words > 0`, el DMA NO manda tlast en el beat N
(porque el DMA no sabe cuantos beats quiere la FSM). Pero el FIFO
interno necesita tlast para cambiar de "escribir" a "leer".

Solucion: la FSM inyecta un tlast sintetico:

```
                         beat_count == n_words - 1 ?
                                |
  s_axis_tlast ----+            |
  (del DMA, =0)    |    +------+------+
                   +--->|     OR      |---> fi_s_tlast
                        |             |     (al FIFO)
  inject_tlast -------->|             |
  (de la FSM)           +-------------+

  inject_tlast = '1'  cuando:
    - estado = S_LOAD
    - n_words > 0
    - beat_count = n_words - 1  (ultimo beat del chunk)
```

El FIFO ve tlast=1 en el ultimo beat y cambia automaticamente a
modo replay. El DMA no necesita saber nada.
