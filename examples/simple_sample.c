#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define SPALL_IMPLEMENTATION
#include "../spall.h"

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

int main() {
	SpallProfile ctx = SpallInit("simple_sample.spall", 1);

	#define BUFFER_SIZE (100 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);

	SpallBuffer buf = {0};
	buf.length = BUFFER_SIZE;
	buf.data = buffer;

	char ev_str[] = "Hello World";

	SpallBufferInit(&ctx, &buf);
	for (int i = 0; i < 1000000; i++) {
		SpallTraceBeginLenTidPid(&ctx, &buf, ev_str, sizeof(ev_str) - 1, 0, 0, get_time_in_micros());
		SpallTraceEndTidPid(&ctx, &buf, 0, 0, get_time_in_micros());
	}

	SpallBufferQuit(&ctx, &buf);
	SpallQuit(&ctx);
}
