#include <asm/unistd.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>

#define SPALL_IMPLEMENTATION
#include "../spall.h"

static uint64_t mul_u64_u32_shr(uint64_t cyc, uint32_t mult, uint32_t shift) {
    __uint128_t x = cyc;
    x *= mult;
    x >>= shift;
    return x;
}

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
           int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

static double get_rdtsc_ms() {
	struct perf_event_attr pe = {
        .type = PERF_TYPE_HARDWARE,
        .size = sizeof(struct perf_event_attr),
        .config = PERF_COUNT_HW_INSTRUCTIONS,
        .disabled = 1,
        .exclude_kernel = 1,
        .exclude_hv = 1
    };

    int fd = perf_event_open(&pe, 0, -1, -1, 0);
    if (fd == -1) {
        perror("perf_event_open failed");
        return 1;
    }
    void *addr = mmap(NULL, 4*1024, PROT_READ, MAP_SHARED, fd, 0);
    if (!addr) {
        perror("mmap failed");
        return 1;
    }
    struct perf_event_mmap_page *pc = addr;
    if (pc->cap_user_time != 1) {
        fprintf(stderr, "Perf system doesn't support user time\n");
        return 1;
    }
	double nanos = (double)mul_u64_u32_shr(1000000, pc->time_mult, pc->time_shift);
	return nanos / 1000000000;
}

int main() {
	SpallProfile ctx = SpallInit("spall_sample.spall", get_rdtsc_ms());

	#define BUFFER_SIZE (100 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);

	SpallBuffer buf = {};
	buf.length = BUFFER_SIZE;
	buf.data = buffer;

	// touch the pages ahead of time, so we get fewer fault-bubbles
	memset(buf.data, 1, buf.length);

	char ev_str[] = "Hello World";

	SpallBufferInit(&ctx, &buf);
	for (int i = 0; i < 1000000; i++) {
		SpallTraceBeginLenTidPid(&ctx, &buf, ev_str, sizeof(ev_str), 0, 0);
		SpallTraceEndTidPid(&ctx, &buf, 0, 0);
	}

	SpallBufferQuit(&ctx, &buf);
	SpallQuit(&ctx);
}
