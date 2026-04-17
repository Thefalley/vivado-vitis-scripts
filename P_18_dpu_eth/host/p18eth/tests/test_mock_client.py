"""Tests end-to-end client ↔ mock_server por TCP loopback.

Cubre la conversación completa del protocolo V1: HELLO, WRITE_*, EXEC, READ,
y los error paths (CRC corrupto, kind mismatch, EXEC sin cfg, etc.).

Cada test arranca un MockServer nuevo en un puerto libre para aislamiento.
"""
from __future__ import annotations

import socket
import struct
import time

import pytest

from p18eth import (
    DpuHost, MockServer,
    Kind, OpType, Dtype, Err, Opcode, Flags,
    LayerCfg, DataHdr, crc32, pack_data_hdr,
    LAYER_CFG_SIZE, DATA_HDR_SIZE, ADDR_CFG_ARRAY,
)
from p18eth.client import ProtocolError


# =============================================================================
# Fixture: MockServer en puerto libre
# =============================================================================
def _free_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    p = s.getsockname()[1]
    s.close()
    return p


@pytest.fixture
def mock_server():
    port = _free_port()
    srv = MockServer(host="127.0.0.1", port=port, verbose=False)
    srv.start()
    try:
        yield srv
    finally:
        srv.stop()


@pytest.fixture
def client(mock_server):
    h = DpuHost("127.0.0.1", port=mock_server.port, timeout=5.0)
    h.connect()
    try:
        yield h
    finally:
        h.close()


# =============================================================================
# HELLO + PING
# =============================================================================
def test_hello_ok(client):
    info = client.hello()
    assert info["proto_ver"] == 1
    assert info["layer_cfg_size"] == LAYER_CFG_SIZE
    assert info["data_hdr_size"] == DATA_HDR_SIZE


def test_ping(client):
    resp = client.ping()
    assert resp == b"P_18 OK\0"


def test_hello_wrong_version_rejected(mock_server):
    """Si el cliente manda versión != servidor, el mock responde PROTO_VERSION."""
    port = mock_server.port
    sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
    # Header HELLO + payload con versión errónea
    bad_payload = struct.pack("<IIII", 999, LAYER_CFG_SIZE, DATA_HDR_SIZE, 0)
    header = struct.pack("<BBHI", Opcode.HELLO, 0, 1, len(bad_payload))
    sock.sendall(header + bad_payload)
    # Recibe header de respuesta
    rh = sock.recv(8)
    opcode = rh[0]
    plen = struct.unpack("<I", rh[4:8])[0]
    body = sock.recv(plen)
    code = struct.unpack("<I", body[:4])[0]
    sock.close()
    assert opcode == 0x8E  # RSP_ERROR
    assert code == Err.PROTO_VERSION


# =============================================================================
# WRITE_RAW / READ_RAW round-trip
# =============================================================================
def test_write_read_raw_small(client):
    client.hello()
    data = b"\x01\x02\x03\x04" * 64  # 256 B
    client.write_raw(0x10000000, data)
    back = client.read_raw(0x10000000, len(data))
    assert back == data


def test_write_read_raw_1mb(client):
    client.hello()
    data = bytes(range(256)) * 4096  # 1 MB
    client.write_raw(0x12000000, data)
    back = client.read_raw(0x12000000, len(data))
    assert back == data


def test_write_raw_bad_address_rejected(client):
    client.hello()
    with pytest.raises(ProtocolError) as exc:
        client.write_raw(0x00000000, b"\xAA" * 16)
    assert exc.value.code == Err.BAD_ADDR


# =============================================================================
# WRITE_INPUT / WRITE_WEIGHTS (typed, con data_hdr + CRC)
# =============================================================================
def test_write_input(client, mock_server):
    client.hello()
    img = bytes(range(256)) * 2029  # ~519 168 B, no exacto pero >0
    img = img[:416 * 416 * 3]
    client.write_input(addr=0x10000000, data=img)

    # El mock marca input_loaded
    assert mock_server.state.input_loaded
    # Los bytes están en DDR virtual
    back = mock_server.ddr.read(0x10000000, len(img))
    assert back == img


def test_write_weights_marks_state(client, mock_server):
    client.hello()
    w = b"\x7F" * 864  # pesos layer 0 (3*3*3*32 = 864)
    client.write_weights(layer_idx=0, addr=0x12000000, data=w)
    assert mock_server.state.layer[0].w_loaded
    assert not mock_server.state.layer[1].w_loaded


def test_write_bias_marks_state(client, mock_server):
    client.hello()
    bias = struct.pack("<" + "i" * 32, *range(32))
    client.write_bias(layer_idx=0, addr=0x12100000, data=bias)
    assert mock_server.state.layer[0].b_loaded


# =============================================================================
# CRC corrupto → mock rechaza
# =============================================================================
def test_crc_corruption_detected(mock_server):
    """Manda un CMD_WRITE_WEIGHTS con CRC erróneo → mock responde Err.CRC."""
    port = mock_server.port
    sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
    # HELLO primero
    hello_payload = struct.pack("<IIII", 1, LAYER_CFG_SIZE, DATA_HDR_SIZE, 0)
    hello_hdr = struct.pack("<BBHI", Opcode.HELLO, 0, 1, len(hello_payload))
    sock.sendall(hello_hdr + hello_payload)
    sock.recv(8 + 16 + 4)  # descarta respuesta ACK

    # Mensaje corrupto: data_hdr dice crc=0x0 pero data es "AAAA"
    data = b"\x41" * 16
    bad_dh = DataHdr(
        layer_idx=0, kind=Kind.WEIGHTS, dtype=Dtype.INT8,
        ddr_addr=0x12000000, expected_len=16, crc32=0xDEADBEEF,  # ¡mal!
    ).pack()
    payload = bad_dh + data
    hdr = struct.pack("<BBHI", Opcode.WRITE_WEIGHTS, Flags.HAS_DATA_HDR,
                      2, len(payload))
    sock.sendall(hdr + payload)

    resp_hdr = sock.recv(8)
    opcode = resp_hdr[0]
    plen = struct.unpack("<I", resp_hdr[4:8])[0]
    body = sock.recv(plen)
    code = struct.unpack("<I", body[:4])[0]
    sock.close()

    assert opcode == 0x8E  # RSP_ERROR
    assert code == Err.CRC
    assert mock_server.state.total_crc_errors == 1


# =============================================================================
# KIND mismatch (opcode WRITE_WEIGHTS pero data_hdr.kind = INPUT)
# =============================================================================
def test_kind_mismatch_rejected(mock_server):
    port = mock_server.port
    sock = socket.create_connection(("127.0.0.1", port), timeout=2.0)
    hello_payload = struct.pack("<IIII", 1, LAYER_CFG_SIZE, DATA_HDR_SIZE, 0)
    hello_hdr = struct.pack("<BBHI", Opcode.HELLO, 0, 1, len(hello_payload))
    sock.sendall(hello_hdr + hello_payload)
    sock.recv(8 + 16 + 4)

    data = b"\xAB" * 16
    # kind=INPUT pero opcode=WRITE_WEIGHTS → mismatch
    bad_dh = pack_data_hdr(
        layer_idx=0, kind=Kind.INPUT, dtype=Dtype.INT8,
        ddr_addr=0x12000000, data=data,
    )
    payload = bad_dh + data
    hdr = struct.pack("<BBHI", Opcode.WRITE_WEIGHTS, Flags.HAS_DATA_HDR,
                      5, len(payload))
    sock.sendall(hdr + payload)

    resp_hdr = sock.recv(8)
    plen = struct.unpack("<I", resp_hdr[4:8])[0]
    body = sock.recv(plen)
    code = struct.unpack("<I", body[:4])[0]
    sock.close()
    assert code == Err.KIND_MISMATCH


# =============================================================================
# WRITE_CFG + EXEC_LAYER happy path
# =============================================================================
def test_write_cfg_single(client, mock_server):
    client.hello()
    cfg = LayerCfg(
        op_type=OpType.CONV, layer_idx=5,
        in_addr=0x16000000, out_addr=0x17000000,
        w_addr=0x12001000, b_addr=0x12A00000,
        c_in=32, c_out=64, h_in=208, w_in=208, h_out=208, w_out=208,
        kh=3, kw=3, stride_h=1, stride_w=1,
        pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
    )
    client.write_cfg(cfg)
    assert mock_server.state.layer[5].cfg_set
    assert mock_server.cfgs[5].c_out == 64


def test_exec_layer_requires_cfg(client, mock_server):
    client.hello()
    with pytest.raises(ProtocolError) as exc:
        client.exec_layer(3)
    assert exc.value.code == Err.NOT_CONFIGURED


def test_exec_layer_missing_weights(client, mock_server):
    """Strict mode: CONV sin weights → MISSING_DATA."""
    client.hello()
    cfg = LayerCfg(
        op_type=OpType.CONV, layer_idx=0,
        c_in=3, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416,
        kh=3, kw=3, stride_h=1, stride_w=1,
        pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
        in_addr=0x10000000, out_addr=0x16000000,
        w_addr=0x12000000, b_addr=0x12A00000,
    )
    client.write_cfg(cfg)
    with pytest.raises(ProtocolError) as exc:
        client.exec_layer(0)
    assert exc.value.code == Err.MISSING_DATA


def test_exec_layer_conv_happy_path(client, mock_server):
    """INPUT + WEIGHTS + BIAS + CFG → EXEC OK → out_crc correcto."""
    client.hello()

    image = bytes(range(256)) * 2029
    image = image[:416 * 416 * 3]
    client.write_input(addr=0x10000000, data=image)

    w = b"\x01" * 864
    client.write_weights(layer_idx=0, addr=0x12000000, data=w)

    bias = struct.pack("<" + "i" * 32, *([0] * 32))
    client.write_bias(layer_idx=0, addr=0x12A00000, data=bias)

    cfg = LayerCfg(
        op_type=OpType.CONV, layer_idx=0,
        c_in=3, c_out=32, h_in=416, w_in=416, h_out=416, w_out=416,
        kh=3, kw=3, stride_h=1, stride_w=1,
        pad_top=1, pad_bottom=1, pad_left=1, pad_right=1,
        in_addr=0x10000000, out_addr=0x16000000,
        w_addr=0x12000000, b_addr=0x12A00000,
    )
    client.write_cfg(cfg)

    res = client.exec_layer(0)
    assert res.status == Err.OK
    assert res.out_bytes == 32 * 416 * 416
    # mock retorna zeros → crc conocido
    expected_crc = crc32(bytes(res.out_bytes))
    assert res.out_crc == expected_crc


# =============================================================================
# READ_ACTIVATION con verificación CRC
# =============================================================================
def test_read_activation_round_trip(client, mock_server):
    client.hello()
    # inyectar datos directamente en la DDR virtual del mock
    payload = bytes(range(256)) * 1024
    mock_server.ddr.write(0x16000000, payload)

    data, crc_reported = client.read_activation(0x16000000, len(payload))
    assert data == payload
    assert crc_reported == crc32(payload)


# =============================================================================
# Simulación de las 255 capas — no crashea, state consistente
# =============================================================================
def test_network_simulation_255_layers(client, mock_server):
    """Write cfgs, weights, biases y ejecuta cada layer. No verifica numerics,
    sí verifica que el protocolo no se desincroniza y el estado queda coherente.
    """
    client.hello()

    # INPUT único
    image = bytes([7]) * (416 * 416 * 3)
    client.write_input(addr=0x10000000, data=image)

    # Stubs de CFGs: todas CONV minúsculas para que el mock acepte
    cfgs = []
    for i in range(255):
        cfg = LayerCfg(
            op_type=OpType.CONV, layer_idx=i,
            c_in=4, c_out=4, h_in=4, w_in=4, h_out=4, w_out=4,
            kh=1, kw=1, stride_h=1, stride_w=1,
            in_addr=0x10000000 if i == 0 else 0x16000000 + (i * 256),
            out_addr=0x16000000 + ((i + 1) * 256),
            w_addr=0x12000000 + i * 64,
            b_addr=0x12A00000 + i * 16,
        )
        cfgs.append(cfg)

    client.write_cfg_array(cfgs)

    # Weights/bias dummy por layer
    for i in range(255):
        client.write_weights(i, 0x12000000 + i * 64, b"\x01" * 16)
        client.write_bias(i, 0x12A00000 + i * 16, b"\x00" * 16)

    # Ejecutar en orden
    for i in range(255):
        res = client.exec_layer(i)
        assert res.status == Err.OK, f"layer {i} fail status=0x{res.status:08x}"

    # Estado final coherente
    states = client.get_state()
    for s in states:
        assert s["cfg_set"]
        assert s["w_loaded"]
        assert s["b_loaded"]
        assert s["executed"]


# =============================================================================
# get_state / reset_state
# =============================================================================
def test_reset_state_clears_flags(client, mock_server):
    client.hello()
    w = b"\x01" * 16
    client.write_weights(layer_idx=10, addr=0x12000000, data=w)
    assert mock_server.state.layer[10].w_loaded
    client.reset_state()
    assert not mock_server.state.layer[10].w_loaded


def test_get_state_reports_flags(client, mock_server):
    client.hello()
    w = b"\x00" * 32
    client.write_weights(layer_idx=100, addr=0x12000000, data=w)
    st = client.get_state()
    assert len(st) == 255
    assert st[100]["w_loaded"]
    assert not st[100]["b_loaded"]


# =============================================================================
# tag mismatch detection
# =============================================================================
def test_tag_is_preserved_in_response(client):
    client.hello()
    # Manda 2 pings seguidos y verifica que ambos responden con su tag
    for _ in range(5):
        client.ping()


# =============================================================================
# exec_hook custom: inyectar activación de referencia
# =============================================================================
def test_custom_exec_hook_out_crc(mock_server):
    """Usa exec_hook para devolver datos conocidos → verifica out_crc."""
    expected = b"\x55" * 256

    def hook(cfg, srv):
        return expected

    mock_server.exec_hook = hook

    h = DpuHost("127.0.0.1", port=mock_server.port, timeout=5.0)
    h.connect()
    try:
        h.hello()
        cfg = LayerCfg(
            op_type=OpType.CONV, layer_idx=42,
            c_in=4, c_out=4, h_in=4, w_in=4, h_out=4, w_out=4,
            kh=1, kw=1,
            in_addr=0x10000000, out_addr=0x16000000,
            w_addr=0x12000000, b_addr=0x12A00000,
        )
        h.write_cfg(cfg)
        h.write_weights(42, 0x12000000, b"\x01" * 16)
        h.write_bias(42, 0x12A00000, b"\x00" * 16)

        # El layer 42 no tiene input_ok automáticamente, inyectamos:
        h.write_activation_in(42, 0x10000000, b"\x00" * 64)

        res = h.exec_layer(42)
        assert res.status == Err.OK
        assert res.out_crc == crc32(expected)
    finally:
        h.close()
