#define _GNU_SOURCE
#include <stdlib.h>
#include <stdint.h>
#include <dlfcn.h>
#include <time.h>
#include <pthread.h>
#include <unistd.h>

#include "../../spall.h"

#include "instrument.h"

typedef struct {
	char *str;
	int len;
} Name;

typedef struct {
	void *addr;
	Name name;
} SymEntry;

typedef struct {
	SymEntry *arr;
	uint64_t len;
	uint64_t cap;
} SymArr;

typedef struct {
	int64_t *arr;
	uint64_t len;
} HashArr;

typedef struct {
	SymArr  entries;	
	HashArr hashes;	
} AddrHash;

static SpallProfile spall_ctx;
static _Thread_local SpallBuffer spall_buffer;
static _Thread_local AddrHash addr_map;
static _Thread_local uint32_t tid;
static _Thread_local bool spall_thread_running = false;

// we're not checking overflow here...Don't do stupid things with input sizes
SPALL_FN uint64_t next_pow2(uint64_t x) {
	return 1 << (64 - __builtin_clzll(x - 1));
}

// This is not thread-safe... Use one per thread!
SPALL_FN AddrHash ah_init(int64_t size) {
	AddrHash ah;

	ah.entries.cap = size;
	ah.entries.arr = calloc(sizeof(SymEntry), size);
	ah.entries.len = 0;

	ah.hashes.len = next_pow2(size);
	ah.hashes.arr = malloc(sizeof(int64_t) * ah.hashes.len);

	for (int64_t i = 0; i < ah.hashes.len; i++) {
		ah.hashes.arr[i] = -1;
	}

	return ah;
}

SPALL_FN void ah_free(AddrHash *ah) {
	free(ah->entries.arr);
	free(ah->hashes.arr);
	memset(ah, 0, sizeof(AddrHash));
}

// fibhash addresses
SPALL_FN int ah_hash(void *addr) {
	return (int)(((uint32_t)(uintptr_t)addr) * 2654435769);
}

// Replace me with your platform's addr->name resolver if needed
SPALL_FN bool get_addr_name(void *addr, Name *name_ret) {
	Dl_info info;
	if (dladdr(addr, &info) != 0 && info.dli_sname != NULL) {
		char *str = (char *)info.dli_sname;
		*name_ret = (Name){.str = str, .len = strlen(str)};
		return true;
	}

	return false;
}

SPALL_FN bool ah_get(AddrHash *ah, void *addr, Name *name_ret) {
	int addr_hash = ah_hash(addr);
	uint64_t hv = ((uint64_t)addr_hash) & (ah->hashes.len - 1);
	for (uint64_t i = 0; i < ah->hashes.len; i++) {
		uint64_t idx = (hv + i) & (ah->hashes.len - 1);

		int64_t e_idx = ah->hashes.arr[idx];
		if (e_idx == -1) {

			Name name;
			if (!get_addr_name(addr, &name)) {
				// Failed to get a name for the address!
				return false;
			}

			SymEntry entry = {.addr = addr, .name = name};
			ah->hashes.arr[idx] = ah->entries.len;
			ah->entries.arr[ah->entries.len] = entry;
			ah->entries.len += 1;

			*name_ret = name;
			return true;
		}

		if ((uint64_t)ah->entries.arr[e_idx].addr == (uint64_t)addr) {
			*name_ret = ah->entries.arr[e_idx].name;
			return true;
		}
	}

	// The symbol map is full, make the symbol map bigger!
	return false;
}

#ifdef __linux__
#include <linux/perf_event.h>
#include <asm/unistd.h>
#include <sys/mman.h>

SPALL_FN uint64_t mul_u64_u32_shr(uint64_t cyc, uint32_t mult, uint32_t shift) {
    __uint128_t x = cyc;
    x *= mult;
    x >>= shift;
    return x;
}

SPALL_FN long perf_event_open(struct perf_event_attr *hw_event, pid_t pid,
           int cpu, int group_fd, unsigned long flags) {
    return syscall(__NR_perf_event_open, hw_event, pid, cpu, group_fd, flags);
}

SPALL_FN double get_rdtsc_multiplier() {
	struct perf_event_attr pe = {
        .type = PERF_TYPE_HARDWARE,
        .size = sizeof(struct perf_event_attr),
        .config = PERF_COUNT_HW_INSTRUCTIONS,
        .disabled = 1,
        .exclude_kernel = 1,
        .exclude_hv = 1
    };

    int fd = perf_event_open(&pe, 0, -1, -1, 0);
    if (fd == -1) {
        perror("perf_event_open failed");
        return 1;
    }
    void *addr = mmap(NULL, 4*1024, PROT_READ, MAP_SHARED, fd, 0);
    if (!addr) {
        perror("mmap failed");
        return 1;
    }
    struct perf_event_mmap_page *pc = addr;
    if (pc->cap_user_time != 1) {
        fprintf(stderr, "Perf system doesn't support user time\n");
        return 1;
    }
	double nanos = (double)mul_u64_u32_shr(1000000, pc->time_mult, pc->time_shift);
	return nanos / 1000000000;
}
#elif __APPLE__
#include <sys/types.h>
#include <sys/sysctl.h>

SPALL_FN double get_rdtsc_multiplier() {
	uint64_t freq;
	size_t size = sizeof(freq);

	sysctlbyname("machdep.tsc.frequency", &freq, &size, NULL, 0);

	return 1000000.0 / (double)freq;
}
#endif

void init_thread(uint32_t _tid, size_t buffer_size, int64_t symbol_cache_size) {
	uint8_t *buffer = (uint8_t *)malloc(buffer_size);
	spall_buffer = (SpallBuffer){ .data = buffer, .length = buffer_size };

	// removing initial page-fault bubbles to make the data a little more accurate, at the cost of thread spin-up time
	memset(buffer, 1, buffer_size);

	spall_buffer_init(&spall_ctx, &spall_buffer);

	tid = _tid;
	addr_map = ah_init(symbol_cache_size);
	spall_thread_running = true;
}

void exit_thread() {
	spall_thread_running = false;
	ah_free(&addr_map);
	spall_buffer_quit(&spall_ctx, &spall_buffer);
	free(spall_buffer.data);
}

void init_profile(char *filename) {
	spall_ctx = spall_init_file(filename, get_rdtsc_multiplier());
}

void exit_profile(void) {
	spall_quit(&spall_ctx);
}

char not_found[] = "(unknown name)";
void __cyg_profile_func_enter(void *fn, void *caller) {
	if (!spall_thread_running) {
		return;
	}

	Name name;
	if (!ah_get(&addr_map, fn, &name)) {
		name = (Name){.str = not_found, .len = sizeof(not_found) - 1};
	}

	spall_buffer_begin_ex(&spall_ctx, &spall_buffer, name.str, name.len, __rdtsc(), tid, 0);
}

void __cyg_profile_func_exit(void *fn, void *caller) {
	if (!spall_thread_running) {
		return;
	}

	spall_buffer_end_ex(&spall_ctx, &spall_buffer, __rdtsc(), tid, 0);
}
