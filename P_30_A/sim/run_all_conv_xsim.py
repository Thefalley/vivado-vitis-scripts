#!/usr/bin/env python3
"""Batch XSIM runner: testea TODAS las 110 capas CONV del YOLOv4 contra ONNX.

Para cada capa CONV:
  1. Genera vectores (input, weights OHWI, bias, expected) desde ONNX
  2. Crea un testbench parametrizado
  3. Compila + elabora + corre xsim
  4. Compara resultado

Resultado: tabla de 110 lineas con OK/FAIL por capa.
"""
import json, os, sys, subprocess, struct, zlib, time
import numpy as np
import onnx
from onnx import numpy_helper

ONNX_PATH = r"C:/project/vitis-ai/workspace/models/custom/yolov4_int8_qop.onnx"
REFS = r"C:/project/vivado/P_18_dpu_eth/host/onnx_refs"
SIM_DIR = os.path.dirname(os.path.abspath(__file__))
SRC_DIR = os.path.join(os.path.dirname(SIM_DIR), "src")
LAYERS_JSON = r"C:/project/vivado/P_18_dpu_eth/host/layer_configs.json"

def align64(x): return (x + 63) & ~63

def gen_vectors_and_tb(layer_idx, conv_node_idx, layers, onnx_model, inits, out_dir):
    """Genera vectores + TB para una capa CONV."""
    L = layers[layer_idx]
    convs = [n for n in onnx_model.graph.node if n.op_type == "QLinearConv"]
    conv = convs[conv_node_idx]

    W = numpy_helper.to_array(inits[conv.input[3]]).astype(np.int32)
    x_zp = int(numpy_helper.to_array(inits[conv.input[2]]))
    y_zp = int(numpy_helper.to_array(inits[conv.input[7]]))
    w_zp = int(numpy_helper.to_array(inits[conv.input[5]]))
    bias = numpy_helper.to_array(inits[conv.input[8]]).astype(np.int32)

    k = L["kernel"]; stride = L["stride"]; c_in = L["c_in"]; c_out = L["c_out"]
    M0 = L["M0"]; n_shift = L["n_shift"]

    # Tile size: 2x2 output for speed
    tile = 2
    pad_top = 1 if L["pad"] == 1 else 0
    pad_left = pad_top
    pad_bot = 0; pad_right = 0

    # h_in_real = real input rows for the top-left corner tile
    # Formula: (tile-1)*stride + k - pad_top
    h_in_real = (tile - 1) * stride + k - pad_top
    w_in_real = (tile - 1) * stride + k - pad_left

    # Input from previous layer output (manifest[layer_idx + 1] for the input)
    in_manifest_idx = layer_idx + 1  # +1 because manifest[0]=float, [1]=quantized input
    in_file = os.path.join(REFS, f"layer_{in_manifest_idx:03d}.bin")
    if not os.path.exists(in_file):
        return None, f"input file {in_file} missing"

    manifest = json.load(open(os.path.join(REFS, "manifest.json")))
    in_shape = manifest["tensors"][in_manifest_idx]["shape"]
    # shape is [1, C, H, W]
    x_full = np.fromfile(in_file, dtype=np.int8).reshape(in_shape)
    x_crop = x_full[:, :c_in, :h_in_real, :w_in_real].astype(np.int32)

    # Pad
    pad_spec = ((0,0), (0,0), (pad_top, pad_bot), (pad_left, pad_right))
    xp = np.pad(x_crop, pad_spec, mode="constant", constant_values=x_zp)

    # Conv
    w_eff = W - w_zp
    x_eff = xp - x_zp
    out = np.zeros((1, c_out, tile, tile), dtype=np.int64)
    for oh in range(tile):
        for ow in range(tile):
            ih = oh * stride; iw = ow * stride
            patch = x_eff[0, :, ih:ih+k, iw:iw+k]
            out[0, :, oh, ow] = np.tensordot(w_eff, patch, axes=([1,2,3],[0,1,2]))
    out += bias.reshape(1,-1,1,1)

    rounding = 1 << (n_shift - 1)
    out_q = np.clip(((out * M0 + rounding) >> n_shift) + y_zp, -128, 127).astype(np.int8)

    # IC tile size
    ic_tile_size = min(c_in, max(1, 32768 // (c_out * k * k)))

    # Write vectors
    os.makedirs(out_dir, exist_ok=True)
    def whex(arr, path):
        with open(path, "w") as f:
            for b in arr.astype(np.int8).view(np.uint8).flatten():
                f.write(f"{b:02X}\n")

    whex(x_crop.astype(np.int8), os.path.join(out_dir, "input.hex"))
    W_ohwi = np.ascontiguousarray(np.transpose(W.astype(np.int8), (0,2,3,1)))
    whex(W_ohwi, os.path.join(out_dir, "weights.hex"))
    with open(os.path.join(out_dir, "bias.hex"), "w") as f:
        for b in bias.astype(np.int32).view(np.uint8).flatten():
            f.write(f"{b:02X}\n")
    whex(out_q, os.path.join(out_dir, "expected.hex"))

    # Sizes
    in_bytes = c_in * h_in_real * w_in_real
    w_bytes = c_out * k * k * c_in
    b_bytes = c_out * 4
    out_bytes = c_out * tile * tile

    OUT_OFF = 0
    IN_OFF = align64(out_bytes)
    W_OFF = align64(IN_OFF + in_bytes)
    B_OFF = align64(W_OFF + w_bytes)
    TOT = align64(B_OFF + b_bytes)
    mem_size = max(TOT + 1024, 8192)
    # Round up to power of 2
    ms = 1
    while ms < mem_size: ms *= 2

    ksize_enc = "00" if k == 1 else "10"

    return {
        "layer_idx": layer_idx, "c_in": c_in, "c_out": c_out,
        "k": k, "stride": stride, "h_in": h_in_real, "w_in": w_in_real,
        "tile": tile, "pad_top": pad_top, "pad_bot": pad_bot,
        "pad_left": pad_left, "pad_right": pad_right,
        "x_zp": x_zp, "y_zp": y_zp, "M0": M0, "n_shift": n_shift,
        "ic_tile_size": ic_tile_size, "ksize_enc": ksize_enc,
        "in_bytes": in_bytes, "w_bytes": w_bytes, "b_bytes": b_bytes,
        "out_bytes": out_bytes,
        "OUT_OFF": OUT_OFF, "IN_OFF": IN_OFF, "W_OFF": W_OFF, "B_OFF": B_OFF,
        "TOT": TOT, "mem_size": ms,
        "expected_crc": zlib.crc32(out_q.tobytes()) & 0xFFFFFFFF,
    }, None


def gen_tb_vhdl(params, vec_dir, tb_path):
    """Genera testbench VHDL parametrizado."""
    p = params
    tb_name = f"conv_v4_L{p['layer_idx']}_tb"
    vec_dir = vec_dir.replace("\\", "/")
    stride_val = "'1'" if p["stride"] == 2 else "'0'"
    x_zp_val = p["x_zp"] if p["x_zp"] >= 0 else p["x_zp"]
    y_zp_val = p["y_zp"] if p["y_zp"] >= 0 else p["y_zp"]

    vhdl = f"""library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use ieee.std_logic_textio.all;
use work.mac_array_pkg.all;
library xpm; use xpm.vcomponents.all;

entity {tb_name} is end entity;
architecture sim of {tb_name} is
    constant CLK_PERIOD : time := 10 ns;
    constant ADDR_OUTPUT  : natural := {p['OUT_OFF']};
    constant ADDR_INPUT   : natural := {p['IN_OFF']};
    constant ADDR_WEIGHTS : natural := {p['W_OFF']};
    constant ADDR_BIAS    : natural := {p['B_OFF']};
    constant N_INPUT   : natural := {p['in_bytes']};
    constant N_WEIGHTS : natural := {p['w_bytes']};
    constant N_BIAS    : natural := {p['b_bytes']};
    constant N_OUTPUT  : natural := {p['out_bytes']};
    type mem_t is array (0 to {p['mem_size']-1}) of std_logic_vector(7 downto 0);
    shared variable mem : mem_t := (others => (others => '0'));
    signal clk   : std_logic := '0';
    signal rst_n : std_logic := '0';
    signal cfg_c_in   : unsigned(9 downto 0) := to_unsigned({p['c_in']}, 10);
    signal cfg_c_out  : unsigned(9 downto 0) := to_unsigned({p['c_out']}, 10);
    signal cfg_h_in   : unsigned(9 downto 0) := to_unsigned({p['h_in']}, 10);
    signal cfg_w_in   : unsigned(9 downto 0) := to_unsigned({p['w_in']}, 10);
    signal cfg_ksize  : unsigned(1 downto 0) := "{p['ksize_enc']}";
    signal cfg_stride : std_logic := {stride_val};
    signal cfg_pad_top    : unsigned(1 downto 0) := to_unsigned({p['pad_top']}, 2);
    signal cfg_pad_bottom : unsigned(1 downto 0) := to_unsigned({p['pad_bot']}, 2);
    signal cfg_pad_left   : unsigned(1 downto 0) := to_unsigned({p['pad_left']}, 2);
    signal cfg_pad_right  : unsigned(1 downto 0) := to_unsigned({p['pad_right']}, 2);
    signal cfg_x_zp       : signed(8 downto 0)  := to_signed({x_zp_val}, 9);
    signal cfg_w_zp       : signed(7 downto 0)  := to_signed(0, 8);
    signal cfg_M0         : unsigned(31 downto 0) := to_unsigned({p['M0']}, 32);
    signal cfg_n_shift    : unsigned(5 downto 0)  := to_unsigned({p['n_shift']}, 6);
    signal cfg_y_zp       : signed(7 downto 0)  := to_signed({y_zp_val}, 8);
    signal cfg_addr_input    : unsigned(24 downto 0) := to_unsigned(ADDR_INPUT, 25);
    signal cfg_addr_weights  : unsigned(24 downto 0) := to_unsigned(ADDR_WEIGHTS, 25);
    signal cfg_addr_bias     : unsigned(24 downto 0) := to_unsigned(ADDR_BIAS, 25);
    signal cfg_addr_output   : unsigned(24 downto 0) := to_unsigned(ADDR_OUTPUT, 25);
    signal cfg_ic_tile_size  : unsigned(9 downto 0) := to_unsigned({p['ic_tile_size']}, 10);
    signal start : std_logic := '0';
    signal done, busy : std_logic;
    signal ddr_rd_addr : unsigned(24 downto 0);
    signal ddr_rd_data : std_logic_vector(7 downto 0) := (others => '0');
    signal ddr_rd_en   : std_logic;
    signal ddr_wr_addr : unsigned(24 downto 0);
    signal ddr_wr_data : std_logic_vector(7 downto 0);
    signal ddr_wr_en   : std_logic;
    signal dbg_state : integer range 0 to 63;
    signal dbg_oh, dbg_ow, dbg_kh, dbg_kw, dbg_ic : unsigned(9 downto 0);
    signal dbg_oc_tile_base, dbg_ic_tile_base : unsigned(9 downto 0);
    signal dbg_w_base : unsigned(19 downto 0);
    signal dbg_mac_a : signed(8 downto 0);
    signal dbg_mac_b : weight_array_t;
    signal dbg_mac_bi : bias_array_t;
    signal dbg_mac_acc : acc_array_t;
    signal dbg_mac_vi, dbg_mac_clr, dbg_mac_lb, dbg_pad : std_logic;
    signal dbg_act_addr : unsigned(24 downto 0);
    signal sim_end : boolean := false;
begin
    clk <= not clk after CLK_PERIOD / 2;
    u_dut : entity work.conv_engine_v4
        generic map (WB_SIZE => 32768)
        port map (
            clk => clk, rst_n => rst_n,
            cfg_c_in => cfg_c_in, cfg_c_out => cfg_c_out,
            cfg_h_in => cfg_h_in, cfg_w_in => cfg_w_in,
            cfg_ksize => cfg_ksize, cfg_stride => cfg_stride,
            cfg_pad_top => cfg_pad_top, cfg_pad_bottom => cfg_pad_bottom,
            cfg_pad_left => cfg_pad_left, cfg_pad_right => cfg_pad_right,
            cfg_x_zp => cfg_x_zp, cfg_w_zp => cfg_w_zp,
            cfg_M0 => cfg_M0, cfg_n_shift => cfg_n_shift, cfg_y_zp => cfg_y_zp,
            cfg_addr_input => cfg_addr_input, cfg_addr_weights => cfg_addr_weights,
            cfg_addr_bias => cfg_addr_bias, cfg_addr_output => cfg_addr_output,
            cfg_ic_tile_size => cfg_ic_tile_size,
            cfg_no_clear => '0', cfg_no_requantize => '0',
            ext_wb_addr => (others => '0'), ext_wb_data => (others => '0'), ext_wb_we => '0',
            start => start, done => done, busy => busy,
            ddr_rd_addr => ddr_rd_addr, ddr_rd_data => ddr_rd_data, ddr_rd_en => ddr_rd_en,
            ddr_wr_addr => ddr_wr_addr, ddr_wr_data => ddr_wr_data, ddr_wr_en => ddr_wr_en,
            dbg_state => dbg_state, dbg_oh => dbg_oh, dbg_ow => dbg_ow,
            dbg_kh => dbg_kh, dbg_kw => dbg_kw, dbg_ic => dbg_ic,
            dbg_oc_tile_base => dbg_oc_tile_base, dbg_ic_tile_base => dbg_ic_tile_base,
            dbg_w_base => dbg_w_base, dbg_mac_a => dbg_mac_a,
            dbg_mac_b => dbg_mac_b, dbg_mac_bi => dbg_mac_bi, dbg_mac_acc => dbg_mac_acc,
            dbg_mac_vi => dbg_mac_vi, dbg_mac_clr => dbg_mac_clr, dbg_mac_lb => dbg_mac_lb,
            dbg_pad => dbg_pad, dbg_act_addr => dbg_act_addr);
    p_stim : process
        variable ln : line; variable bv : std_logic_vector(7 downto 0);
        variable i, n_ok, n_fail : integer := 0;
        variable fs : file_open_status;
        file f : text;
        procedure lf(path: string; base: natural; nb: natural) is
            variable ll: line; variable bb: std_logic_vector(7 downto 0); variable j: integer := 0;
            variable ffs: file_open_status; file ff: text;
        begin
            file_open(ffs, ff, path, read_mode);
            while not endfile(ff) and j < nb loop readline(ff,ll); hread(ll,bb); mem(base+j):=bb; j:=j+1; end loop;
            file_close(ff);
        end procedure;
    begin
        rst_n <= '0'; wait for CLK_PERIOD*5;
        lf("{vec_dir}/input.hex", ADDR_INPUT, N_INPUT);
        lf("{vec_dir}/weights.hex", ADDR_WEIGHTS, N_WEIGHTS);
        lf("{vec_dir}/bias.hex", ADDR_BIAS, N_BIAS);
        wait for CLK_PERIOD*5; rst_n <= '1'; wait for CLK_PERIOD*2;
        wait until rising_edge(clk); start <= '1'; wait until rising_edge(clk); start <= '0';
        for t in 0 to 30000000 loop
            wait until rising_edge(clk);
            if ddr_rd_en='1' then ddr_rd_data <= mem(to_integer(ddr_rd_addr)); end if;
            if ddr_wr_en='1' then mem(to_integer(ddr_wr_addr)) := ddr_wr_data; end if;
            if done='1' then exit; end if;
        end loop;
        if done /= '1' then report "TIMEOUT" severity failure; end if;
        wait for CLK_PERIOD*5;
        file_open(fs, f, "{vec_dir}/expected.hex", read_mode);
        n_ok := 0; n_fail := 0; i := 0;
        while not endfile(f) and i < N_OUTPUT loop
            readline(f, ln); hread(ln, bv);
            if mem(ADDR_OUTPUT+i) = bv then n_ok := n_ok+1;
            else n_fail := n_fail+1; end if;
            i := i+1;
        end loop;
        file_close(f);
        report "RESULT: " & integer'image(n_ok) & "/" & integer'image(i) & " OK, " & integer'image(n_fail) & " mismatches";
        sim_end <= true; wait for CLK_PERIOD*10;
        assert false report "END" severity failure;
    end process;
end architecture;
"""
    with open(tb_path, "w") as f:
        f.write(vhdl)


def run_xsim(tb_name, tb_path):
    """Compila + elabora + corre xsim. Retorna resultado."""
    os.chdir(SIM_DIR)
    os.environ["PATH"] = r"C:\AMDDesignTools\2025.2\Vivado\bin;" + os.environ.get("PATH", "")
    srcs = " ".join([
        f"{SRC_DIR}/mul_s32x32_pipe.vhd", f"{SRC_DIR}/requantize.vhd",
        f"{SRC_DIR}/mac_unit.vhd", f"{SRC_DIR}/mac_array.vhd",
        f"{SRC_DIR}/conv_engine_v4.vhd", tb_path,
    ])
    # Compile
    r = subprocess.run(f"xvhdl.bat -2008 {srcs}", shell=True, capture_output=True, text=True, timeout=60)
    if r.returncode != 0:
        return f"COMPILE_ERROR: {r.stderr[:200]}"
    # Elaborate
    snap = f"{tb_name}_snap"
    r = subprocess.run(f"xelab.bat -debug typical -top {tb_name} -snapshot {snap}",
                       shell=True, capture_output=True, text=True, timeout=120)
    if r.returncode != 0:
        return f"ELAB_ERROR: {r.stderr[:200]}"
    # Simulate
    tcl = os.path.join(SIM_DIR, f"run_{tb_name}.tcl").replace("\\", "/")
    with open(tcl, "w") as f:
        f.write("run all\nquit\n")
    r = subprocess.run(f"xsim.bat {snap} -t {tcl}", shell=True, capture_output=True, text=True, timeout=600)
    # Parse result
    for line in r.stdout.split("\n"):
        if "RESULT:" in line:
            return line.strip()
        if "TIMEOUT" in line:
            return "TIMEOUT"
    return f"NO_RESULT: {r.stdout[-200:]}"


def main():
    max_layers = int(sys.argv[1]) if len(sys.argv) > 1 else 110
    layers = json.load(open(LAYERS_JSON))
    model = onnx.load(ONNX_PATH)
    inits = {i.name: i for i in model.graph.initializer}

    conv_idx = 0
    ok = fail = skip = 0
    results = []

    for i, L in enumerate(layers):
        if L["op_type"] != 0:
            continue
        if conv_idx >= max_layers:
            break

        vec_dir = os.path.join(SIM_DIR, f"vectors_auto", f"L{i}").replace("\\", "/")
        tb_path = os.path.join(SIM_DIR, f"auto_L{i}_tb.vhd").replace("\\", "/")
        tb_name = f"conv_v4_L{i}_tb"

        t0 = time.time()
        params, err = gen_vectors_and_tb(i, conv_idx, layers, model, inits, vec_dir)
        if err:
            print(f"[{i:3d}] SKIP {err}")
            skip += 1
            conv_idx += 1
            continue

        gen_tb_vhdl(params, vec_dir, tb_path)
        result = run_xsim(tb_name, tb_path)
        dt = time.time() - t0

        is_ok = "OK" in result and "0 mismatches" in result
        tag = "OK" if is_ok else "FAIL"
        if is_ok: ok += 1
        else: fail += 1

        ic_ts = params["ic_tile_size"]
        ic_note = f"ic_ts={ic_ts}" if ic_ts < L["c_in"] else ""
        print(f"[{i:3d}] {tag:4s} {L['c_in']:4d}->{L['c_out']:4d} k={L['kernel']} s={L['stride']} {ic_note:10s} {dt:5.1f}s  {result}")
        results.append({"layer": i, "result": tag, "detail": result})
        conv_idx += 1

    print(f"\n{'='*60}")
    print(f"TOTAL: {ok}/{ok+fail+skip} OK, {fail} FAIL, {skip} SKIP")

    json.dump(results, open(os.path.join(SIM_DIR, "xsim_all_results.json"), "w"), indent=2)


if __name__ == "__main__":
    main()
