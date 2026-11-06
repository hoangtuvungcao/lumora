/*
 * Lumora screen-frame ring: hands ReplayKit frames from the Broadcast Upload Extension
 * (separate process, ~50 MB memory cap) to the Lumora app through a file in the shared
 * App Group container, mapped MAP_SHARED by both processes.
 *
 * Single writer (extension), single reader (app). Each slot is a seqlock: the writer
 * makes the slot's sequence odd while copying, even when done; the reader re-checks
 * the sequence after copying and drops a frame that changed underneath it (never shows
 * a torn picture). Latency over completeness: the reader always takes the newest frame.
 *
 * Plain C11 (stdatomic + mmap), so it is unit-tested on Linux (tests/ring_test.c).
 */
#ifndef LUMORA_RING_H
#define LUMORA_RING_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define LUMORA_RING_SLOTS 3u
/* Frames are downscaled in the extension so the long side is at most this. */
#define LUMORA_RING_MAX_SIDE 960u
#define LUMORA_RING_SLOT_BYTES (LUMORA_RING_MAX_SIDE * LUMORA_RING_MAX_SIDE * 4u)

/* pixel formats (same numbers as lumora_push_screen_frame) */
#define LUMORA_RING_RGBA 0u
#define LUMORA_RING_BGRA 1u

/* broadcast state */
#define LUMORA_RING_STOPPED 0u
#define LUMORA_RING_LIVE 1u

typedef struct lumora_ring lumora_ring;

/* writer = 1: create/resize the file if needed (keeps sequence numbers monotonic across
 * restarts of the extension). writer = 0: map an existing ring (NULL if absent/invalid). */
lumora_ring *lumora_ring_open(const char *path, int writer);
void lumora_ring_close(lumora_ring *r);

/* Writer: reserve the next slot for a frame; returns where to write `stride * height`
 * bytes, or NULL if the frame is too large. Must be followed by lumora_ring_commit. */
uint8_t *lumora_ring_begin(lumora_ring *r, uint32_t width, uint32_t height, uint32_t stride, uint32_t format);
void lumora_ring_commit(lumora_ring *r, uint64_t ts_us);
/* Writer: give up on the frame started with lumora_ring_begin (e.g. conversion failed). */
void lumora_ring_abort(lumora_ring *r);
void lumora_ring_set_state(lumora_ring *r, uint32_t state, uint32_t display_w, uint32_t display_h, float scale);

/* Reader: copy the newest frame with sequence > *last_seq into dst. Returns the number of
 * bytes copied, 0 if there is nothing new (or the frame was overwritten mid-copy),
 * -1 if dst is too small. Updates *last_seq on success. */
int64_t lumora_ring_read(lumora_ring *r, uint64_t *last_seq, uint8_t *dst, size_t cap, uint32_t *width, uint32_t *height,
                         uint32_t *stride, uint32_t *format, uint64_t *ts_us);
uint32_t lumora_ring_state(lumora_ring *r, uint32_t *display_w, uint32_t *display_h, float *scale);

#ifdef __cplusplus
}
#endif
#endif
