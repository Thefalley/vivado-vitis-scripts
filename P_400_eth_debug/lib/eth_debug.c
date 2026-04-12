/*
 * eth_debug.c - Ethernet Debug Library for ZedBoard
 * See eth_debug.h for usage.
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>
#include <stdarg.h>

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "netif/xadapter.h"

#include "eth_debug.h"
#include "platform_eth.h"

/* ---- Internal state ---- */
extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;

static struct netif g_netif;
static unsigned char g_mac[] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};

static struct udp_pcb *g_dbg_pcb   = NULL;
static ip_addr_t       g_pc_addr;
static u16_t           g_pc_port   = 0;
static int             g_pc_known  = 0;
static int             g_init_done = 0;

/* ============================================================
 * Internal: UDP send helper
 * ============================================================ */
static void udp_send_buf(const char *buf, u16_t len,
                         const ip_addr_t *addr, u16_t port)
{
    if (!g_dbg_pcb) return;
    struct pbuf *p = pbuf_alloc(PBUF_TRANSPORT, len, PBUF_RAM);
    if (p) {
        memcpy(p->payload, buf, len);
        udp_sendto(g_dbg_pcb, p, addr, port);
        pbuf_free(p);
    }
}

/* ============================================================
 * Internal: UDP command handler (read/write/dump/ping)
 * ============================================================ */
static void udp_recv_handler(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                             const ip_addr_t *addr, u16_t port)
{
    if (!p) return;

    /* Remember PC address for eth_printf */
    g_pc_addr  = *addr;
    g_pc_port  = port;
    g_pc_known = 1;

    char cmd[256];
    u16_t len = (p->tot_len < 255) ? p->tot_len : 255;
    pbuf_copy_partial(p, cmd, len, 0);
    cmd[len] = '\0';
    pbuf_free(p);

    while (len > 0 && (cmd[len-1] == '\n' || cmd[len-1] == '\r' || cmd[len-1] == ' '))
        cmd[--len] = '\0';

    char reply[2048];
    int rlen = 0;

    if (strcmp(cmd, "ping") == 0) {
        rlen = snprintf(reply, sizeof(reply), "pong\n");
    }
    else if (strncmp(cmd, "read ", 5) == 0) {
        u32 a = (u32)strtoul(cmd + 5, NULL, 16);
        u32 d = Xil_In32(a);
        rlen = snprintf(reply, sizeof(reply),
                        "0x%08lX = 0x%08lX\n",
                        (unsigned long)a, (unsigned long)d);
    }
    else if (strncmp(cmd, "write ", 6) == 0) {
        char *sp = strchr(cmd + 6, ' ');
        if (sp) {
            u32 a = (u32)strtoul(cmd + 6, NULL, 16);
            u32 d = (u32)strtoul(sp + 1, NULL, 16);
            Xil_Out32(a, d);
            rlen = snprintf(reply, sizeof(reply),
                            "W [0x%08lX] <- 0x%08lX OK\n",
                            (unsigned long)a, (unsigned long)d);
        } else {
            rlen = snprintf(reply, sizeof(reply), "ERR: write <addr> <val>\n");
        }
    }
    else if (strncmp(cmd, "dump ", 5) == 0) {
        char *sp = strchr(cmd + 5, ' ');
        u32 base = (u32)strtoul(cmd + 5, NULL, 16);
        u32 cnt  = sp ? (u32)strtoul(sp + 1, NULL, 10) : 4;
        if (cnt > 128) cnt = 128;
        u32 i;
        for (i = 0; i < cnt && rlen < (int)sizeof(reply) - 40; i++) {
            u32 a = base + i * 4;
            rlen += snprintf(reply + rlen, sizeof(reply) - rlen,
                             "0x%08lX = 0x%08lX\n",
                             (unsigned long)a, (unsigned long)Xil_In32(a));
        }
    }
    else {
        rlen = snprintf(reply, sizeof(reply),
            "Commands: ping | read <addr> | write <addr> <val> | dump <addr> [n]\n");
    }

    if (rlen > 0)
        udp_send_buf(reply, (u16_t)rlen, addr, port);
}

/* ============================================================
 * Internal: TCP echo callbacks
 * ============================================================ */
static err_t tcp_echo_recv(void *arg, struct tcp_pcb *tpcb,
                           struct pbuf *p, err_t err)
{
    if (!p) { tcp_close(tpcb); return ERR_OK; }
    tcp_recved(tpcb, p->tot_len);
    tcp_write(tpcb, p->payload, p->tot_len, TCP_WRITE_FLAG_COPY);
    tcp_output(tpcb);
    pbuf_free(p);
    return ERR_OK;
}

static err_t tcp_echo_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    tcp_recv(newpcb, tcp_echo_recv);
    return ERR_OK;
}

/* ============================================================
 * Public: eth_debug_init
 * ============================================================ */
int eth_debug_init(void)
{
    ip_addr_t ipaddr, netmask, gw;

    init_platform();

    xil_printf("\r\n[eth_debug] Initializing...\r\n");

    lwip_init();

    IP4_ADDR(&ipaddr,  ETH_DBG_BOARD_IP1, ETH_DBG_BOARD_IP2,
                        ETH_DBG_BOARD_IP3, ETH_DBG_BOARD_IP4);
    IP4_ADDR(&netmask, ETH_DBG_NETMASK1, ETH_DBG_NETMASK2,
                        ETH_DBG_NETMASK3, ETH_DBG_NETMASK4);
    IP4_ADDR(&gw,      ETH_DBG_GW1, ETH_DBG_GW2,
                        ETH_DBG_GW3, ETH_DBG_GW4);

    if (!xemac_add(&g_netif, &ipaddr, &netmask, &gw,
                   g_mac, PLATFORM_EMAC_BASEADDR)) {
        xil_printf("[eth_debug] ERROR: xemac_add failed\r\n");
        return -1;
    }
    netif_set_default(&g_netif);
    netif_set_up(&g_netif);

    platform_enable_interrupts();

    /* TCP echo server */
    struct tcp_pcb *tpcb = tcp_new();
    tcp_bind(tpcb, IP_ADDR_ANY, ETH_DBG_TCP_PORT);
    tpcb = tcp_listen(tpcb);
    tcp_accept(tpcb, tcp_echo_accept);

    /* UDP debug channel */
    g_dbg_pcb = udp_new();
    udp_bind(g_dbg_pcb, IP_ADDR_ANY, ETH_DBG_UDP_PORT);
    udp_recv(g_dbg_pcb, udp_recv_handler, NULL);

    g_init_done = 1;

    xil_printf("[eth_debug] Ready at %d.%d.%d.%d (UDP %d, TCP %d)\r\n",
               ETH_DBG_BOARD_IP1, ETH_DBG_BOARD_IP2,
               ETH_DBG_BOARD_IP3, ETH_DBG_BOARD_IP4,
               ETH_DBG_UDP_PORT, ETH_DBG_TCP_PORT);

    return 0;
}

/* ============================================================
 * Public: eth_printf
 * ============================================================ */
void eth_printf(const char *fmt, ...)
{
    if (!g_init_done || !g_dbg_pcb) return;

    char buf[1400];
    va_list args;
    va_start(args, fmt);
    int len = vsnprintf(buf, sizeof(buf), fmt, args);
    va_end(args);

    if (len <= 0) return;
    if (len > (int)sizeof(buf)) len = sizeof(buf);

    /* Also print to UART if available */
    xil_printf("%s", buf);

    /* Send to last known PC, or broadcast */
    if (g_pc_known) {
        udp_send_buf(buf, (u16_t)len, &g_pc_addr, g_pc_port);
    } else {
        ip_addr_t bcast;
        IP4_ADDR(&bcast, 192, 168, 1, 255);
        udp_send_buf(buf, (u16_t)len, &bcast, ETH_DBG_UDP_PORT);
    }
}

/* ============================================================
 * Public: eth_debug_poll
 * ============================================================ */
void eth_debug_poll(void)
{
    if (!g_init_done) return;

    if (TcpFastTmrFlag) {
        tcp_fasttmr();
        TcpFastTmrFlag = 0;
    }
    if (TcpSlowTmrFlag) {
        tcp_slowtmr();
        TcpSlowTmrFlag = 0;
    }
    xemacif_input(&g_netif);
}

/* ============================================================
 * Public: eth_debug_link_up
 * ============================================================ */
int eth_debug_link_up(void)
{
    /* GEM0 Net Status register, bit 0 = link status (from PHY) */
    /* Actually check Net Control TX/RX enable as proxy */
    u32 ctrl = Xil_In32(0xE000B000);
    return (ctrl & 0x0C) ? 1 : 0;  /* bits 2,3 = RX_EN, TX_EN */
}
