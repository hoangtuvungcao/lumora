/* Stress test for lumora_ring (runs on Linux/macOS):
 *   cc -std=c11 -O2 -Wall -Wextra -Werror -pthread lumora_ring.c tests/ring_test.c -o ring_test && ./ring_test
 * A writer process commits frames as fast as it can; the reader must never accept a torn
 * frame (every byte of a frame carries the frame number), sequences must increase, and a
 * restarted writer must keep numbering monotonic so the reader keeps up. */
#define _POSIX_C_SOURCE 200809L
#include "../lumora_ring.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/wait.h>
#include <time.h>
#include <unistd.h>

#define FRAMES 3000
#define CHECK(c) do { if (!(c)) { fprintf(stderr, "FAIL %s:%d: %s\n", __FILE__, __LINE__, #c); exit(1); } } while (0)

static void write_frames(const char *path, uint32_t first, uint32_t count) {
    lumora_ring *w = lumora_ring_open(path, 1);
    CHECK(w);
    lumora_ring_set_state(w, LUMORA_RING_LIVE, 1170, 2532, 3.0f);
    for (uint32_t f = first; f < first + count; f++) {
        uint32_t width = 300 + (f % 7) * 20, height = 640, stride = width * 4 + 16;
        uint8_t *p = lumora_ring_begin(w, width, height, stride, LUMORA_RING_BGRA);
        CHECK(p);
        memset(p, (int)(f & 0xff), (size_t)stride * height);
        memcpy(p, &f, sizeof f);
        lumora_ring_commit(w, f);
    }
    CHECK(lumora_ring_begin(w, 2000, 2000, 8000, 0) == NULL); /* too large → refused */
    CHECK(lumora_ring_begin(w, 64, 64, 256, LUMORA_RING_BGRA) != NULL);
    lumora_ring_abort(w); /* an aborted frame is never delivered */
    lumora_ring_close(w);
}

int main(void) {
    char path[] = "/tmp/lumora-ring-test-XXXXXX";
    int fd = mkstemp(path);
    CHECK(fd >= 0);
    close(fd);
    unlink(path);
    CHECK(lumora_ring_open(path, 0) == NULL); /* reader cannot open a missing ring */
    write_frames(path, 0, 1);                 /* create */

    lumora_ring *r = lumora_ring_open(path, 0);
    CHECK(r);
    uint32_t dw, dh; float sc;
    CHECK(lumora_ring_state(r, &dw, &dh, &sc) == LUMORA_RING_LIVE && dw == 1170 && dh == 2532 && sc == 3.0f);
    size_t cap = LUMORA_RING_SLOT_BYTES;
    uint8_t *buf = malloc(cap);
    uint64_t last = 0;
    uint32_t w, h, stride, fmt; uint64_t ts;
    CHECK(lumora_ring_read(r, &last, buf, cap, &w, &h, &stride, &fmt, &ts) > 0 && ts == 0);
    CHECK(lumora_ring_read(r, &last, buf, cap, &w, &h, &stride, &fmt, &ts) == 0); /* nothing new */
    CHECK(lumora_ring_read(r, &last, buf, 16, &w, &h, &stride, &fmt, &ts) == 0);  /* nothing new beats cap check */

    for (int round = 0; round < 2; round++) { /* round 2 = a restarted extension */
        pid_t pid = fork();
        CHECK(pid >= 0);
        if (pid == 0) { write_frames(path, 1 + round * FRAMES, FRAMES); _exit(0); }
        long accepted = 0, torn_free = 1;
        uint64_t prev_ts = round == 0 ? 0 : (uint64_t)FRAMES;
        int status = 0, done = 0;
        while (!done) {
            done = waitpid(pid, &status, WNOHANG) == pid;
            for (int k = 0; k < 64; k++) {
                int64_t n = lumora_ring_read(r, &last, buf, cap, &w, &h, &stride, &fmt, &ts);
                CHECK(n >= 0);
                if (n == 0) continue;
                uint32_t f;
                memcpy(&f, buf, sizeof f);
                CHECK(f == ts);                                   /* header matches payload */
                CHECK(ts > prev_ts || (round == 0 && ts == prev_ts && accepted == 0));
                CHECK(w == 300 + (f % 7) * 20 && h == 640 && stride == w * 4 + 16 && fmt == LUMORA_RING_BGRA);
                for (size_t i = sizeof f; i < (size_t)n; i += 997) torn_free &= buf[i] == (uint8_t)(f & 0xff);
                CHECK(torn_free);
                prev_ts = ts;
                accepted++;
            }
        }
        CHECK(WIFEXITED(status) && WEXITSTATUS(status) == 0);
        /* the very last frame is always readable after the writer finished */
        int64_t n = lumora_ring_read(r, &last, buf, cap, &w, &h, &stride, &fmt, &ts);
        CHECK(n >= 0);
        if (n > 0) prev_ts = ts;
        CHECK(prev_ts == (uint64_t)(round + 1) * FRAMES);
        printf("round %d: %ld/%d frames accepted while racing the writer, 0 torn, newest = %llu\n", round + 1, accepted, FRAMES,
               (unsigned long long)prev_ts);
    }
    lumora_ring_close(r);
    free(buf);
    unlink(path);
    printf("lumora_ring: OK\n");
    return 0;
}
