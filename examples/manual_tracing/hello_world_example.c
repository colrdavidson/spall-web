#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <time.h>

#include "../../spall.h"

/*
	Ready to trace your code?
	To get rolling, you need a few basic things:

	- A SpallProfile
		- this tracks your tracing state, and handles file creation and cleanup

	- One SpallBuffer per thread
		- this is a fixed size buffer that Spall writes events to and flushes to disk periodically

	- A timing function of your choice
		- bring your own timer for maximum portability to your weird embedded platform
*/
uint64_t get_time_in_nanos(void);
void hello_world(void);

static SpallProfile spall_ctx;
static SpallBuffer  spall_buffer;

int main() {
	/* 
		Start with spall_init_file
		init_file takes 2 things:
		- the name of your trace, ex: "hello_world.spall"
		- the multiplier to convert from your timer's timestamps to nanoseconds

		The timer functions in this example provide timestamps in nanoseconds so we use 1
		If you want to use something more accurate like RDTSC, you can probe your OS for the multiplier,
		or approximate it with sleep. We'll go into it more in the advanced thread example
	*/
	if (!spall_init_file("hello_world.spall", 1, &spall_ctx)) {
		printf("Failed to setup spall?\n");
		return 1;
	}

	/* 
		Next, we'll make a buffer to log events into.

		Spall is BYOB (bring your own buffer)
		You malloc it or make some stack space for it,
		and you clean it up at the end.
	*/
	int buffer_size = 1 * 1024 * 1024;
	unsigned char *buffer = malloc(buffer_size);
	spall_buffer = (SpallBuffer){
		.length = buffer_size,
		.data = buffer,
	};
	if (!spall_buffer_init(&spall_buffer)) {
		printf("Failed to init spall buffer?\n");
		return 1;
	}

	/*
		Ok, we're ready to trace, time to call our hello world function!
	*/
	for (int i = 0; i < 1000000; i++) {
		hello_world();
	}

	/*
		Remember to quit or flush your buffers before you exit!
		If you don't, you might not get the last few events waiting to be written
	*/
	spall_buffer_quit(&spall_ctx, &spall_buffer);

	// Freeing our buffer's memory now that spall_buffer_quit has flushed it for us.
	free(buffer);

	spall_quit(&spall_ctx);
}

void hello_world(void) {
	// Log the start of your function
	spall_buffer_begin(&spall_ctx, &spall_buffer, 
		__FUNCTION__,             // name of your function
		sizeof(__FUNCTION__) - 1, // name len minus the null terminator
		get_time_in_nanos()      // timestamp in nanoseconds -- start of your timing block
	);

	printf("Hello World\n");

	// Log the end of your function
	spall_buffer_end(&spall_ctx, &spall_buffer, 
		get_time_in_nanos() // timestamp in nanoseconds -- end of your timing block
	);
}

// Reference timer implementations
// These are relatively slow but portable, check out the advanced example for some faster approaches using RDTSC

#if _WIN32
#include <Windows.h>
uint64_t get_time_in_nanos(void) {
	static double invfreq;
	if (!invfreq) {
		LARGE_INTEGER frequency;
		QueryPerformanceFrequency(&frequency);
		invfreq = 1000000000.0 / frequency.QuadPart;
	}
	LARGE_INTEGER counter;
	QueryPerformanceCounter(&counter);
	uint64_t ts = (uint64_t)((double)counter.QuadPart * invfreq);
	return ts;
}
#else
#include <unistd.h>
uint64_t get_time_in_nanos(void) {
	struct timespec spec;
	clock_gettime(CLOCK_MONOTONIC, &spec);
	uint64_t ts = ((uint64_t)spec.tv_sec * 1000000000ull) + (uint64_t)spec.tv_nsec;
	return ts;
}
#endif
