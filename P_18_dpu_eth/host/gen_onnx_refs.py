"""Genera los tensores de referencia de YOLOv4 ONNX.

Corre `yolov4_int8_qop.onnx` con un input de prueba y vuelca TODAS las
activaciones intermedias a disco. Estas son las referencias bit-exact
contra las que comparar cada capa del DPU.

Uso:
    python gen_onnx_refs.py [--onnx PATH] [--out DIR] [--input PATH]

Output:
    <out_dir>/
        manifest.json              — lista ordenada de capas + meta
        layer_000.bin              — activación int8 del nodo 0
        layer_000.json             — shape, dtype, crc32, op_type, node_name
        layer_001.bin / .json
        ...
        input.bin                  — imagen usada (int8, 416x416x3)
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
import zlib
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort


ONNX_DEFAULT = r"C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"


def crc32(data: bytes) -> int:
    return zlib.crc32(data) & 0xFFFFFFFF


def pick_all_intermediate_outputs(model_path: str) -> list[str]:
    """Lista los nombres de TODOS los tensores intermedios del grafo."""
    m = onnx.load(model_path)
    names = []
    seen = set()
    for node in m.graph.node:
        for out in node.output:
            if out and out not in seen:
                names.append(out)
                seen.add(out)
    # Quitar las salidas ya declaradas como model outputs (las añadimos aparte)
    model_outs = {o.name for o in m.graph.output}
    intermediate = [n for n in names if n not in model_outs]
    final_outs = [o.name for o in m.graph.output]
    return intermediate + final_outs, final_outs


def build_session_with_all_outputs(model_path: str) -> tuple[ort.InferenceSession, list[str], list[str]]:
    """Crea una sesión donde cada tensor intermedio sea tratado como output."""
    all_names, final_outs = pick_all_intermediate_outputs(model_path)
    m = onnx.load(model_path)

    # Añadir cada tensor intermedio como output del grafo
    existing_outs = {o.name for o in m.graph.output}
    for name in all_names:
        if name in existing_outs:
            continue
        vi = onnx.ValueInfoProto()
        vi.name = name
        m.graph.output.append(vi)

    patched_path = model_path.replace(".onnx", "_patched.onnx")
    onnx.save(m, patched_path)

    sess = ort.InferenceSession(patched_path,
                                providers=["CPUExecutionProvider"])
    return sess, all_names, final_outs


def generate_test_input(shape: tuple, dtype: str, seed: int = 42) -> np.ndarray:
    """Input sintético reproducible."""
    rng = np.random.default_rng(seed)
    if dtype in ("uint8", "int8"):
        arr = rng.integers(0, 256 if dtype == "uint8" else 128,
                           size=shape, dtype=np.int64)
        if dtype == "int8":
            arr = arr.astype(np.int8)
        else:
            arr = arr.astype(np.uint8)
        return arr
    elif dtype in ("float32", "float"):
        return rng.uniform(0.0, 1.0, size=shape).astype(np.float32)
    raise ValueError(f"dtype no soportado: {dtype}")


def dtype_onnx_to_numpy(t: int) -> str:
    """Mapeo TensorProto.DataType → string usable por onnxruntime."""
    mapping = {
        1: "float32", 2: "uint8", 3: "int8",
        6: "int32", 7: "int64", 9: "bool",
        10: "float16", 11: "float64",
    }
    return mapping.get(t, f"unknown_{t}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--onnx", default=ONNX_DEFAULT)
    ap.add_argument("--out", default="./onnx_refs")
    ap.add_argument("--input", default=None,
                    help="path a input.bin (opcional). Si no, usa input sintético")
    ap.add_argument("--seed", type=int, default=42)
    ap.add_argument("--max-layers", type=int, default=0,
                    help=">0 limita nº de tensores dumpeados (debug)")
    args = ap.parse_args()

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)

    print(f"[1/4] Cargando modelo {args.onnx}...")
    t0 = time.time()
    sess, all_names, final_outs = build_session_with_all_outputs(args.onnx)
    print(f"      {len(all_names)} tensores a dumpear "
          f"(de los cuales {len(final_outs)} son heads finales) "
          f"en {time.time()-t0:.1f}s")

    # Input metadata
    inputs_meta = sess.get_inputs()
    print(f"[2/4] Inputs del modelo:")
    for im in inputs_meta:
        print(f"      {im.name} shape={im.shape} type={im.type}")

    # Generar / cargar input
    input_name = inputs_meta[0].name
    input_shape = [int(s) if isinstance(s, int) or (isinstance(s, str) and s.isdigit()) else 1
                   for s in inputs_meta[0].shape]
    input_dtype = inputs_meta[0].type
    # type = 'tensor(uint8)' → 'uint8'
    dtype_str = input_dtype.replace("tensor(", "").replace(")", "")

    if args.input and os.path.exists(args.input):
        raw = np.fromfile(args.input, dtype=np.uint8 if dtype_str == "uint8"
                          else np.int8 if dtype_str == "int8"
                          else np.float32)
        inp = raw.reshape(input_shape)
        print(f"      cargado input desde {args.input}, shape={inp.shape}")
    else:
        inp = generate_test_input(tuple(input_shape), dtype_str, args.seed)
        print(f"      input sintético seed={args.seed} dtype={dtype_str} "
              f"shape={inp.shape}")

    # Guardar input
    inp_bytes = inp.tobytes()
    (out_dir / "input.bin").write_bytes(inp_bytes)
    input_meta = {
        "name": input_name,
        "shape": list(inp.shape),
        "dtype": dtype_str,
        "bytes": len(inp_bytes),
        "crc32": crc32(inp_bytes),
    }
    (out_dir / "input.json").write_text(json.dumps(input_meta, indent=2))
    print(f"      input.bin dumped, crc=0x{input_meta['crc32']:08X}")

    # Ejecutar inferencia
    print(f"[3/4] Ejecutando ONNX runtime con {len(all_names)} outputs...")
    t0 = time.time()
    feed = {input_name: inp}
    if args.max_layers > 0:
        wanted = all_names[:args.max_layers] + final_outs
        # deduplicar preservando orden
        seen = set()
        wanted = [n for n in wanted if not (n in seen or seen.add(n))]
    else:
        wanted = all_names
    outputs = sess.run(wanted, feed)
    print(f"      inferencia OK en {time.time()-t0:.1f}s")

    # Dump por tensor
    print(f"[4/4] Dumpeando a {out_dir} ...")
    manifest = {
        "onnx_path": args.onnx,
        "seed": args.seed,
        "input": input_meta,
        "n_tensors": len(wanted),
        "final_outputs": final_outs,
        "tensors": [],
    }
    t0 = time.time()
    for i, (name, arr) in enumerate(zip(wanted, outputs)):
        arr = np.asarray(arr)
        raw = arr.tobytes()
        fname = f"layer_{i:03d}.bin"
        (out_dir / fname).write_bytes(raw)
        info = {
            "index": i,
            "node_name": name,
            "file": fname,
            "shape": list(arr.shape),
            "dtype": str(arr.dtype),
            "bytes": len(raw),
            "crc32": crc32(raw),
            "is_final_output": name in final_outs,
        }
        manifest["tensors"].append(info)
        if i < 5 or i >= len(wanted) - 5 or i % 50 == 0:
            print(f"      [{i:3d}] {name[:40]:40s} {str(arr.shape):20s} "
                  f"{str(arr.dtype):8s} {len(raw):10d} B  "
                  f"crc=0x{info['crc32']:08X}")

    (out_dir / "manifest.json").write_text(json.dumps(manifest, indent=2))
    print(f"      {len(wanted)} tensores en {time.time()-t0:.1f}s")
    print()
    print(f"DONE. Output en {out_dir.resolve()}")
    total_bytes = sum(t["bytes"] for t in manifest["tensors"])
    print(f"Total data: {total_bytes/1e6:.1f} MB across {len(wanted)} tensors")


if __name__ == "__main__":
    main()
