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

void *run_work(void *ptr) {
	init_thread((uint32_t)pthread_self(), 10 * 1024 * 1024, 1000);

	for (int i = 0; i < 1000; i++) {
		foo();
	}

	exit_thread();
	return NULL;
}

int main() {
	init_profile("profile.spall");
	init_thread(0, 10 * 1024 * 1024, 1000);

	pthread_t thread_1, thread_2;
	pthread_create(&thread_1, NULL, run_work, NULL);
	pthread_create(&thread_2, NULL, run_work, NULL);

	for (int i = 0; i < 1000; i++) {
		foo();
	}

	wub();

	pthread_join(thread_1, NULL);
	pthread_join(thread_2, NULL);

	exit_thread();
	exit_profile();
}
