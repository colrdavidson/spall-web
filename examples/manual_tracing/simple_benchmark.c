#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#include "../../spall.h"

#if _WIN32

#define WIN32_LEAN_AND_MEAN
#define VC_EXTRALEAN
#define NOMINMAX
#include <Windows.h>
static inline unsigned long long get_rdtsc_freq(void)
{
    unsigned long long tsc_freq  = 3000000000;
    bool               fast_path = false;
    HMODULE ntdll                = LoadLibrary("ntdll.dll");
    if (ntdll)
    {
        int (*NtQuerySystemInformation)(int, void *, unsigned int, unsigned int *) =
            (int (*)(int, void *, unsigned int, unsigned int *))GetProcAddress(ntdll, "NtQuerySystemInformation");
        if (NtQuerySystemInformation)
        {
            volatile unsigned long long *HSUV   = 0;
            unsigned int                 size   = 0;
            int                          result = NtQuerySystemInformation(0xc5, (void **)&HSUV, sizeof(HSUV), &size);
            if (size == sizeof(HSUV) && result >= 0)
            {
                tsc_freq  = (10000000ull << 32) / (HSUV[1] >> 32);
                fast_path = true;
            }
        }
        FreeLibrary(ntdll);
    }

    if (! fast_path)
    {
        LARGE_INTEGER frequency; QueryPerformanceFrequency(&frequency);
        LARGE_INTEGER qpc_begin; QueryPerformanceCounter(&qpc_begin);
        unsigned long long tsc_begin = __rdtsc();
        Sleep(2);
        LARGE_INTEGER qpc_end; QueryPerformanceCounter(&qpc_end);
        unsigned long long tsc_end   = __rdtsc();
        tsc_freq                     = (tsc_end - tsc_begin) * frequency.QuadPart / (qpc_end.QuadPart - qpc_begin.QuadPart);
    }

    return tsc_freq;
}

#else

#include <stdbool.h>
#include <sys/mman.h>
#include <linux/perf_event.h>
#include <time.h>
#include <unistd.h>
#include <x86intrin.h>

static inline unsigned long get_rdtsc_freq(void) {
    unsigned long          tsc_freq  = 3000000000;
    bool                   fast_path = false;
    struct perf_event_attr pe        = {
        .type           = PERF_TYPE_HARDWARE,
        .size           = sizeof(struct perf_event_attr),
        .config         = PERF_COUNT_HW_INSTRUCTIONS,
        .disabled       = 1,
        .exclude_kernel = 1,
        .exclude_hv     = 1
    };

    int fd = syscall(298 /* __NR_perf_event_open on x86_64 */, &pe, 0, -1, -1, 0);
    if (fd != -1) {
        void *addr = mmap(NULL, 4096, PROT_READ, MAP_SHARED, fd, 0);
        if (addr) {
            struct perf_event_mmap_page *pc = addr;
            if (pc->cap_user_time == 1) {
                tsc_freq  = ((__uint128_t)1000000000 << pc->time_shift) / pc->time_mult;
                // If you don't like 128 bit arithmetic, do this:
                // tsc_freq  = (1000000000ull << (pc->time_shift / 2)) / (pc->time_mult >> (pc->time_shift - pc->time_shift / 2));
                fast_path = true;
            }
            munmap(addr, 4096);
        }
        close(fd);
    }

    if (!fast_path) {
        // CLOCK_MONOTONIC_RAW is Linux-specific but better;
        // CLOCK_MONOTONIC     is POSIX-portable but slower.
        struct timespec clock = {0};
        clock_gettime(CLOCK_MONOTONIC_RAW, &clock);
        signed long   time_begin = clock.tv_sec * 1e9 + clock.tv_nsec;
        unsigned long tsc_begin  = __rdtsc();
        usleep(2000);
        clock_gettime(CLOCK_MONOTONIC_RAW, &clock);
        signed long   time_end   = clock.tv_sec * 1e9 + clock.tv_nsec;
        unsigned long tsc_end    = __rdtsc();
        tsc_freq                 = (tsc_end - tsc_begin) * 1000000000 / (time_end - time_begin);
    }

    return tsc_freq;
}
#endif

static SpallProfile spall_ctx;
static SpallBuffer  spall_buffer;

int main() {
	spall_ctx = spall_init_file("simple_benchmark.spall", 1000000.0 / get_rdtsc_freq());

	#define BUFFER_SIZE (64 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);
	memset(buffer, 1, BUFFER_SIZE);

	spall_buffer = (SpallBuffer){
		.length = BUFFER_SIZE,
		.data = buffer,
	};

	spall_buffer_init(&spall_ctx, &spall_buffer);
	for (int i = 0; i < 1000000; i++) {
		spall_buffer_begin(&spall_ctx, &spall_buffer, __FUNCTION__, sizeof(__FUNCTION__) - 1, __rdtsc());
		spall_buffer_end(&spall_ctx, &spall_buffer, __rdtsc());
	}

	spall_buffer_quit(&spall_ctx, &spall_buffer);
	spall_quit(&spall_ctx);
}
