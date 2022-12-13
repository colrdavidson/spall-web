#include <asm/unistd.h>
#include <inttypes.h>
#include <linux/perf_event.h>
#include <stdio.h>
#include <sys/mman.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <pthread.h>

#define SPALL_IMPLEMENTATION
#include "../../spall.h"

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

/*
	This is some fancy syscall magic to ask the Linux kernel for the RTDSC oscillator multiplier settings
	so we can accurately convert from it's 3 GHZ "tick" monotonic clock to microseconds on the frontend.
	I highly encourage you get the correct multiplier settings for your platform, it can shrink event
	overhead *considerably*. For my i7-8559U, it's the difference between ~20 ns and ~6 ns, which can be
	huge.
*/
static double get_rdtsc_multiplier() {
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

static SpallProfile spall_ctx;
static _Thread_local SpallBuffer spall_buffer;
static _Thread_local uint32_t tid;

#define BEGIN_FUNC() do { SpallTraceBeginLenTidPid(&spall_ctx, &spall_buffer, __FUNCTION__, sizeof(__FUNCTION__) - 1, tid, 0, __rdtsc()); } while(0)
#define END_FUNC() do { SpallTraceEndTidPid(&spall_ctx, &spall_buffer, tid, 0, __rdtsc()); } while(0)

void bar() {
	BEGIN_FUNC();
	END_FUNC();
}

void foo() {
	BEGIN_FUNC();

	bar();

	END_FUNC();
}

void *run_work(void *ptr) {
	tid = (uint32_t)pthread_self();

	/*
		This is a user-tweakable. You don't *need* a buffer, (you can just pass NULL),
		but it helps clump disk-write overhead so most of your data stays clean. 
		If you notice big variance in events, you can try bumping the buffer size so you
		do fewer writes over the course of your program, or shrink it if you need to save memory
	*/
	#define BUFFER_SIZE (100 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);

	spall_buffer = (SpallBuffer){
		.length = BUFFER_SIZE,
		.data = buffer,
	};

	/*
		We're touching the pages ahead of time, so we get fewer fault-bubbles.
		If you don't do this, the first time you fill the buffer,
		your timings may contain page-fault variance as the OS
		allocates the pages for you behind the scenes
	*/
	memset(spall_buffer.data, 1, spall_buffer.length);

	/*
 		fwrite handles the file-locking for us, and we write in atomic buffer-wide chunks,
		so you shouldn't need to do anything special in your threaded event emitting code.
 	*/
	SpallBufferInit(&spall_ctx, &spall_buffer);
	for (int i = 0; i < 1000000; i++) {
		foo();
	}

	SpallBufferQuit(&spall_ctx, &spall_buffer);
	return NULL;
}

int main() {
	spall_ctx = SpallInit("spall_sample.spall", get_rdtsc_multiplier());

	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	/*
 		If you're using SPALL_JSON and you want to use non-Spall JSON tooling, don't forget to quit!
		Quit writes the closing braces to the file. Spall can handle JSON files without the trailing ]}\n,
 		but other tools can definitely be fussy about it
 	*/
	SpallQuit(&spall_ctx);
}
