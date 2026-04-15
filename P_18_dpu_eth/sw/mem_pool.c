/*
 * mem_pool.c -- Bump-and-recycle allocator simple para activaciones YOLOv4.
 *
 * VERSION 1: bump allocator + liberacion por "producer_layer". No hace
 * compactacion ni free list. Suficiente para YOLOv4 con refcount manual
 * desde el orquestrador (el runtime release() cuando el ultimo consumer
 * de una layer ya corrio).
 */

#include "dpu_api.h"
#include "xil_printf.h"

/* Max slots that can be alive simultaneously */
#define POOL_MAX_ALIVE  64

typedef struct {
    uint32_t    ddr_addr;
    uint32_t    bytes;
    uint16_t    producer;  /* layer index that produced this buffer */
    uint16_t    alive;     /* 1 = ocupa, 0 = libre */
} slot_t;

struct mem_pool {
    uintptr_t   base;
    uint32_t    total;
    uint32_t    bump;   /* siguiente direccion libre (high-water) */
    slot_t      slots[POOL_MAX_ALIVE];
};

static struct mem_pool g_pool;

mem_pool_t *pool_create(uintptr_t base, uint32_t bytes)
{
    g_pool.base  = base;
    g_pool.total = bytes;
    g_pool.bump  = 0;
    for (int i = 0; i < POOL_MAX_ALIVE; i++) {
        g_pool.slots[i].alive = 0;
    }
    return &g_pool;
}

/* Bump allocator con busqueda de hueco liberado */
uint8_t *pool_alloc(mem_pool_t *p, uint32_t bytes, uint16_t producer_layer)
{
    /* 1. Intenta reutilizar slot liberado que sirva */
    for (int i = 0; i < POOL_MAX_ALIVE; i++) {
        if (!p->slots[i].alive && p->slots[i].bytes >= bytes) {
            p->slots[i].alive    = 1;
            p->slots[i].producer = producer_layer;
            return (uint8_t *)(p->base + p->slots[i].ddr_addr);
        }
    }
    /* 2. Asigna nuevo slot bump */
    /* Align a 64 bytes para cache line */
    uint32_t aligned = (bytes + 63) & ~63U;
    if (p->bump + aligned > p->total) {
        xil_printf("POOL EXHAUSTED bump=%u bytes=%u total=%u\r\n",
                   p->bump, aligned, p->total);
        return 0;
    }
    /* find free slot idx */
    for (int i = 0; i < POOL_MAX_ALIVE; i++) {
        if (!p->slots[i].alive) {
            p->slots[i].ddr_addr = p->bump;
            p->slots[i].bytes    = aligned;
            p->slots[i].producer = producer_layer;
            p->slots[i].alive    = 1;
            uint8_t *ptr = (uint8_t *)(p->base + p->bump);
            p->bump += aligned;
            return ptr;
        }
    }
    xil_printf("POOL slots exhausted\r\n");
    return 0;
}

void pool_release(mem_pool_t *p, uint16_t producer_layer)
{
    for (int i = 0; i < POOL_MAX_ALIVE; i++) {
        if (p->slots[i].alive && p->slots[i].producer == producer_layer) {
            p->slots[i].alive = 0;
            return;
        }
    }
}

uint32_t pool_bytes_used(mem_pool_t *p)
{
    uint32_t live = 0;
    for (int i = 0; i < POOL_MAX_ALIVE; i++) {
        if (p->slots[i].alive) live += p->slots[i].bytes;
    }
    return live;
}
