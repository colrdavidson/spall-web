//usr/bin/clang spall_sample.c && "./a.out" ; exit

#define SPALL_IMPLEMENTATION
#include "spall.h"

int main() {
	SpallProfile ctx = SpallInit("spall_sample.spall", 1);
	SpallTraceBegin(&ctx, NULL, __rdtsc(), "Hello, World!");
	SpallTraceEnd(&ctx, NULL, __rdtsc());
	SpallQuit(&ctx);
}
