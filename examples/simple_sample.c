#include <stdio.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#define SPALL_IMPLEMENTATION
#include "../spall.h"

// This is slow, if you can use RDTSC and set the multiplier in SpallInit, you'll have far better timing accuracy
double get_time_in_millis() {
	struct timespec spec;
	clock_gettime(CLOCK_MONOTONIC, &spec);
	return (((double)spec.tv_sec) * 1000000) + (((double)spec.tv_nsec) / 1000);
}

int main() {
	SpallProfile ctx = SpallInit("simple_sample.spall", 1);

	#define BUFFER_SIZE (100 * 1024 * 1024)
	unsigned char *buffer = malloc(BUFFER_SIZE);

	SpallBuffer buf = {};
	buf.length = BUFFER_SIZE;
	buf.data = buffer;

	char ev_str[] = "Hello World";

	SpallBufferInit(&ctx, &buf);
	for (int i = 0; i < 1000000; i++) {
		SpallTraceBeginLenTidPid(&ctx, &buf, ev_str, sizeof(ev_str) - 1, 0, 0, get_time_in_millis());
		SpallTraceEndTidPid(&ctx, &buf, 0, 0, get_time_in_millis());
	}

	SpallBufferQuit(&ctx, &buf);
	SpallQuit(&ctx);
}
