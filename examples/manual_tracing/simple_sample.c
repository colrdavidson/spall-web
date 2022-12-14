#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define SPALL_IMPLEMENTATION
#include "../../spall.h"

#if _WIN32
#define WIN32_LEAN_AND_MEAN
#define VC_EXTRALEAN
#define NOMINMAX
#include <Windows.h>
// This is slow, if you can use RDTSC and set the multiplier in SpallInit, you'll have far better timing accuracy
double get_time_in_micros() {
	static double invfreq;
	if (!invfreq) {
		LARGE_INTEGER frequency;
		QueryPerformanceFrequency(&frequency);
		invfreq = 1000000.0 / frequency.QuadPart;
	}
	LARGE_INTEGER counter;
	QueryPerformanceCounter(&counter);
	return counter.QuadPart * invfreq;
}
#else
#include <unistd.h>
// This is slow, if you can use RDTSC and set the multiplier in SpallInit, you'll have far better timing accuracy
double get_time_in_micros() {
	struct timespec spec;
	clock_gettime(CLOCK_MONOTONIC, &spec);
	return (((double)spec.tv_sec) * 1000000) + (((double)spec.tv_nsec) / 1000);
}
#endif

static SpallProfile spall_ctx;
static SpallBuffer  spall_buffer;
void hello_world() {
	spall_trace_begin_tid_pid(&spall_ctx, &spall_buffer, __FUNCTION__, sizeof(__FUNCTION__) - 1, get_time_in_micros(), 0, 0);

	printf("Hello World\n");

	spall_trace_end_tid_pid(&spall_ctx, &spall_buffer, get_time_in_micros(), 0, 0);
}

int main() {
	spall_ctx = spall_init("simple_sample.spall", 1);

	#define BUFFER_SIZE (1 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);

	spall_buffer = (SpallBuffer){
		.length = BUFFER_SIZE,
		.data = buffer,
	};

	spall_buffer_init(&spall_ctx, &spall_buffer);
	for (int i = 0; i < 1000000; i++) {
		hello_world();
	}

	spall_buffer_quit(&spall_ctx, &spall_buffer);
	spall_quit(&spall_ctx);
}
