#include "CRealtime.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct mm_ring {
    float *buf;
    uint32_t capacity;
    uint32_t mask;
    // Monotonic counters; their difference is the fill level. 64-bit so they
    // never wrap in the life of the process.
    _Atomic uint64_t head; // written by the producer
    _Atomic uint64_t tail; // written by the consumer
    _Atomic uint64_t dropped;
};

mm_ring *mm_ring_create(uint32_t capacity) {
    if (capacity < 2) capacity = 2;
    uint32_t cap = 1;
    while (cap < capacity) {
        if (cap > (1u << 30)) return NULL;
        cap <<= 1;
    }
    mm_ring *r = calloc(1, sizeof(*r));
    if (!r) return NULL;
    r->buf = calloc(cap, sizeof(float));
    if (!r->buf) {
        free(r);
        return NULL;
    }
    r->capacity = cap;
    r->mask = cap - 1;
    atomic_init(&r->head, 0);
    atomic_init(&r->tail, 0);
    atomic_init(&r->dropped, 0);
    return r;
}

void mm_ring_destroy(mm_ring *r) {
    if (!r) return;
    free(r->buf);
    free(r);
}

uint32_t mm_ring_capacity(const mm_ring *r) { return r->capacity; }

uint32_t mm_ring_write(mm_ring *r, const float *samples, uint32_t n) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_relaxed);
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_acquire);
    uint32_t free_slots = r->capacity - (uint32_t)(head - tail);
    uint32_t count = n < free_slots ? n : free_slots;
    if (count < n) {
        atomic_fetch_add_explicit(&r->dropped, n - count, memory_order_relaxed);
    }
    if (count == 0) return 0;

    uint32_t start = (uint32_t)head & r->mask;
    uint32_t first = r->capacity - start;
    if (first > count) first = count;
    memcpy(r->buf + start, samples, first * sizeof(float));
    if (count > first) {
        memcpy(r->buf, samples + first, (count - first) * sizeof(float));
    }
    atomic_store_explicit(&r->head, head + count, memory_order_release);
    return count;
}

uint32_t mm_ring_read(mm_ring *r, float *out, uint32_t max) {
    uint64_t tail = atomic_load_explicit(&r->tail, memory_order_relaxed);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint32_t avail = (uint32_t)(head - tail);
    uint32_t count = max < avail ? max : avail;
    if (count == 0) return 0;

    uint32_t start = (uint32_t)tail & r->mask;
    uint32_t first = r->capacity - start;
    if (first > count) first = count;
    memcpy(out, r->buf + start, first * sizeof(float));
    if (count > first) {
        memcpy(out + first, r->buf, (count - first) * sizeof(float));
    }
    atomic_store_explicit(&r->tail, tail + count, memory_order_release);
    return count;
}

uint32_t mm_ring_available(const mm_ring *r) {
    uint64_t head = atomic_load_explicit(&((mm_ring *)r)->head, memory_order_acquire);
    uint64_t tail = atomic_load_explicit(&((mm_ring *)r)->tail, memory_order_acquire);
    return (uint32_t)(head - tail);
}

uint64_t mm_ring_take_dropped(mm_ring *r) {
    return atomic_exchange_explicit(&r->dropped, 0, memory_order_relaxed);
}

void mm_ring_clear(mm_ring *r) {
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    atomic_store_explicit(&r->tail, head, memory_order_release);
}
