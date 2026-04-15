#!/usr/bin/env python3
"""validate_bbox_decoder.py -- compare bare-metal C decoder vs draw_bboxes.py.

Strategy: build the C decoder as a host shared library (no Xil deps), feed it
the same INT8 heads + dequant params used in the reference Python pipeline,
then diff resulting detection sets.

Usage:
    # 1) compile a host wrapper:
    gcc -O2 -shared -fPIC -o libbboxdec.so \\
        ../bbox_decoder.c host_shim.c -lm

    # 2) run validator:
    python validate_bbox_decoder.py \\
        --h52 head_52.i8 --h26 head_26.i8 --h13 head_13.i8 \\
        --scales 0.0039 0.0039 0.0039 --zps 0 0 0

Inputs:
    head_*.i8 : raw int8 dumps in NHWC, channels-last, 255 ch/cell.
                If you only have float32 dumps, requantise via x_scale/zp first.

A pass = same number of survivors AND, for each Python detection, a C
detection of the same class with IoU > 0.99 and |conf diff| < 1e-3.
"""
import argparse, ctypes, sys, os
import numpy as np

sys.path.insert(0, os.path.join(os.path.dirname(__file__),
                                "..", "..", "..",
                                "P_17_dpu_multi", "sw", "runtime"))
from draw_bboxes import decode_heads as py_decode, nms as py_nms  # noqa: E402


class Det(ctypes.Structure):
    _fields_ = [("x", ctypes.c_float), ("y", ctypes.c_float),
                ("w", ctypes.c_float), ("h", ctypes.c_float),
                ("confidence", ctypes.c_float),
                ("class_id", ctypes.c_int)]


def load_lib(path="./libbboxdec.so"):
    lib = ctypes.CDLL(path)
    lib.decode_heads.restype = ctypes.c_int
    lib.decode_heads.argtypes = [
        ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p,
        ctypes.c_float, ctypes.c_float, ctypes.c_float,
        ctypes.c_int32, ctypes.c_int32, ctypes.c_int32,
        ctypes.POINTER(Det), ctypes.c_int]
    lib.nms.restype = ctypes.c_int
    lib.nms.argtypes = [ctypes.POINTER(Det), ctypes.c_int, ctypes.c_float]
    return lib


def iou(a, b):
    x1 = max(a[0], b[0]); y1 = max(a[1], b[1])
    x2 = min(a[2], b[2]); y2 = min(a[3], b[3])
    iw = max(0.0, x2 - x1); ih = max(0.0, y2 - y1)
    inter = iw * ih
    aa = (a[2]-a[0])*(a[3]-a[1]); bb = (b[2]-b[0])*(b[3]-b[1])
    return inter / (aa + bb - inter + 1e-9)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--h52", required=True)
    ap.add_argument("--h26", required=True)
    ap.add_argument("--h13", required=True)
    ap.add_argument("--scales", nargs=3, type=float, required=True)
    ap.add_argument("--zps",    nargs=3, type=int,   required=True)
    ap.add_argument("--lib", default="./libbboxdec.so")
    args = ap.parse_args()

    h52 = np.fromfile(args.h52, dtype=np.int8)
    h26 = np.fromfile(args.h26, dtype=np.int8)
    h13 = np.fromfile(args.h13, dtype=np.int8)

    # ---- C path -------------------------------------------------------
    lib = load_lib(args.lib)
    buf = (Det * 256)()
    n = lib.decode_heads(h52.tobytes(), h26.tobytes(), h13.tobytes(),
                         *args.scales, *args.zps, buf, 256)
    n = lib.nms(buf, n, ctypes.c_float(0.45))
    c_dets = [(buf[i].class_id, buf[i].confidence,
               (buf[i].x, buf[i].y, buf[i].w, buf[i].h)) for i in range(n)]

    # ---- Python path --------------------------------------------------
    def deq(arr, s, z):
        return ((arr.astype(np.int32) - z) * s).astype(np.float32)
    py_h52 = deq(h52, args.scales[0], args.zps[0]).reshape(1, 52, 52, 255)
    py_h26 = deq(h26, args.scales[1], args.zps[1]).reshape(1, 26, 26, 255)
    py_h13 = deq(h13, args.scales[2], args.zps[2]).reshape(1, 13, 13, 255)
    boxes, scores = py_decode([py_h52, py_h26, py_h13])
    py_dets_raw = py_nms(boxes, scores, 0.25, 0.45)
    py_dets = [(d["class_id"], d["conf"], tuple(d["box"])) for d in py_dets_raw]

    # ---- Compare ------------------------------------------------------
    print(f"C: {len(c_dets)} dets   Py: {len(py_dets)} dets")
    ok = (len(c_dets) == len(py_dets))
    for cd in c_dets:
        match = next((pd for pd in py_dets
                      if pd[0] == cd[0]
                      and abs(pd[1] - cd[1]) < 1e-3
                      and iou(pd[2], cd[2]) > 0.99), None)
        if match is None:
            ok = False
            print(f"  MISS  C={cd}")
    print("RESULT:", "PASS" if ok else "FAIL")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
