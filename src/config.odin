package main

import "core:fmt"
import "core:strings"
import "core:container/queue"
import "core:mem"
import "core:math/rand"
import "core:strconv"
import "formats:spall"

start_time: u64
start_mem: u64
allocator: mem.Allocator
start_bench :: proc(name: string, al := context.allocator) {
	start_time = u64(get_time())
	allocator = al
	arena := cast(^Arena)al.data
	start_mem = u64(arena.offset)
}
stop_bench :: proc(name: string) {
	end_time := u64(get_time())
	arena := cast(^Arena)allocator.data
	end_mem := u64(arena.offset)

	time_range := end_time - start_time
	mem_range := end_mem - start_mem
	fmt.printf("%s -- ran in %fs (%dms), used %f MB\n", name, f32(time_range) / 1000, time_range, f64(mem_range) / 1024 / 1024)
}

find_idx :: proc(events: []Event, val: f64) -> int {
	low := 0
	max := len(events)
	high := max - 1

	for low < high {
		mid := (low + high) / 2

		ev := events[mid]
		ev_start := ev.timestamp - total_min_time
		ev_end := ev_start + ev.duration

		if (val >= ev_start && val <= ev_end) {
			return mid
		} else if ev_start < val && ev_end < val { 
			low = mid + 1
		} else { 
			high = mid - 1
		}
	}

	return low
}

jp: JSONParser
bp: Parser

@export
start_loading_file :: proc "contextless" (size: u32) {
	context = wasmContext

	init_loading_state(size)
	get_chunk(0, CHUNK_SIZE)

}

manual_load :: proc(config: string) {
	init_loading_state(u32(len(config)))
	load_config_chunk(0, u32(len(config)), transmute([]u8)config)
}

set_next_chunk :: proc(p: ^Parser, start: u32, chunk: []u8) {
	p.chunk_start = start
	p.full_chunk = chunk
}

instant_count := 0
first_chunk: bool
init_loading_state :: proc(size: u32) {

	selected_event = EventID{-1, -1, -1, -1}
	free_all(scratch_allocator)
	free_all(small_global_allocator)
	free_all(context.allocator)
	free_all(context.temp_allocator)
	processes = make([dynamic]Process, small_global_allocator)
	process_map = vh_init(scratch_allocator)
	global_instants = make([dynamic]Instant, big_global_allocator)
	total_max_time = 0
	total_min_time = 0x7fefffffffffffff

	first_chunk = true
	event_count = 0

	jp = JSONParser{}
	bp = Parser{}
	
	loading_config = true
	post_loading = false

	fmt.printf("Loading a %.1f MB config\n", f64(size) / 1024 / 1024)
	start_bench("parse config")
}

is_json := false
finish_loading :: proc (p: ^Parser) {
	stop_bench("parse config")
	fmt.printf("Got %d events, %d instants\n", event_count, instant_count)

	free_all(context.temp_allocator)
	free_all(scratch_allocator)

	start_bench("process events")
	if is_json {
		json_process_events()
	} else {
		bin_process_events()
	}
	stop_bench("process events")

	// reset render state

	choice_count := int(_pow(2, 6))
	color_choices = make([dynamic]Vec3, 0, choice_count, small_global_allocator)
	for i := 0; i < choice_count; i += 1 {
		h := rand.float64() * 0.5 + 0.5
		h *= h
		h *= h
		h *= h
		s := 0.5 + rand.float64() * 0.1
		v := 0.85

		append(&color_choices, hsv2rgb(Vec3{h, s, v}) * 255)
	}

	t = 0
	frame_count = 0

	free_all(context.temp_allocator)
	free_all(scratch_allocator)

	loading_config = false
	post_loading = true
	return
}

stamp_scale: f64
@export
load_config_chunk :: proc "contextless" (start, total_size: u32, chunk: []u8) {
	context = wasmContext
	defer free_all(context.temp_allocator)

	if first_chunk {
		header_sz := size_of(spall.Header)
		if len(chunk) < header_sz {
			return
		}
		magic := (^u64)(raw_data(chunk))^

		is_json = magic != spall.MAGIC
		if is_json {
			stamp_scale = 1
			jp = init_json_parser(total_size)
		} else {
			hdr := cast(^spall.Header)raw_data(chunk)
			if hdr.version != 0 {
				return
			}

			stamp_scale = hdr.timestamp_unit
			bp = init_parser(total_size)
			bp.pos += u32(header_sz)
		}

		first_chunk = false
	}

	if is_json {
		load_json_chunk(&jp, start, total_size, chunk)
	} else {
		load_binary_chunk(&bp, start, total_size, chunk)
	}

	return
}

bound_duration :: proc(ev: Event, max_ts: f64) -> f64 {
	return ev.duration == -1 ? (max_ts - ev.timestamp) : ev.duration
}

/*
default_config := `[
	{"cat":"function", "name":"0", "ph":"X", "pid":0, "tid": 0, "ts": 0, "dur": 1},
	{"cat":"function", "name":"1", "ph":"X", "pid":0, "tid": 0, "ts": 1, "dur": 1},
	{"cat":"function", "name":"2", "ph":"X", "pid":0, "tid": 0, "ts": 3, "dur": 1},
	{"cat":"function", "name":"3", "ph":"X", "pid":0, "tid": 0, "ts": 4, "dur": 1},
	{"cat":"function", "name":"4", "ph":"X", "pid":0, "tid": 1, "ts": 1, "dur": 1},
]`
*/

/*
default_config := `[
	{"cat":"function", "name":"0", "ph":"B", "pid":0, "tid": 0, "ts": 0},
	{"cat":"function",             "ph":"E", "pid":0, "tid": 0, "ts": 1},
	{"cat":"function", "name":"1", "ph":"B", "pid":0, "tid": 0, "ts": 1},
	{"cat":"function", "name":"2", "ph":"B", "pid":0, "tid": 0, "ts": 2},
	{"cat":"function",             "ph":"E", "pid":0, "tid": 0, "ts": 4},
]`
*/

default_config := string(#load("../demos/example_config.json"))
