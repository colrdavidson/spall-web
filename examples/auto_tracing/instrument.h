#pragma once

#include <stdint.h>

void init_profile(char *filename);
void exit_profile(void);
void init_thread(uint32_t tid, size_t buffer_size, int64_t symbol_cache_size, char *thread_name);
void exit_thread(void);
