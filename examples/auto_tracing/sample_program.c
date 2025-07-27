#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

#include "instrument.h"

void bar(void) {
}
void foo(void) {
	bar();
}
void wub() {
	printf("Foobar is terrible\n");
}

#define MAX_CACHED_SYMBOLS 1000
#define SPALL_BUFFER_SIZE 10 * 1024 * 1024
#define LOOP_ITERATIONS 5000000

void *run_work(void *ptr) {
	init_thread((uint32_t)(uint64_t)pthread_self(), SPALL_BUFFER_SIZE, MAX_CACHED_SYMBOLS);

	for (int i = 0; i < LOOP_ITERATIONS; i++) {
		foo();
	}

	exit_thread();
	return NULL;
}

int main() {
	init_profile("profile.spall");
	init_thread(0, SPALL_BUFFER_SIZE, MAX_CACHED_SYMBOLS);

	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);

	for (int i = 0; i < LOOP_ITERATIONS; i++) {
		foo();
	}

	wub();

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	exit_thread();
	exit_profile();
}
