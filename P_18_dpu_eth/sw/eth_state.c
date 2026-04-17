/*
 * eth_state.c -- Estado global del server P_18 (layer_state_t + cfgs).
 *
 * Estas variables son consultadas por eth_server.c al procesar
 * CMD_EXEC_LAYER (validación de prerrequisitos), y actualizadas por cada
 * CMD_WRITE_*.
 *
 * Los layer_cfg_t también se replican en DDR (ADDR_CFG_ARRAY) para que el
 * cliente pueda verificarlos con un READ_RAW si lo desea; pero el ARM
 * consulta esta copia en OCM/heap para evitar round-trips a DDR en cada
 * EXEC.
 */
#include "eth_protocol.h"
#include <string.h>

/* Inicializados a cero -> todos los flags limpios, proto_ver se setea
 * durante CMD_HELLO. */
global_state_t g_state;
layer_cfg_t    g_cfgs[N_LAYERS];

/* Helper llamado desde main() tras cache init */
void eth_state_init(void)
{
    memset(&g_state, 0, sizeof(g_state));
    memset(g_cfgs,   0, sizeof(g_cfgs));
    g_state.proto_ver = ETH_PROTO_VERSION;
}
