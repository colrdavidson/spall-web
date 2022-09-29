package main

import "core:fmt"
import "core:os"
import "formats:spall"

buf: [dynamic]u8

emit_json_event :: proc(tid, ts, dur: int) {
	name := fmt.tprintf("foo-%d\n", tid)
	str := fmt.tprintf("\t\t{{\"cat\":\"function\", \"dur\":%d, \"name\":\"%s\", \"ph\":\"X\", \"pid\":0, \"tid\": %d, \"ts\": %d}},\n", dur, name, tid, ts)
	append(&buf, str)
}

emit_header :: proc() {
	header := spall.Header{magic = spall.MAGIC, version = 0, timestamp_unit = 1.0, must_be_0 = 0}
	header_bytes := transmute([size_of(spall.Header)]u8)header
	append(&buf, ..header_bytes[:])
}
emit_begin_event :: proc(name: string, pid, tid, ts: int) {
	begin := spall.Begin_Event {
		type = .Begin,
		pid  = u32(pid),
		tid  = u32(tid),
		time = f64(ts),
		name_len = u8(len(name)),
	}

	begin_bytes := transmute([size_of(spall.Begin_Event)]u8)begin
	append(&buf, ..begin_bytes[:])
	append(&buf, name)

}
emit_end_event :: proc(pid, tid, ts: int) {
	end := spall.End_Event {
		type = .End,
		pid  = u32(pid),
		tid  = u32(tid),
		time = f64(ts),
	}
	end_bytes := transmute([size_of(spall.End_Event)]u8)end
	append(&buf, ..end_bytes[:])
}

gen_triangle :: proc(tid, start, end: int) {
	if end - start <= 0 {
		return
	}

	name := fmt.tprintf("foo-%d\n", tid)
	emit_begin_event(name, 0, tid, start)
	gen_triangle(tid, start + 1, end - 1)
	emit_end_event(0, tid, end)
}

/*
	|---------|
	 |-------|
	  |----|
*/

gen_triangles :: proc(tid_count, rank, size: int) {
	width := rank * 2
	ts_count := 0
	for i := 0; i < size; i += 1 {
		for tid := 0; tid < tid_count; tid += 1 {
			start := ts_count * width
			end := (ts_count * width) + width
			gen_triangle(tid, start, end)
		}

		ts_count += 1
	}
}


/*
	|-----------------------------|
	 |------------| |------------|
	  |----| |---|   |----| |---|
*/

/*
gen_fractals :: proc(tid_count, start_ts, width: int) {
	if width <= 0 {
		return
	}

	for i := 0; i < tid_count; i += 1 {
		emit_bin_event(i, start_ts, width)
	}

	subdivision := 8
	seg_width := (width / subdivision) - 1
	
	for i := 0; i < subdivision; i += 1 {	
		gen_fractals(tid_count, start_ts + (i + 1) + (i * seg_width), seg_width)
	}
}
*/

main :: proc() {
	emit_header()
	//fmt.fprintf("{{\n\t\"traceEvents\": [\n")
	//gen_fractals(8, 1_000_000, 20_000_000)
	gen_triangles(8, 10, 300_000)
	//fmt.fprintf("\t]\n}}")

	out_file := "test_DUMP.spall"
	if os.write_entire_file(out_file, buf[:]) {
		//fmt.printf("Done, wrote %v events to %v (%v bytes)\n", len(trace.traceEvents), out_file, len(buf))
	} else {
		fmt.eprintf("Problem writing to %v\n", out_file)
		os.exit(1)
	}
}
