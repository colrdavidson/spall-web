#include <stdlib.h>
#include <stdio.h>
#include <pthread.h>

#include "spall_native_auto.h"

void bar(void) {
}
void foo(void) {
	bar();
}
void wub() {
	printf("Foobar is terrible\n");
}

void *run_work(void *ptr) {
	spall_auto_thread_init((uint32_t)(uint64_t)pthread_self(), SPALL_DEFAULT_BUFFER_SIZE);

	for (int i = 0; i < 1000; i++) {
		foo();
	}

	spall_auto_quit();
	return NULL;
}

int main() {
	spall_auto_init((char *)"profile.spall");
	spall_auto_thread_init(0, SPALL_DEFAULT_BUFFER_SIZE);

	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);

	for (int i = 0; i < 1000; i++) {
		foo();
	}

	wub();

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	spall_auto_thread_quit();
	spall_auto_quit();
}

#define SPALL_AUTO_IMPLEMENTATION
#include "spall_native_auto.h"
