/*
 * main.c -- P_18 DPU + Ethernet TCP bare-metal entry point.
 *
 * - Inicializa lwIP + netif estatico 192.168.1.10
 * - Inicializa DPU (dpu_init)
 * - Arranca eth_server en puerto 7001 (protocolo P_18)
 * - Loop principal: procesa paquetes + TCP timers
 *
 * Base: P_400_eth_debug/sw/main.c (simplificado, solo TCP).
 */

#include <stdio.h>
#include <string.h>

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_cache.h"

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "netif/xadapter.h"

#include "platform_eth.h"
#include "dpu_api.h"
#include "eth_protocol.h"

/* ---- Network config ---- */
#define BOARD_IP_1  192
#define BOARD_IP_2  168
#define BOARD_IP_3  1
#define BOARD_IP_4  10

#define NETMASK_1   255
#define NETMASK_2   255
#define NETMASK_3   255
#define NETMASK_4   0

#define GW_1        192
#define GW_2        168
#define GW_3        1
#define GW_4        1

extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;

/* Exposed by eth_server.c */
void eth_server_init(void);

static struct netif server_netif;
static unsigned char mac_addr[] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};

int main(void)
{
    struct netif *netif = &server_netif;
    ip_addr_t ipaddr, netmask, gw;

    /* Init caches + GIC + SCU timer (lwIP tcp_fasttmr/slowtmr depends on this) */
    init_platform();

    /* Pre-compute CRC32 table BEFORE any callback que lo use.
     * No lazy-init dentro de on_recv (eso rompió V1). */
    p18_crc32_init();

    xil_printf("\r\n\r\n##############################################\r\n");
    xil_printf("  P_18 DPU+Ethernet server\r\n");
    xil_printf("##############################################\r\n");

    lwip_init();

    IP4_ADDR(&ipaddr,  BOARD_IP_1, BOARD_IP_2, BOARD_IP_3, BOARD_IP_4);
    IP4_ADDR(&netmask, NETMASK_1,  NETMASK_2,  NETMASK_3,  NETMASK_4);
    IP4_ADDR(&gw,      GW_1,       GW_2,       GW_3,       GW_4);

    if (!xemac_add(netif, &ipaddr, &netmask, &gw, mac_addr,
                   XPAR_XEMACPS_0_BASEADDR)) {
        xil_printf("ERROR: xemac_add\r\n");
        return -1;
    }
    netif_set_default(netif);
    netif_set_up(netif);

    /* Enable IRQ mask AFTER netif is up (matches P_400 sequence) */
    platform_enable_interrupts();

    xil_printf("Network up: %d.%d.%d.%d mask %d.%d.%d.%d\r\n",
               BOARD_IP_1, BOARD_IP_2, BOARD_IP_3, BOARD_IP_4,
               NETMASK_1, NETMASK_2, NETMASK_3, NETMASK_4);

    /* Init DPU wrapper */
    int dpu_r = dpu_init();
    if (dpu_r != DPU_OK) {
        xil_printf("ERROR: dpu_init=%d\r\n", dpu_r);
    } else {
        xil_printf("DPU init OK\r\n");
    }

    /* Arranca servidor TCP P_18 */
    eth_server_init();

    /* Main loop lwIP */
    while (1) {
        if (TcpFastTmrFlag) {
            tcp_fasttmr();
            TcpFastTmrFlag = 0;
        }
        if (TcpSlowTmrFlag) {
            tcp_slowtmr();
            TcpSlowTmrFlag = 0;
        }
        xemacif_input(netif);
    }

    return 0;
}
