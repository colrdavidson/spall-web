// SPDX-FileCopyrightText: © 2023 Phillip Trudeau-Tavara <pmttavara@protonmail.com>
// SPDX-License-Identifier: MIT

/*

TODO: Optional Helper APIs:

  - Compression API: would require a mutexed lockable context (yuck...)
      - Either using a ZIP library, a name cache + TIDPID cache, or both (but ZIP is likely more than enough!!!)
      - begin()/end() writes compressed chunks to a caller-determined destination
          - The destination can be the buffered-writing API or a custom user destination
      - Ultimately need to take a lock with some granularity... can that be the caller's responsibility?

  - Counter Event: should allow tracking arbitrary named values with a single event, for memory and frame profiling

  - Ring-buffer API
        spall_ring_init
        spall_ring_emit_begin
        spall_ring_emit_end
        spall_ring_flush
*/

#ifndef SPALL_H
#define SPALL_H

#if !defined(_MSC_VER) || defined(__clang__)
#define SPALL_NOINSTRUMENT __attribute__((no_instrument_function))
#define SPALL_FORCEINLINE __attribute__((always_inline))
#else
#define _CRT_SECURE_NO_WARNINGS
#define SPALL_NOINSTRUMENT // Can't noinstrument on MSVC!
#define SPALL_FORCEINLINE __forceinline
#endif

#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include <stdbool.h>

#define SPALL_FN static inline SPALL_NOINSTRUMENT
#define SPALL_MIN(a, b) (((a) < (b)) ? (a) : (b))
#define SPALL_MAX(a, b) (((a) > (b)) ? (a) : (b))

#pragma pack(push, 1)

typedef struct SpallHeader {
    uint64_t magic_header; // = 0x0BADF00D
    uint64_t version; // = 3
    double   timestamp_unit;
    uint64_t must_be_0;
} SpallHeader;

typedef enum {
    SpallEventType_Invalid             = 0,
    SpallEventType_Custom_Data         = 1, // Basic readers can skip this.
    SpallEventType_StreamOver          = 2,

    SpallEventType_Begin               = 3,
    SpallEventType_End                 = 4,
    SpallEventType_Instant             = 5,

    SpallEventType_Overwrite_Timestamp = 6, // Retroactively change timestamp units - useful for incrementally improving RDTSC frequency.
    SpallEventType_Pad_Skip            = 7,

	SpallEventType_NameProcess         = 8,
	SpallEventType_NameThread          = 9,
} SpallEventType;

typedef struct SpallBufferHeader {
	uint32_t size;
	uint32_t tid;
	uint32_t pid;
	uint64_t first_ts;
} SpallBufferHeader;

typedef struct SpallBeginEvent {
    uint8_t type; // = SpallEventType_Begin
    uint64_t when;

    uint8_t name_length;
    uint8_t args_length;
} SpallBeginEvent;

typedef struct SpallBeginEventMax {
    SpallBeginEvent event;
    char name_bytes[255];
    char args_bytes[255];
} SpallBeginEventMax;

typedef struct SpallEndEvent {
    uint8_t  type; // = SpallEventType_End
    uint64_t when;
} SpallEndEvent;

typedef struct SpallPadSkipEvent {
    uint8_t  type; // = SpallEventType_Pad_Skip
    uint32_t size;
} SpallPadSkipEvent;

typedef struct SpallNameContainerEvent {
	uint8_t type; // = SpallEventType_NameThread/Process
	uint8_t name_length;
} SpallNameContainerEvent;

typedef struct SpallNameContainerEventMax {
    SpallNameContainerEvent event;
    char name_bytes[255];
} SpallNameContainerEventMax;

#pragma pack(pop)

typedef struct SpallProfile SpallProfile;

// Important!: If you define your own callbacks, mark them SPALL_NOINSTRUMENT!
typedef bool (*SpallWriteCallback)(SpallProfile *self, const void *data, size_t length);
typedef bool (*SpallFlushCallback)(SpallProfile *self);
typedef void (*SpallCloseCallback)(SpallProfile *self);

struct SpallProfile {
    double timestamp_unit;
    SpallWriteCallback write;
    SpallFlushCallback flush;
    SpallCloseCallback close;
    void *data;
};

// Important!: If you are writing Begin/End events, then do NOT write
//             events for the same PID + TID pair on different buffers!!!
typedef struct SpallBuffer {
    void *data;
    size_t length;
	uint32_t tid;
	uint32_t pid;

    // Internal data - don't assign this
    size_t head;
	uint64_t first_ts;
} SpallBuffer;

#ifdef __cplusplus
extern "C" {
#endif

SPALL_FN SPALL_FORCEINLINE bool spall__file_write(SpallProfile *ctx, const void *p, size_t n) {
    if (fwrite(p, n, 1, (FILE *)ctx->data) != 1) return false;
    return true;
}
SPALL_FN bool spall__file_flush(SpallProfile *ctx) {
    if (fflush((FILE *)ctx->data)) return false;
    return true;
}
SPALL_FN void spall__file_close(SpallProfile *ctx) {
    fclose((FILE *)ctx->data);
    ctx->data = NULL;
}

SPALL_FN SPALL_FORCEINLINE bool spall__buffer_flush(SpallProfile *ctx, SpallBuffer *wb, uint64_t ts) {
	wb->first_ts = SPALL_MAX(wb->first_ts, ts);

	SpallBufferHeader hdr;
	hdr.size = wb->head - sizeof(SpallBufferHeader);
	hdr.pid = wb->pid;
	hdr.tid = wb->tid;
	hdr.first_ts = wb->first_ts;

	memcpy(wb->data, &hdr, sizeof(hdr));

	if (!ctx->write(ctx, wb->data, wb->head)) return false;
    wb->head = sizeof(SpallBufferHeader);
    return true;
}

SPALL_FN bool spall_buffer_flush(SpallProfile *ctx, SpallBuffer *wb) {
    if (!spall__buffer_flush(ctx, wb, 0)) return false;
    return true;
}

SPALL_FN bool spall_buffer_quit(SpallProfile *ctx, SpallBuffer *wb) {
    if (!spall_buffer_flush(ctx, wb)) return false;
    return true;
}

SPALL_FN size_t spall_build_header(void *buffer, size_t rem_size, double timestamp_unit) {
    size_t header_size = sizeof(SpallHeader);
    if (header_size > rem_size) {
        return 0;
    }

    SpallHeader *header = (SpallHeader *)buffer;
    header->magic_header = 0x0BADF00D;
    header->version = 3;
    header->timestamp_unit = timestamp_unit;
    header->must_be_0 = 0;
    return header_size;
}
SPALL_FN SPALL_FORCEINLINE size_t spall_build_begin(void *buffer, size_t rem_size, const char *name, int32_t name_len, const char *args, int32_t args_len, uint64_t when) {
    SpallBeginEventMax *ev = (SpallBeginEventMax *)buffer;
    uint8_t trunc_name_len = (uint8_t)SPALL_MIN(name_len, 255); // will be interpreted as truncated in the app (?)
    uint8_t trunc_args_len = (uint8_t)SPALL_MIN(args_len, 255); // will be interpreted as truncated in the app (?)

    size_t ev_size = sizeof(SpallBeginEvent) + trunc_name_len + trunc_args_len;
    if (ev_size > rem_size) {
        return 0;
    }

    ev->event.type = SpallEventType_Begin;
    ev->event.when = when;
    ev->event.name_length = trunc_name_len;
    ev->event.args_length = trunc_args_len;
    memcpy(ev->name_bytes,                  name, trunc_name_len);
    memcpy(ev->name_bytes + trunc_name_len, args, trunc_args_len);

    return ev_size;
}
SPALL_FN SPALL_FORCEINLINE size_t spall_build_end(void *buffer, size_t rem_size, uint64_t when) {
    size_t ev_size = sizeof(SpallEndEvent);
    if (ev_size > rem_size) {
        return 0;
    }

    SpallEndEvent *ev = (SpallEndEvent *)buffer;
    ev->type = SpallEventType_End;
    ev->when = when;

    return ev_size;
}
SPALL_FN SPALL_FORCEINLINE size_t spall_build_name(void *buffer, size_t rem_size, const char *name, int32_t name_len, SpallEventType type) {
    SpallNameContainerEventMax *ev = (SpallNameContainerEventMax *)buffer;
    uint8_t trunc_name_len = (uint8_t)SPALL_MIN(name_len, 255); // will be interpreted as truncated in the app (?)

    size_t ev_size = sizeof(SpallNameContainerEvent) + trunc_name_len;
    if (ev_size > rem_size) {
        return 0;
    }

    ev->event.type = type;
    ev->event.name_length = trunc_name_len;
    memcpy(ev->name_bytes, name, trunc_name_len);

    return ev_size;
}

SPALL_FN void spall_quit(SpallProfile *ctx) {
    if (!ctx) return;
    if (ctx->close) ctx->close(ctx);

    memset(ctx, 0, sizeof(*ctx));
}

SPALL_FN bool spall_init_callbacks(double timestamp_unit,
								   SpallWriteCallback write,
								   SpallFlushCallback flush,
								   SpallCloseCallback close,
								   void *userdata,
								   SpallProfile *ctx) {

    if (timestamp_unit < 0) return false;

    memset(ctx, 0, sizeof(*ctx));
    ctx->timestamp_unit = timestamp_unit;
    ctx->data = userdata;
    ctx->write = write;
    ctx->flush = flush;
    ctx->close = close;

	SpallHeader header;
	size_t len = spall_build_header(&header, sizeof(header), timestamp_unit);
	if (!ctx->write(ctx, &header, len)) {
		spall_quit(ctx);
		return false;
	}

    return true;
}

SPALL_FN bool spall_init_file(const char* filename, double timestamp_unit, SpallProfile *ctx) {
    if (!filename) return false;

    FILE *f = fopen(filename, "wb"); // TODO: handle utf8 and long paths on windows
    if (f) { // basically freopen() but we don't want to force users to lug along another macro define
        fclose(f);
        f = fopen(filename, "ab");
    }
	if (!f) { return false; }

    return spall_init_callbacks(timestamp_unit, spall__file_write, spall__file_flush, spall__file_close, (void *)f, ctx);
}

SPALL_FN bool spall_flush(SpallProfile *ctx) {
    if (!ctx->flush(ctx)) return false;
    return true;
}

SPALL_FN bool spall_buffer_init(SpallProfile *ctx, SpallBuffer *wb) {
	// Fails if buffer is not big enough to contain at least one event!
	if (wb->length < sizeof(SpallBufferHeader) + sizeof(SpallBeginEventMax)) {
		return false;
	}

	wb->head = sizeof(SpallBufferHeader);
	return true;
}


SPALL_FN SPALL_FORCEINLINE bool spall_buffer_begin_args(SpallProfile *ctx, SpallBuffer *wb, const char *name, int32_t name_len, const char *args, int32_t args_len, uint64_t when) {
	if ((wb->head + sizeof(SpallBeginEventMax)) > wb->length) {
		if (!spall__buffer_flush(ctx, wb, when)) {
			return false;
		}
	}

	wb->head += spall_build_begin((char *)wb->data + wb->head, wb->length - wb->head, name, name_len, args, args_len, when);

    return true;
}

SPALL_FN bool spall_buffer_begin(SpallProfile *ctx, SpallBuffer *wb, const char *name, int32_t name_len, uint64_t when) {
    return spall_buffer_begin_args(ctx, wb, name, name_len, "", 0, when);
}

SPALL_FN bool spall_buffer_end(SpallProfile *ctx, SpallBuffer *wb, uint64_t when) {
	if ((wb->head + sizeof(SpallEndEvent)) > wb->length) {
		if (!spall__buffer_flush(ctx, wb, when)) {
			return false;
		}
	}

	wb->head += spall_build_end((char *)wb->data + wb->head, wb->length - wb->head, when);
	return true;
}

SPALL_FN bool spall_buffer_name_thread(SpallProfile *ctx, SpallBuffer *wb, const char *name, int32_t name_len) {
	if ((wb->head + sizeof(SpallNameContainerEvent)) > wb->length) {
		if (!spall__buffer_flush(ctx, wb, 0)) {
			return false;
		}
	}

	wb->head += spall_build_name((char *)wb->data + wb->head, wb->length - wb->head, name, name_len, SpallEventType_NameThread);
	return true;
}

SPALL_FN bool spall_buffer_name_process(SpallProfile *ctx, SpallBuffer *wb, const char *name, int32_t name_len) {
	if ((wb->head + sizeof(SpallNameContainerEvent)) > wb->length) {
		if (!spall__buffer_flush(ctx, wb, 0)) {
			return false;
		}
	}

	wb->head += spall_build_name((char *)wb->data + wb->head, wb->length - wb->head, name, name_len, SpallEventType_NameProcess);
	return true;
}

#ifdef __cplusplus
}
#endif

#endif // SPALL_H
