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

typedef struct {
	uint32_t tid;
} ThreadCtx;

void *run_work(void *ptr) {
	ThreadCtx *ctx = (ThreadCtx *)ptr;

	char *worker_prefix = "worker";
	char name_buffer[sizeof(worker_prefix) + 3] = {};
	snprintf(name_buffer, sizeof(name_buffer), "%s-%u", worker_prefix, ctx->tid);

	init_thread(ctx->tid, SPALL_BUFFER_SIZE, MAX_CACHED_SYMBOLS, name_buffer);

	for (int i = 0; i < LOOP_ITERATIONS; i++) {
		foo();
	}

	exit_thread();
	return NULL;
}

int main() {
	init_profile("profile.spall");
	init_thread(0, SPALL_BUFFER_SIZE, MAX_CACHED_SYMBOLS, "main");

	pthread_t thread_1, thread_2;
	ThreadCtx ctx_1 = (ThreadCtx){.tid = 1};
	ThreadCtx ctx_2 = (ThreadCtx){.tid = 2};
	pthread_create(&thread_1, NULL, run_work, &ctx_1);
	pthread_create(&thread_2, NULL, run_work, &ctx_2);

	for (int i = 0; i < LOOP_ITERATIONS; i++) {
		foo();
	}

	wub();

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	exit_thread();
	exit_profile();
}
