#include "lumora_ring.h"

#include <fcntl.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#define MAGIC 0x4C4D5247u /* "LMRG" */
#define VERSION 1u

typedef struct {
    uint32_t magic, version, slots, slot_bytes;
    _Atomic uint64_t latest;      /* sequence of the newest committed frame (0 = none) */
    _Atomic uint32_t latest_slot;
    _Atomic uint32_t state;
    _Atomic uint32_t display_w, display_h;
    _Atomic uint32_t scale_bits;  /* float bits */
    uint8_t reserved[128 - 44];
} ring_header;

typedef struct {
    _Atomic uint64_t seq;          /* odd while being written */
    uint32_t width, height, stride, format;
    uint64_t ts_us;
    uint8_t reserved[64 - 32];
} slot_header;

_Static_assert(sizeof(ring_header) == 128, "header layout");
_Static_assert(sizeof(slot_header) == 64, "slot layout");

struct lumora_ring {
    uint8_t *base;
    size_t size;
    int writer;
    uint32_t cur;      /* writer: slot being written */
    uint64_t next_seq; /* writer: sequence of the frame being written (even) */
};

static size_t ring_size(void) {
    return sizeof(ring_header) + (size_t)LUMORA_RING_SLOTS * (sizeof(slot_header) + LUMORA_RING_SLOT_BYTES);
}

static ring_header *hdr(lumora_ring *r) { return (ring_header *)r->base; }

static slot_header *slot(lumora_ring *r, uint32_t i) {
    return (slot_header *)(r->base + sizeof(ring_header) + (size_t)i * (sizeof(slot_header) + LUMORA_RING_SLOT_BYTES));
}

static uint8_t *slot_data(lumora_ring *r, uint32_t i) { return (uint8_t *)slot(r, i) + sizeof(slot_header); }

lumora_ring *lumora_ring_open(const char *path, int writer) {
    size_t size = ring_size();
    int fd = open(path, writer ? (O_RDWR | O_CREAT) : O_RDWR, 0600);
    if (fd < 0) return NULL;
    struct stat st;
    if (fstat(fd, &st) != 0) { close(fd); return NULL; }
    if ((size_t)st.st_size != size) {
        if (!writer || ftruncate(fd, (off_t)size) != 0) { close(fd); return NULL; }
    }
    void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (p == MAP_FAILED) return NULL;
    lumora_ring *r = calloc(1, sizeof *r);
    if (!r) { munmap(p, size); return NULL; }
    r->base = p;
    r->size = size;
    r->writer = writer;
    ring_header *h = hdr(r);
    int valid = h->magic == MAGIC && h->version == VERSION && h->slots == LUMORA_RING_SLOTS && h->slot_bytes == LUMORA_RING_SLOT_BYTES;
    if (writer) {
        if (!valid) {
            memset(h, 0, sizeof *h);
            for (uint32_t i = 0; i < LUMORA_RING_SLOTS; i++) atomic_store(&slot(r, i)->seq, 0);
            h->slots = LUMORA_RING_SLOTS;
            h->slot_bytes = LUMORA_RING_SLOT_BYTES;
            h->version = VERSION;
            atomic_thread_fence(memory_order_release);
            h->magic = MAGIC;
        }
        /* continue numbering after whatever a previous run committed */
        uint64_t last = atomic_load_explicit(&h->latest, memory_order_acquire);
        for (uint32_t i = 0; i < LUMORA_RING_SLOTS; i++) {
            uint64_t s = atomic_load_explicit(&slot(r, i)->seq, memory_order_acquire);
            if (s > last) last = s;
        }
        r->next_seq = (last | 1u) + 1u; /* next even number above everything seen */
        r->cur = atomic_load_explicit(&h->latest_slot, memory_order_acquire) % LUMORA_RING_SLOTS;
    } else if (!valid) {
        lumora_ring_close(r);
        return NULL;
    }
    return r;
}

void lumora_ring_close(lumora_ring *r) {
    if (!r) return;
    munmap(r->base, r->size);
    free(r);
}

uint8_t *lumora_ring_begin(lumora_ring *r, uint32_t width, uint32_t height, uint32_t stride, uint32_t format) {
    if (!r || !r->writer || width == 0 || height == 0 || stride < width * 4u) return NULL;
    if ((uint64_t)stride * height > LUMORA_RING_SLOT_BYTES) return NULL;
    /* never the slot the reader is most likely copying (the newest) */
    r->cur = (atomic_load_explicit(&hdr(r)->latest_slot, memory_order_acquire) + 1u) % LUMORA_RING_SLOTS;
    slot_header *s = slot(r, r->cur);
    atomic_store_explicit(&s->seq, r->next_seq - 1u, memory_order_release); /* odd: busy */
    atomic_thread_fence(memory_order_release);
    s->width = width;
    s->height = height;
    s->stride = stride;
    s->format = format;
    return slot_data(r, r->cur);
}

void lumora_ring_commit(lumora_ring *r, uint64_t ts_us) {
    if (!r || !r->writer) return;
    slot_header *s = slot(r, r->cur);
    s->ts_us = ts_us;
    atomic_thread_fence(memory_order_release);
    atomic_store_explicit(&s->seq, r->next_seq, memory_order_release);
    atomic_store_explicit(&hdr(r)->latest_slot, r->cur, memory_order_release);
    atomic_store_explicit(&hdr(r)->latest, r->next_seq, memory_order_release);
    r->next_seq += 2u;
}

void lumora_ring_abort(lumora_ring *r) {
    if (!r || !r->writer) return;
    /* 0 is never newer than anything a reader has seen: the slot reads as empty */
    atomic_store_explicit(&slot(r, r->cur)->seq, 0, memory_order_release);
}

void lumora_ring_set_state(lumora_ring *r, uint32_t state, uint32_t display_w, uint32_t display_h, float scale) {
    if (!r) return;
    ring_header *h = hdr(r);
    uint32_t bits;
    memcpy(&bits, &scale, sizeof bits);
    atomic_store(&h->display_w, display_w);
    atomic_store(&h->display_h, display_h);
    atomic_store(&h->scale_bits, bits);
    atomic_store_explicit(&h->state, state, memory_order_release);
}

uint32_t lumora_ring_state(lumora_ring *r, uint32_t *display_w, uint32_t *display_h, float *scale) {
    if (!r) return LUMORA_RING_STOPPED;
    ring_header *h = hdr(r);
    uint32_t st = atomic_load_explicit(&h->state, memory_order_acquire);
    if (display_w) *display_w = atomic_load(&h->display_w);
    if (display_h) *display_h = atomic_load(&h->display_h);
    if (scale) {
        uint32_t bits = atomic_load(&h->scale_bits);
        memcpy(scale, &bits, sizeof bits);
    }
    return st;
}

int64_t lumora_ring_read(lumora_ring *r, uint64_t *last_seq, uint8_t *dst, size_t cap, uint32_t *width, uint32_t *height,
                         uint32_t *stride, uint32_t *format, uint64_t *ts_us) {
    if (!r || !last_seq || !dst) return -1;
    ring_header *h = hdr(r);
    uint64_t latest = atomic_load_explicit(&h->latest, memory_order_acquire);
    if (latest == 0 || latest <= *last_seq) return 0;
    uint32_t i = atomic_load_explicit(&h->latest_slot, memory_order_acquire) % LUMORA_RING_SLOTS;
    slot_header *s = slot(r, i);
    uint64_t s1 = atomic_load_explicit(&s->seq, memory_order_acquire);
    if ((s1 & 1u) || s1 <= *last_seq) return 0;
    uint32_t w = s->width, hh = s->height, st = s->stride, f = s->format;
    uint64_t ts = s->ts_us;
    size_t n = (size_t)st * hh;
    if (n == 0 || n > LUMORA_RING_SLOT_BYTES) return 0;
    if (n > cap) return -1;
    memcpy(dst, slot_data(r, i), n);
    atomic_thread_fence(memory_order_acquire);
    uint64_t s2 = atomic_load_explicit(&s->seq, memory_order_acquire);
    if (s1 != s2) return 0; /* overwritten while copying: drop, a newer frame is coming */
    *last_seq = s1;
    if (width) *width = w;
    if (height) *height = hh;
    if (stride) *stride = st;
    if (format) *format = f;
    if (ts_us) *ts_us = ts;
    return (int64_t)n;
}
