/*
 * example_main.c - Example: how to use eth_debug in your project
 *
 * This shows the MINIMUM code needed to add Ethernet debug
 * to any bare-metal Zynq project on ZedBoard.
 */

#include "eth_debug.h"

int main(void)
{
    /* Step 1: Initialize (does everything: GIC, lwIP, GEM, UDP) */
    if (eth_debug_init() != 0) {
        return -1;  /* Ethernet init failed */
    }

    eth_printf("My project started!\n");

    /* Step 2: Your application loop */
    int counter = 0;
    while (1) {
        /* MUST call this regularly - processes network packets */
        eth_debug_poll();

        /* Your application code here... */
        counter++;

        /* Use eth_printf like regular printf */
        if (counter % 5000000 == 0) {
            eth_printf("counter = %d\n", counter / 5000000);
        }
    }

    return 0;
}
