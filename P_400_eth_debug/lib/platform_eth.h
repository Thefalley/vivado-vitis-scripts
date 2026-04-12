#ifndef PLATFORM_ETH_H
#define PLATFORM_ETH_H

#include "xparameters.h"
#include "xscugic.h"

#define PLATFORM_EMAC_BASEADDR  XPAR_XEMACPS_0_BASEADDR

void init_platform(void);
void cleanup_platform(void);
void platform_enable_interrupts(void);
XScuGic *get_gic_instance(void);

#endif
