/*
 * P_400 ETH Debug - ZedBoard
 *
 * Bare-metal lwIP application:
 *   - TCP echo server on port 7 (for ping/telnet test)
 *   - UDP debug channel on port 7777:
 *       ping              -> "pong"
 *       read  <hex_addr>  -> reads 32-bit word
 *       write <hex_addr> <hex_val> -> writes 32-bit word
 *       dump  <hex_addr> [count]   -> reads N words
 *
 * Board IP: 192.168.1.10 (static)
 * PC IP:    configure your Ethernet adapter to 192.168.1.x
 */

#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "xparameters.h"
#include "xil_printf.h"
#include "xil_io.h"
#include "xil_cache.h"

#include "lwip/init.h"
#include "lwip/tcp.h"
#include "lwip/udp.h"
#include "netif/xadapter.h"

#include "platform_eth.h"

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

#define TCP_ECHO_PORT  7
#define UDP_DBG_PORT   7777

/* ---- Globals ---- */
extern volatile int TcpFastTmrFlag;
extern volatile int TcpSlowTmrFlag;

static struct netif server_netif;
static unsigned char mac_addr[] = {0x00, 0x0a, 0x35, 0x00, 0x01, 0x02};

/* ============================================================
 * TCP Echo Server
 * ============================================================ */
static err_t echo_recv(void *arg, struct tcp_pcb *tpcb,
                       struct pbuf *p, err_t err)
{
    if (!p) {
        tcp_close(tpcb);
        return ERR_OK;
    }
    tcp_recved(tpcb, p->tot_len);
    tcp_write(tpcb, p->payload, p->tot_len, TCP_WRITE_FLAG_COPY);
    tcp_output(tpcb);
    pbuf_free(p);
    return ERR_OK;
}

static err_t echo_accept(void *arg, struct tcp_pcb *newpcb, err_t err)
{
    tcp_recv(newpcb, echo_recv);
    xil_printf("TCP: client connected\r\n");
    return ERR_OK;
}

static void setup_tcp_echo(void)
{
    struct tcp_pcb *pcb = tcp_new();
    tcp_bind(pcb, IP_ADDR_ANY, TCP_ECHO_PORT);
    pcb = tcp_listen(pcb);
    tcp_accept(pcb, echo_accept);
    xil_printf("  TCP echo   -> port %d\r\n", TCP_ECHO_PORT);
}

/* ============================================================
 * UDP Debug Channel - read/write memory over Ethernet
 * ============================================================ */
static void udp_send_reply(struct udp_pcb *pcb, const ip_addr_t *addr,
                           u16_t port, const char *msg, u16_t len)
{
    struct pbuf *rp = pbuf_alloc(PBUF_TRANSPORT, len, PBUF_RAM);
    if (rp) {
        memcpy(rp->payload, msg, len);
        udp_sendto(pcb, rp, addr, port);
        pbuf_free(rp);
    }
}

static void udp_debug_recv(void *arg, struct udp_pcb *pcb, struct pbuf *p,
                           const ip_addr_t *addr, u16_t port)
{
    if (!p) return;

    char cmd[256];
    u16_t len = (p->tot_len < 255) ? p->tot_len : 255;
    pbuf_copy_partial(p, cmd, len, 0);
    cmd[len] = '\0';
    pbuf_free(p);

    /* strip trailing whitespace */
    while (len > 0 && (cmd[len-1] == '\n' || cmd[len-1] == '\r' || cmd[len-1] == ' '))
        cmd[--len] = '\0';

    char reply[2048];
    int rlen = 0;

    /* ---- ping ---- */
    if (strcmp(cmd, "ping") == 0) {
        rlen = snprintf(reply, sizeof(reply), "pong\n");
    }
    /* ---- read <hex_addr> ---- */
    else if (strncmp(cmd, "read ", 5) == 0) {
        u32 a = (u32)strtoul(cmd + 5, NULL, 16);
        u32 d = Xil_In32(a);
        rlen = snprintf(reply, sizeof(reply),
                        "0x%08lX = 0x%08lX\n",
                        (unsigned long)a, (unsigned long)d);
        xil_printf("R [0x%08lX] = 0x%08lX\r\n",
                   (unsigned long)a, (unsigned long)d);
    }
    /* ---- write <hex_addr> <hex_val> ---- */
    else if (strncmp(cmd, "write ", 6) == 0) {
        char *sp = strchr(cmd + 6, ' ');
        if (sp) {
            u32 a = (u32)strtoul(cmd + 6, NULL, 16);
            u32 d = (u32)strtoul(sp + 1, NULL, 16);
            Xil_Out32(a, d);
            rlen = snprintf(reply, sizeof(reply),
                            "W [0x%08lX] <- 0x%08lX OK\n",
                            (unsigned long)a, (unsigned long)d);
            xil_printf("W [0x%08lX] <- 0x%08lX\r\n",
                       (unsigned long)a, (unsigned long)d);
        } else {
            rlen = snprintf(reply, sizeof(reply),
                            "ERR: usage: write <addr> <val>\n");
        }
    }
    /* ---- dump <hex_addr> [count] ---- */
    else if (strncmp(cmd, "dump ", 5) == 0) {
        char *sp = strchr(cmd + 5, ' ');
        u32 base = (u32)strtoul(cmd + 5, NULL, 16);
        u32 cnt  = sp ? (u32)strtoul(sp + 1, NULL, 10) : 4;
        if (cnt > 128) cnt = 128;

        rlen = 0;
        u32 i;
        for (i = 0; i < cnt && rlen < (int)sizeof(reply) - 40; i++) {
            u32 a = base + i * 4;
            rlen += snprintf(reply + rlen, sizeof(reply) - rlen,
                             "0x%08lX = 0x%08lX\n",
                             (unsigned long)a,
                             (unsigned long)Xil_In32(a));
        }
        xil_printf("DUMP 0x%08lX x%lu\r\n",
                   (unsigned long)base, (unsigned long)cnt);
    }
    /* ---- help / unknown ---- */
    else {
        rlen = snprintf(reply, sizeof(reply),
            "P_400 ETH Debug commands:\n"
            "  ping\n"
            "  read  <hex_addr>\n"
            "  write <hex_addr> <hex_val>\n"
            "  dump  <hex_addr> [count]\n");
    }

    if (rlen > 0)
        udp_send_reply(pcb, addr, port, reply, (u16_t)rlen);
}

static void setup_udp_debug(void)
{
    struct udp_pcb *pcb = udp_new();
    udp_bind(pcb, IP_ADDR_ANY, UDP_DBG_PORT);
    udp_recv(pcb, udp_debug_recv, NULL);
    xil_printf("  UDP debug  -> port %d\r\n", UDP_DBG_PORT);
}

/* ============================================================
 * Main
 * ============================================================ */
int main(void)
{
    ip_addr_t ipaddr, netmask, gw;

    init_platform();

    xil_printf("\r\n");
    xil_printf("========================================\r\n");
    xil_printf("  P_400 ETH Debug - ZedBoard\r\n");
    xil_printf("========================================\r\n");

    lwip_init();

    IP4_ADDR(&ipaddr,  BOARD_IP_1, BOARD_IP_2, BOARD_IP_3, BOARD_IP_4);
    IP4_ADDR(&netmask, NETMASK_1,  NETMASK_2,  NETMASK_3,  NETMASK_4);
    IP4_ADDR(&gw,      GW_1,       GW_2,       GW_3,       GW_4);

    if (!xemac_add(&server_netif, &ipaddr, &netmask, &gw,
                   mac_addr, PLATFORM_EMAC_BASEADDR)) {
        xil_printf("ERROR: xemac_add failed\r\n");
        return -1;
    }
    netif_set_default(&server_netif);
    netif_set_up(&server_netif);

    platform_enable_interrupts();

    xil_printf("Board IP: %d.%d.%d.%d\r\n",
               BOARD_IP_1, BOARD_IP_2, BOARD_IP_3, BOARD_IP_4);

    setup_tcp_echo();
    setup_udp_debug();

    xil_printf("----------------------------------------\r\n");
    xil_printf("Ready! From PC run:\r\n");
    xil_printf("  ping 192.168.1.10\r\n");
    xil_printf("  python eth_debug.py ping\r\n");
    xil_printf("  python eth_debug.py read 0xF8000000\r\n");
    xil_printf("========================================\r\n\r\n");

    /* Main polling loop */
    while (1) {
        if (TcpFastTmrFlag) {
            tcp_fasttmr();
            TcpFastTmrFlag = 0;
        }
        if (TcpSlowTmrFlag) {
            tcp_slowtmr();
            TcpSlowTmrFlag = 0;
        }
        xemacif_input(&server_netif);
    }

    cleanup_platform();
    return 0;
}
