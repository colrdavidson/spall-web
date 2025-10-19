#include <inttypes.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>

#include <linux/perf_event.h>
#include <asm/unistd.h>

#include "../../spall.h"

static SpallProfile spall_ctx;
static _Thread_local SpallBuffer spall_buffer;

void *run_work(void *ptr);
void foo(void);
void bar(void);
static double get_clock_multiplier(void);
static uint64_t get_clock(void);

int main() {
	spall_init_file("spall_sample.spall", get_clock_multiplier(), &spall_ctx);

	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	spall_quit(&spall_ctx);
}

void *run_work(void *ptr) {
	/*
		If you notice big variance in events, you can try bumping the buffer size so you do fewer flushes
		while your code runs, or you can shrink it if you need to save some memory
	*/
	#define BUFFER_SIZE (100 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);
	spall_buffer = (SpallBuffer){
		.pid = 0,
		.tid = (uint32_t)(uint64_t)pthread_self(),
		.length = BUFFER_SIZE,
		.data = buffer,
	};

	/*
		Here's another neat trick:
		We're touching the pages ahead of time here, so we get a smoother trace.
		By pre-faulting all the pages in our event buffer, we avoid waiting for pages to load
		while user code runs. This can make a noticable difference for data consistency, especially
		with bigger buffers
	*/
	memset(spall_buffer.data, 1, spall_buffer.length);

	spall_buffer_init(&spall_ctx, &spall_buffer);
	for (int i = 0; i < 1000000; i++) {
		foo();
	}

	// You can flush manually at any time, like during downtime between frames
	spall_buffer_flush(&spall_ctx, &spall_buffer);

	// Quitting also flushes the buffer, so you don't need to manually flush
	spall_buffer_quit(&spall_ctx, &spall_buffer);
	return NULL;
}

/*
	Defining these to make life a little easier. You can definitely write out begins and ends
	explicitly, but I expect most users to write tracing wrappers that fit their needs
*/
#define BEGIN_FUNC() do { \
	spall_buffer_begin(&spall_ctx, &spall_buffer, __FUNCTION__, sizeof(__FUNCTION__) - 1, get_clock()); \
} while(0)
#define END_FUNC() do { \
	spall_buffer_end(&spall_ctx, &spall_buffer, get_clock()); \
} while(0)

void bar(void) {
	BEGIN_FUNC();
	END_FUNC();
}

void foo(void) {
	BEGIN_FUNC();
	bar();
	END_FUNC();
}

/*
	This is supporting code to read the RDTSC multiplier from perf on Linux,
	so we can convert from RDTSC's clock to microseconds.

	Using the RDTSC directly like this reduces profiler overhead a lot,
	which can save you a ton of time and improve the quality of your trace.

	For my i7-8559U, it takes ~20 ns to call clock_gettime, or ~6 ns to use rdtsc directly, which adds up!
*/
static uint64_t mul_u64_u32_shr(uint64_t cyc, uint32_t mult, uint32_t shift) {
    __uint128_t x = cyc;
    x *= mult;
    x >>= shift;
    return x;
}

static long perf_event_open(struct perf_event_attr *hw_event, pid_t pid, int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

static double get_clock_multiplier(void) {
    struct perf_event_attr pe = {
        .type = PERF_TYPE_HARDWARE,
        .size = sizeof(struct perf_event_attr),
        .config = PERF_COUNT_HW_INSTRUCTIONS,
        .disabled = 1,
        .exclude_kernel = 1,
        .exclude_hv = 1
    };

    int fd = (int)perf_event_open(&pe, 0, -1, -1, 0);
    if (fd == -1) {
        perror("perf_event_open failed");
        return 1;
    }
    void *addr = mmap(NULL, 4*1024, PROT_READ, MAP_SHARED, fd, 0);
    if (!addr) {
        perror("mmap failed");
        return 1;
    }
    struct perf_event_mmap_page *pc = (struct perf_event_mmap_page *)addr;
    if (pc->cap_user_time != 1) {
        fprintf(stderr, "Perf system doesn't support user time\n");
        return 1;
    }
    double nanos = (double)mul_u64_u32_shr(1000000000000000ull, pc->time_mult, pc->time_shift);
    double multiplier = nanos / 1000000000000000.0;
    return multiplier;
}
static uint64_t get_clock(void) {
	return __rdtsc();
}
