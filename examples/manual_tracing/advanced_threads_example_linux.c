#include <asm/unistd.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>

#include "../../spall.h"

static SpallProfile spall_ctx;
static _Thread_local SpallBuffer spall_buffer;
static _Thread_local uint32_t tid;

void *run_work(void *ptr);
void foo(void);
void bar(void);
double get_rdtsc_multiplier(void);

int main() {
	spall_ctx = spall_init_file("spall_sample.spall", get_rdtsc_multiplier());

	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	/*
 		If you're using SPALL_JSON and you want to use non-Spall JSON tooling, don't forget to call spall_quit!
		spall_quit writes the closing braces to the file. Spall can handle JSON files without the trailing ]}\n,
 		but other tools can be fussy about it
 	*/
	spall_quit(&spall_ctx);
}

void *run_work(void *ptr) {
	tid = (uint32_t)pthread_self();

	/*
		Fun fact: You don't actually *need* a buffer, you can just pass NULL!
		Passing a buffer clumps flushing overhead, so individual functions are faster and less noisy

		If you notice big variance in events, you can try bumping the buffer size so you do fewer flushes
		while your code runs, or you can shrink it if you need to save some memory
	*/
	#define BUFFER_SIZE (100 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);
	spall_buffer = (SpallBuffer){
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
	spall_buffer_begin_ex(&spall_ctx, &spall_buffer, __FUNCTION__, sizeof(__FUNCTION__) - 1, __rdtsc(), tid, 0); \
} while(0)
#define END_FUNC() do { \
	spall_buffer_end_ex(&spall_ctx, &spall_buffer, __rdtsc(), tid, 0); \
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

static double get_rdtsc_multiplier(void) {
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
