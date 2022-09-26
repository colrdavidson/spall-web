package main

import "core:fmt"
import "core:os"

emit_event :: proc(fd: os.Handle, tid, ts, dur: int) {
	name := fmt.tprintf("foo-%d\n", tid)
	fmt.fprintf(fd, "\t\t{{\"cat\":\"function\", \"dur\":%d, \"name\":\"%s\", \"ph\":\"X\", \"pid\":0, \"tid\": %d, \"ts\": %d}},\n", dur, name, tid, ts)
}

gen_triangles :: proc(fd: os.Handle, tid_count, rank, size: int) {
	ts_count := 0
	for i := 0; i < size; i += 1 {
		for tid := 0; tid < tid_count; tid += 1 {
			for k := 0; k < rank; k += 1 {
				emit_event(fd, tid, (ts_count * rank * 2) + k, (rank - k) * 2)
			}
		}

		ts_count += 1
	}
}

/*
	|-----------------------------|
	 |------------| |------------|
	  |----| |---|   |----| |---|
*/

gen_fractals :: proc(fd: os.Handle, tid_count, start_ts, width: int) {
	if width <= 0 {
		return
	}

	for i := 0; i < tid_count; i += 1 {
		emit_event(fd, i, start_ts, width)
	}

	subdivision := 8
	seg_width := (width / subdivision) - 1
	
	for i := 0; i < subdivision; i += 1 {	
		gen_fractals(fd, tid_count, start_ts + (i + 1) + (i * seg_width), seg_width)
	}
}

main :: proc() {
	json_fd, err := os.open("test_DUMP.json", os.O_WRONLY | os.O_CREATE, 0o644)
	if err != 0 {
		fmt.printf("failed to open file: %s\n", err)
	}

	fmt.fprintf(json_fd, "{{\n\t\"traceEvents\": [\n")
	gen_fractals(json_fd, 8, 1_000_000, 1_000_000)
	//gen_triangles(json_fd, 8, 10, 5_000)
	fmt.fprintf(json_fd, "\t]\n}}")
}
