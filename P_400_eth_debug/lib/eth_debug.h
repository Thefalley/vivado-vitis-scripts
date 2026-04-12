/*
 * eth_debug.h - Ethernet Debug Library for ZedBoard (Zynq-7020)
 *
 * Drop-in replacement for printf: sends output to PC over UDP.
 * No UART needed. No JTAG needed for data inspection.
 *
 * === QUICK START ===
 *
 *   #include "eth_debug.h"
 *
 *   int main(void) {
 *       eth_debug_init();                     // once at startup
 *       eth_printf("Hello from ZedBoard!\n");
 *       while (1) {
 *           eth_debug_poll();                 // call often in main loop
 *           eth_printf("val = %d\n", my_val); // use anywhere
 *       }
 *   }
 *
 * === PC SIDE ===
 *
 *   python eth_debug.py           # interactive shell
 *   python eth_debug.py ping      # connectivity test
 *   python eth_debug.py read 0xF8000530   # read any register
 *
 * === REQUIREMENTS ===
 *
 *   1. Vitis BSP must include lwip220 library (RAW API, no DHCP)
 *   2. Copy eth_debug.c, eth_debug.h, platform_eth.c, platform_eth.h
 *      into your Vitis project's src/ directory
 *   3. Board IP: 192.168.1.10 (hardcoded, change below if needed)
 *   4. PC Ethernet adapter: 192.168.1.100
 *   5. ZedBoard Ethernet cable directly to PC
 */

#ifndef ETH_DEBUG_H
#define ETH_DEBUG_H

#include <stdarg.h>

/* ---- Configuration (change these if needed) ---- */
#define ETH_DBG_BOARD_IP1   192
#define ETH_DBG_BOARD_IP2   168
#define ETH_DBG_BOARD_IP3   1
#define ETH_DBG_BOARD_IP4   10

#define ETH_DBG_NETMASK1    255
#define ETH_DBG_NETMASK2    255
#define ETH_DBG_NETMASK3    255
#define ETH_DBG_NETMASK4    0

#define ETH_DBG_GW1         192
#define ETH_DBG_GW2         168
#define ETH_DBG_GW3         1
#define ETH_DBG_GW4         1

#define ETH_DBG_UDP_PORT    7777
#define ETH_DBG_TCP_PORT    7

/* ---- Public API ---- */

/*
 * Initialize Ethernet debug subsystem.
 * Call ONCE at the start of main(), before any eth_printf().
 * This sets up: GIC, timers, lwIP, GEM0, TCP echo, UDP debug.
 * Returns 0 on success, -1 on failure.
 */
int eth_debug_init(void);

/*
 * Printf over Ethernet.
 * Sends formatted string as UDP packet to the last PC that sent us a command,
 * or to broadcast if no PC has connected yet.
 * Max message length: 1400 bytes (single UDP packet).
 * Safe to call from anywhere (ISR-safe: NO, main loop only).
 */
void eth_printf(const char *fmt, ...);

/*
 * Poll the network stack.
 * MUST be called regularly in your main loop (at least every ~10ms).
 * Processes: incoming packets, TCP timers, UDP commands (read/write/dump).
 */
void eth_debug_poll(void);

/*
 * Check if Ethernet link is up.
 * Returns 1 if link is up, 0 if down.
 */
int eth_debug_link_up(void);

#endif /* ETH_DEBUG_H */
