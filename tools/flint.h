// SPDX-FileCopyrightText: © 2022 Phillip Trudeau-Tavara <pmttavara@protonmail.com>
// SPDX-License-Identifier: 0BSD


/* TODO

Core API:

  - Completely contextless; you pass in params to begin()/end(), get a packed begin/end struct
      - Simple, handmade, user has full control and full responsibility

Optional Helper APIs:

  - Buffered-writing API
      - Caller allocates and stores a buffer for multiple events
      - begin()/end() writes chunks to the buffer
      - Function invokes a callback when the buffer is full and needs flushing
          - Can a callback be avoided? The function indicates when the buffer must be flushed?

  - Compression API: would require a mutexed lockable context (yuck...)
      - Either using a ZIP library, a name cache + TIDPID cache, or both (but ZIP is likely more than enough!!!)
      - begin()/end() writes compressed chunks to a caller-determined destination
          - The destination can be the buffered-writing API or a custom user destination
      - Ultimately need to take a lock with some granularity... can that be the caller's responsibility?

  - fopen()/fwrite() API: requires a context (no mutex needed, since fwrite() takes a lock)
      - begin()/end() writes chunks to a FILE*
          - before writing them to disk, the chunks can optionally be sent through the compression API
              - is this opt-in or opt-out?
          - the write to disk can optionally use the buffered writing API


Example Threaded Implementation:
    enum { RING_BUFFER_SIZE = 65536 };
    struct Event {
        double when;
        const char *name;
    };
    struct RegisteredThread {
        uint32_t pid;
        uint32_t tid;
        _Atomic uint64_t read_head;
        _Atomic uint64_t write_head;
#ifdef DYNAMIC_STRINGS
        void *allocator_userdata;
#endif
        Event events[RING_BUFFER_SIZE];
    };
    struct ProfileContext {
        cnd_t recording;
        bool never_drop_events;
        Mutex mutex; {
            RegisteredThread *registered_threads;
            SpallContext ctx;
        }
    };

    ProfileContext profile_init(, bool start_recording) {
        
    }

    void output_profile(ProfileContext *profile) {
        mutex_lock(&profile->mutex); {
            for (auto &thread : registered_threads) {
                if (thread.read_head <= thread.write_head - (RING_BUFFER_SIZE - 1)) {
                    printf(!"Ring tear. Increase the ring buffer size! :(");
                    SpallTraceBeginTidPid(&profile->ctx, "Ring tear. Increase the ring buffer size! :(", event.when, thread.tid, thread.pid);
                    thread.read_head = 0xffffffffffffffffull;
                    continue; // TODO: depth recovery
                }
                while (thread.read_head < thread.write_head) {
                    Event event = thread.events[thread.read_head & (RING_BUFFER_SIZE - 1)];
                    if (!event.is_end) {
                        SpallTraceBeginTidPid(&profile->ctx, event.name, event.when, thread.tid, thread.pid);
                    } else {
                        SpallTraceEndTidPid(&profile->ctx, event.when, thread.tid, thread.pid);
                    }
                    ++thread.read_head; // atomic
                }
            }
        }
        mutex_unlock(&profile->mutex);
        SpallFlush();
    }

    int output_thread(void *userdata) {
        ProfileContext *profile = (ProfileContext *)userdata;
        while (true) {
            cond_wait(profile->recording);
            output_profile();
            Sleep(1);
        }
    }

    EventID trace_begin(ProfileContext *profile, RegisteredThread *thread, const char *name) {
#ifdef DYNAMIC_STRINGS
        SPALL_FREE(thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)].name, thread->allocator_userdata);
        name = SPALL_STRDUP(name, thread->allocator_userdata);
#endif
        thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)] = { false, thread->thread_depth++, name, __rdtsc() };
        ++thread->write_head; // atomic
    }
    void trace_end(ProfileContext *profile, RegisteredThread *thread, EventID id) {
        thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)] = { true, id, thread->events[thread->write_head & (RING_BUFFER_SIZE - 1)].name, __rdtsc() };
        ++thread->write_head; // atomic
    }

    RegisteredThread *thread_init(ProfileContext *profile, u32 pid, u32 tid, u8 ring_buffer_size_power) {
        
    }
    void thread_quit(RegisteredThread *) {
        
    }
*/




#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>
#ifndef __cplusplus
#include <threads.h>
#endif

#pragma pack(push, 1)
typedef struct FlintHeader {
    uint64_t magic_header; // = 0x0BADF00D
    uint64_t version; // = 0
    double timestamp_unit;
    uint8_t name_cache_power; // must be between 0 and 16 inclusive, defaults to 10
} FlintHeader;

typedef struct FlintTime { double floating; } FlintTime;
typedef struct FlintString {
    uint8_t length;
    char bytes[1];
} FlintString;

typedef enum FlintEventType {
    FlintType_Begin,
    FlintType_End,
    FlintType_BeginCacheHit,
} FlintEventType;

typedef struct FlintBeginEvent {
    uint8_t type; // = FlintType_Begin
    uint32_t pid;
    uint32_t tid;
    FlintTime when;
    FlintString name;
} FlintBeginEvent;

typedef struct FlintBeginCacheHitEvent {
    uint8_t type; // = FlintType_BeginCacheHit
    FlintTime when;
    uint16_t name_slot;
} FlintBeginCacheHitEvent;

typedef struct FlintEndEvent {
    uint8_t type; // = FlintType_End
    uint32_t pid;
    uint32_t tid;
    FlintTime when;
} FlintEndEvent;

typedef struct FlintBeginEventMax {
    FlintBeginEvent event;
    char name_bytes[254];
} FlintBeginEventMax;

#pragma pack(pop)

typedef struct FlintCacheEntry {
    uint32_t hash;
    uint32_t pid;
    uint32_t tid;
    uint8_t name_len;
    char name[255];
} FlintCacheEntry;

enum { Flint_Cache_Power = 10 };

typedef struct FlintContext {
    FILE *file;
    double timestamp_unit;
    bool is_json;
    FlintCacheEntry *cache;
} FlintContext;

typedef struct FlintWriteBuffer {
    const uint32_t length;
    uint32_t head;
    void *data;
} FlintWriteBuffer;
inline bool Flint__BufferFlush(FlintWriteBuffer *wb, FILE *f) {
    if (!wb->head) return true;
    if (fwrite(wb->data, wb->head, 1, f) != 1) return false;
    wb->head = 0;
    return true;
}
inline bool Flint__BufferWrite(FlintWriteBuffer *wb, FILE *f, void *p, size_t n) {
    assert(wb->head <= wb->length);
    if (wb->head + n > wb->length && !Flint__BufferFlush(wb, f)) return false;
    if (n > wb->length) return fwrite(p, n, 1, f);
    memcpy((char *)wb->data + wb->head, p, n);
    wb->head += n;
    return true;
}

char FlintSingleThreadedWriteBuffer_Data[1 << 16];
static FlintWriteBuffer FlintSingleThreadedWriteBuffer = {1 << 16, 0, FlintSingleThreadedWriteBuffer_Data};

inline bool FlintFlush(FlintContext *ctx, FlintWriteBuffer *wb) {
    bool result = true;
    FlintWriteBuffer wb_ = {0}; if (!wb) wb = &wb_;
    if (ctx && ctx->file) {
        if (!Flint__BufferFlush(wb, ctx->file)) result = false;
        if (!fflush(ctx->file)) result = false;
    } else {
        wb->head = 0;
        result &= !ctx; // not a failure if there is no context
    }
    return result;
}

inline void FlintQuit(FlintContext *ctx) {
    if (!ctx) return;
    if (ctx->file) {
        if (ctx->is_json) {
            fseek(ctx->file, -2, SEEK_CUR); // seek back to overwrite trailing comma
            fprintf(ctx->file, "\n]}\n");
        }
        fclose(ctx->file);
    }
    if (ctx->cache) {
        free(ctx->cache);
    }
    memset(ctx, 0, sizeof(*ctx));
}

inline FlintContext FlintInit_Impl(const char *filename, double timestamp_unit, bool is_json) {
    FlintContext ctx;
    memset(&ctx, 0, sizeof(ctx));
    if (!filename) return ctx;
    ctx.file = fopen(filename, "wb"); // TODO: handle utf8 on windows
    ctx.timestamp_unit = timestamp_unit;
    ctx.is_json = is_json;
    if (!ctx.file) {
        FlintQuit(&ctx);
        return ctx;
    }
    if (ctx.is_json) {
        if (fprintf(ctx.file, "{\"traceEvents\":[\n") <= 0) {
            FlintQuit(&ctx);
            return ctx;
        }
        if (fflush(ctx.file)) {
            FlintQuit(&ctx);
            return ctx;
        }
    } else {
        ctx.cache = (FlintCacheEntry *)calloc(1 << Flint_Cache_Power, sizeof(FlintCacheEntry));
        if (!ctx.cache) {
            FlintQuit(&ctx);
            return ctx;
        }
        FlintHeader header;
        header.magic_header = 0x0BADF00D;
        header.version = 0;
        header.timestamp_unit = timestamp_unit;
        header.name_cache_power = Flint_Cache_Power;
        if (fwrite(&header, sizeof(header), 1, ctx.file) != 1) {
            FlintQuit(&ctx);
            return ctx;
        }
    }
    return ctx;
}

inline FlintContext FlintInitJson(const char *filename, double timestamp_unit) { return FlintInit_Impl(filename, timestamp_unit,  true); }
inline FlintContext FlintInit    (const char *filename, double timestamp_unit) { return FlintInit_Impl(filename, timestamp_unit, false); }

static inline uint32_t murmur32(const char *key, uint32_t len, uint32_t seed) {
    uint32_t c1 = 0xcc9e2d51;
    uint32_t c2 = 0x1b873593;
    uint32_t r1 = 15;
    uint32_t r2 = 13;
    uint32_t m = 5;
    uint32_t n = 0xe6546b64;
    uint32_t h = 0;
    uint32_t k = 0;
    uint8_t *d = (uint8_t *) key; // 32 bit extract from `key'
    const uint32_t *chunks = NULL;
    const uint8_t *tail = NULL; // tail - last 8 bytes
    int i = 0;
    int l = len / 4; // chunk length

    h = seed;

    chunks = (const uint32_t *) (d + l * 4); // body
    tail = (const uint8_t *) (d + l * 4); // last 8 byte chunk of `key'

    // for each 4 byte chunk of `key'
    for (i = -l; i != 0; ++i) {
        // next 4 byte chunk of `key'
        k = chunks[i];

        // encode next 4 byte chunk of `key'
        k *= c1;
        k = (k << r1) | (k >> (32 - r1));
        k *= c2;

        // append to hash
        h ^= k;
        h = (h << r2) | (h >> (32 - r2));
        h = h * m + n;
    }

    k = 0;

    // remainder
    switch (len & 3) { // `len % 4'
        case 3: k ^= (tail[2] << 16);
        case 2: k ^= (tail[1] << 8);

        case 1:
            k ^= tail[0];
            k *= c1;
            k = (k << r1) | (k >> (32 - r1));
            k *= c2;
            h ^= k;
    }

    h ^= len;

    h ^= (h >> 16);
    h *= 0x85ebca6b;
    h ^= (h >> 13);
    h *= 0xc2b2ae35;
    h ^= (h >> 16);

    return h;
}

static inline uint32_t hash_entry(const char *name, uint8_t name_len, uint32_t tid, uint32_t pid) {
    uint32_t result = murmur32(name, name_len, 2166136261);
    result = murmur32((char *)&pid, 4, result);
    result = murmur32((char *)&tid, 4, result);
    return result;
}

static bool use_cache = false; // @Hack

int begin_payload_length = 0;

// Caller has to take a lock around this function!
inline bool FlintTraceBeginLenTidPid(FlintContext *ctx, FlintWriteBuffer *wb, double when, const char *name, signed long name_len, uint32_t tid, uint32_t pid) {
    FlintWriteBuffer wb_ = {0}; if (!wb) wb = &wb_;
    if (!ctx) return false;
    if (!name) return false;
    if (!ctx->file) return false;
    if (!ctx->cache) return false;
    if (feof(ctx->file)) return false;
    if (ferror(ctx->file)) return false;
    // if (ctx->times_are_u64) return false;
    if (name_len <= 0) return false;
    if (name_len > 255) name_len = 255; // will be interpreted as truncated in the app (?)

    if (ctx->is_json) {
        if (fprintf(ctx->file,
                    "{\"name\":\"%.*s\",\"ph\":\"B\",\"pid\":%u,\"tid\":%u,\"ts\":%f},\n",
                    (int)name_len, name,
                    pid,
                    tid,
                    when * ctx->timestamp_unit)
            <= 0) return false;
    } else {
        if (use_cache) {
            uint32_t hash = hash_entry(name, name_len, tid, pid);
            int slot = hash & ((1 << Flint_Cache_Power) - 1);
            bool hit = false;
            FlintCacheEntry nce = ctx->cache[slot];
            if (nce.hash == hash && nce.tid == tid && nce.pid == pid && nce.name_len == name_len && !memcmp(nce.name, name, name_len)) {
                hit = true;
            }
            if (hit) {
                // Write cache hit position
                FlintBeginCacheHitEvent ev;
                ev.type = FlintType_BeginCacheHit;
                ev.when.floating = when;
                ev.name_slot = slot;
                if (!Flint__BufferWrite(wb, ctx->file, &ev, sizeof(ev))) return false;
                begin_payload_length += sizeof(ev);
            } else {
                // Write new literal
                FlintBeginEventMax ev;
                ev.event.type = FlintType_Begin;
                ev.event.pid = pid;
                ev.event.tid = tid;
                ev.event.when.floating = when;
                ev.event.name.length = (uint8_t)name_len;
                memcpy(ev.event.name.bytes, name, name_len);
                if (!Flint__BufferWrite(wb, ctx->file, &ev, sizeof(FlintBeginEvent) + name_len - 1)) return false;
                begin_payload_length += sizeof(FlintBeginEvent) + name_len - 1;

                // Overwrite hash entry if longer
                FlintCacheEntry entry = {hash, pid, tid, (uint8_t)name_len};
                memcpy(entry.name, name, name_len);
                ctx->cache[slot] = entry;
            }

        } else {
            FlintBeginEventMax ev;
            ev.event.type = FlintType_Begin;
            ev.event.pid = pid;
            ev.event.tid = tid;
            ev.event.when.floating = when;
            ev.event.name.length = (uint8_t)name_len;
            memcpy(ev.event.name.bytes, name, name_len);
            if (!Flint__BufferWrite(wb, ctx->file, &ev, sizeof(FlintBeginEvent) + name_len - 1)) return false;
            begin_payload_length += sizeof(FlintBeginEvent) + name_len - 1;
        }

    }
    return true;
}
inline bool FlintTraceBeginTidPid(FlintContext *ctx, FlintWriteBuffer *wb, double when, const char *name, uint32_t tid, uint32_t pid) {
    unsigned long name_len;
    if (!name) return false;
    name_len = strlen(name);
    if (!name_len) return false;
    return FlintTraceBeginLenTidPid(ctx, wb, when, name, (signed long)name_len, tid, pid);
}
inline bool FlintTraceBeginLenTid(FlintContext *ctx, FlintWriteBuffer *wb, double when, const char *name, signed long name_len, uint32_t tid) { return FlintTraceBeginLenTidPid(ctx, wb, when, name, name_len, tid, 0); }
inline bool FlintTraceBeginLen   (FlintContext *ctx, FlintWriteBuffer *wb, double when, const char *name, signed long name_len)               { return FlintTraceBeginLenTidPid(ctx, wb, when, name, name_len,   0, 0); }
inline bool FlintTraceBeginTid   (FlintContext *ctx, FlintWriteBuffer *wb, double when, const char *name, uint32_t tid)                       { return FlintTraceBeginTidPid   (ctx, wb, when, name,           tid, 0); }
inline bool FlintTraceBegin      (FlintContext *ctx, FlintWriteBuffer *wb, double when, const char *name)                                     { return FlintTraceBeginTidPid   (ctx, wb, when, name,             0, 0); }

inline bool FlintTraceEndTidPid(FlintContext *ctx, FlintWriteBuffer *wb, double when, uint32_t tid, uint32_t pid) {
    FlintEndEvent ev;
    FlintWriteBuffer wb_ = {0}; if (!wb) wb = &wb_;
    if (!ctx) return false;
    if (!ctx->file) return false;
    if (!ctx->cache) return false;
    if (feof(ctx->file)) return false;
    if (ferror(ctx->file)) return false;
    // if (ctx->times_are_u64) return false;
    ev.type = FlintType_End;
    ev.pid = pid;
    ev.tid = tid;
    ev.when.floating = when;
    if (ctx->is_json) {
        if (fprintf(ctx->file,
                    "{\"ph\":\"E\",\"pid\":%u,\"tid\":%u,\"ts\":%f},\n",
                    ev.pid,
                    ev.tid,
                    ev.when.floating * ctx->timestamp_unit)
            <= 0) return false;
    } else {
        if (!Flint__BufferWrite(wb, ctx->file, &ev, sizeof(ev))) return false;
    }
    return true;
}
inline bool FlintTraceEndTid(FlintContext *ctx, FlintWriteBuffer *wb, double when, uint32_t tid) { return FlintTraceEndTidPid(ctx, wb, when, tid, 0); }
inline bool FlintTraceEnd   (FlintContext *ctx, FlintWriteBuffer *wb, double when)               { return FlintTraceEndTidPid(ctx, wb, when,   0, 0); }

/*
Zero-Clause BSD (0BSD)

Copyright (c) 2022, Phillip Trudeau-Tavara
All rights reserved.

Permission to use, copy, modify, and/or distribute this software
for any purpose with or without fee is hereby granted.

THE SOFTWARE IS PROVIDED "AS IS" AND THE AUTHOR DISCLAIMS ALL
WARRANTIES WITH REGARD TO THIS SOFTWARE INCLUDING ALL IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS. IN NO EVENT SHALL
THE AUTHOR BE LIABLE FOR ANY SPECIAL, DIRECT, INDIRECT, OR
CONSEQUENTIAL DAMAGES OR ANY DAMAGES WHATSOEVER RESULTING FROM
LOSS OF USE, DATA OR PROFITS, WHETHER IN AN ACTION OF CONTRACT,
NEGLIGENCE OR OTHER TORTIOUS ACTION, ARISING OUT OF OR IN CONNECTION
WITH THE USE OR PERFORMANCE OF THIS SOFTWARE.
*/
