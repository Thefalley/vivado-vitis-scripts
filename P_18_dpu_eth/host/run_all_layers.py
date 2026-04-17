#!/usr/bin/env python3
"""Orquestador: ejecuta las 255 capas YOLOv4 en la FPGA, verificando
CRC byte a byte contra las activaciones ONNX de referencia.

Mapping verificado: FPGA[i] output = onnx_refs/manifest.tensors[i+2]
Dependencias: LAYERS[i].input_a_idx / input_b_idx (-1 = external input)
Pesos: yolov4_weights.bin con offsets de weights_manifest.json
"""
import json, os, struct, sys, time, zlib
import numpy as np

sys.path.insert(0, os.path.dirname(__file__))
from yolov4_host import DpuHost, CMD_EXEC_LAYER

HERE = os.path.dirname(__file__)
REFS = os.path.join(HERE, "onnx_refs")
BLOB = r"C:/project/vitis-ai/workspace/c_dpu/yolov4_weights.bin"

ADDR_INPUT      = 0x10000000
ADDR_CFG_ARRAY  = 0x11000000
ADDR_WEIGHTS    = 0x12000000
ADDR_ACTIV_BASE = 0x16000000
ADDR_ACTIV_END  = 0x1BFFFFFF
POOL_SIZE       = ADDR_ACTIV_END - ADDR_ACTIV_BASE + 1

LAYER_CFG_FMT = "<BBH IIIII HHHHHH BBBB BBBB BB h i i bbbb III"
OP_NAMES = ['CONV', 'LEAKY', 'ADD', 'CONCAT', 'POOL', 'RESIZE']


def pack_cfg(**kv):
    f = dict(op_type=0, act_type=0, layer_idx=0, in_addr=0, in_b_addr=0,
             out_addr=0, w_addr=0, b_addr=0, c_in=0, c_out=0, h_in=0, w_in=0,
             h_out=0, w_out=0, kh=0, kw=0, stride_h=0, stride_w=0,
             pad_top=0, pad_bottom=0, pad_left=0, pad_right=0,
             ic_tile_size=0, post_shift=0, leaky_alpha_q=0, a_scale_m=0,
             b_scale_m=0, a_scale_s=0, b_scale_s=0, out_zp=0, out_scale_s=0,
             reserved0=0, reserved1=0, reserved2=0); f.update(kv)
    return struct.pack(LAYER_CFG_FMT, *[f[k] for k in [
        "op_type", "act_type", "layer_idx",
        "in_addr", "in_b_addr", "out_addr", "w_addr", "b_addr",
        "c_in", "c_out", "h_in", "w_in", "h_out", "w_out",
        "kh", "kw", "stride_h", "stride_w",
        "pad_top", "pad_bottom", "pad_left", "pad_right",
        "ic_tile_size", "post_shift", "leaky_alpha_q",
        "a_scale_m", "b_scale_m", "a_scale_s", "b_scale_s",
        "out_zp", "out_scale_s", "reserved0", "reserved1", "reserved2"]])


def exec_layer(h, idx):
    h.connect()
    tag = h._next_tag()
    h._send_header(CMD_EXEC_LAYER, 4, tag=tag)
    h._sendall(struct.pack("<HH", idx, 0))
    status, extra = h._expect_ack()
    if len(extra) >= 12:
        cy, crc, nb = struct.unpack("<III", extra[:12])
        return status, cy, crc, nb
    return status, 0, 0, 0


class DDRAllocator:
    """Bump allocator con release por last-use. Asigna direcciones DDR."""
    def __init__(self, base, size):
        self.base = base
        self.size = size
        self.ptr = base
        self.slots = {}  # layer_idx -> (addr, size)

    def alloc(self, layer_idx, nbytes):
        nbytes = (nbytes + 63) & ~63  # align 64
        if self.ptr + nbytes > self.base + self.size:
            self._compact()
            if self.ptr + nbytes > self.base + self.size:
                raise MemoryError(f"DDR pool exhausted: need {nbytes}, have {self.base+self.size-self.ptr}")
        addr = self.ptr
        self.ptr += nbytes
        self.slots[layer_idx] = (addr, nbytes)
        return addr

    def release(self, layer_idx):
        if layer_idx in self.slots:
            del self.slots[layer_idx]

    def addr_of(self, layer_idx):
        return self.slots[layer_idx][0] if layer_idx in self.slots else 0

    def _compact(self):
        if not self.slots:
            self.ptr = self.base
            return
        min_addr = min(a for a, _ in self.slots.values())
        self.ptr = max(a + s for a, s in self.slots.values())


def main():
    N = int(sys.argv[1]) if len(sys.argv) > 1 else 255

    manifest = json.load(open(os.path.join(REFS, "manifest.json")))
    tensors = manifest["tensors"]
    layers = json.load(open(os.path.join(HERE, "layer_configs.json")))
    weights = json.load(open(os.path.join(HERE, "weights_manifest.json")))

    # Pre-compute last_use for release
    last_use = [-1] * 255
    for i in range(255):
        a = layers[i]["input_a_idx"]
        b = layers[i]["input_b_idx"]
        if a >= 0: last_use[a] = max(last_use[a], i)
        if b >= 0: last_use[b] = max(last_use[b], i)

    alloc = DDRAllocator(ADDR_ACTIV_BASE, POOL_SIZE)
    out_addrs = [0] * 255
    results = []

    with DpuHost("192.168.1.10", timeout=120.0) as h:
        print(f"PING: {h.ping()}")
        h.dpu_init()

        t0 = time.time()
        blob = open(BLOB, "rb").read()
        h.write_ddr(ADDR_WEIGHTS, blob)
        print(f"Weights {len(blob)/1e6:.1f} MB: {(time.time()-t0)*1000:.0f} ms")

        inp = np.fromfile(os.path.join(REFS, "layer_001.bin"), dtype=np.int8)
        h.write_ddr(ADDR_INPUT, inp.tobytes())
        print(f"Input {len(inp)} B\n")

        ok = fail = skip = 0
        for i in range(min(N, 255)):
            L = layers[i]
            W = weights[i] if i < len(weights) else {"w_off":0,"w_bytes":0,"b_off":0,"b_bytes":0}
            onnx_idx = i + 2
            if onnx_idx >= len(tensors):
                break

            op_name = OP_NAMES[L["op_type"]] if L["op_type"] < 6 else "?"
            expected_crc = tensors[onnx_idx]["crc32"]
            out_bytes = L["c_out"] * L["h_out"] * L["w_out"]

            # Input address
            a_idx = L["input_a_idx"]
            b_idx = L["input_b_idx"]
            in_addr = ADDR_INPUT if a_idx < 0 else out_addrs[a_idx]
            in_b_addr = 0 if b_idx < 0 else out_addrs[b_idx]

            # Output address
            out_addr = alloc.alloc(i, out_bytes)
            out_addrs[i] = out_addr

            # Weight/bias address
            w_addr = ADDR_WEIGHTS + W["w_off"] if W["w_bytes"] > 0 else 0
            b_addr = ADDR_WEIGHTS + W["b_off"] if W["b_bytes"] > 0 else 0

            # Build cfg (dims=0 -> firmware uses LAYERS[i])
            cfg = pack_cfg(
                layer_idx=i,
                in_addr=in_addr, in_b_addr=in_b_addr,
                out_addr=out_addr, w_addr=w_addr, b_addr=b_addr,
            )
            h.write_ddr(ADDR_CFG_ARRAY + i * 72, cfg)

            t0 = time.time()
            status, cycles, out_crc, out_bytes_ret = exec_layer(h, i)
            dt = time.time() - t0

            match = (status == 0 and out_crc == expected_crc)
            tag = "OK" if match else ("ERR" if status != 0 else "FAIL")

            if match:
                ok += 1
            elif status != 0:
                fail += 1
            else:
                fail += 1

            name = tensors[onnx_idx]["node_name"][:35]
            print(f"[{i:3d}] {tag:4s} {op_name:7s} "
                  f"crc=0x{out_crc:08X} exp=0x{expected_crc:08X} "
                  f"{dt*1000:7.0f}ms  {name}")

            if not match and fail <= 5:
                if status != 0:
                    print(f"       status=0x{status:08X}")
                else:
                    dpu = h.read_ddr(out_addr, min(out_bytes_ret, 32))
                    exp = np.fromfile(os.path.join(REFS, tensors[onnx_idx]["file"]),
                                      dtype=np.int8)[:32]
                    print(f"       dpu[:8]={np.frombuffer(dpu[:8], dtype=np.int8).tolist()}")
                    print(f"       exp[:8]={exp[:8].tolist()}")

            results.append({"layer": i, "op": op_name, "status": status,
                            "match": match, "out_crc": out_crc,
                            "expected_crc": expected_crc, "ms": int(dt*1000)})

            # Release no-longer-needed outputs
            for j in range(i):
                if last_use[j] <= i:
                    alloc.release(j)

            if fail > 10:
                print("Too many failures, stopping")
                break

        print(f"\n{'='*60}")
        print(f"RESULT: {ok}/{ok+fail} OK, {fail} FAIL")
        print(f"{'='*60}")

        json.dump(results, open(os.path.join(HERE, "run_results.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
