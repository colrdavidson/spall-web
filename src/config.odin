package main

import "core:fmt"
import "core:strings"
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
	get_chunk(0.0, f64(CHUNK_SIZE))

}

manual_load :: proc(config: string) {
	init_loading_state(u32(len(config)))
	load_config_chunk(0, u32(len(config)), transmute([]u8)config)
}

set_next_chunk :: proc(p: ^Parser, start: u32, chunk: []u8) {
	p.chunk_start = i64(start)
	p.full_chunk = chunk
}

gen_event_color :: proc(events: []Event, thread_max: f64) -> (FVec4, f32) {
	total_weight : f32 = 0

	color := FVec4{}
	color_weights := [choice_count]f32{}
	for ev in events {
		idx := name_color_idx(ev.name)

		duration := f32(bound_duration(ev, thread_max))
		if duration <= 0 {
			//fmt.printf("weird duration: %d, %#v\n", duration, ev)
			duration = 0.1
		}
		color_weights[idx] += duration
		total_weight += duration
	}

	weights_sum : f32 = 0
	for weight, idx in color_weights {
		color += color_choices[idx] * weight
		weights_sum += weight
	}
	if weights_sum <= 0 {
		fmt.printf("Invalid weights sum! events: %d, %f, %f\n", len(events), weights_sum, total_weight)
		trap()
	}
	color /= weights_sum

	return color, total_weight
}

CHUNK_NARY_WIDTH :: 8
build_tree :: proc(tm: ^Thread, depth_idx: int, events: []Event) -> int {
	tree := &tm.depths[depth_idx].tree

	bucket_size :: 16 
	bucket_count := i_round_up(len(events), bucket_size) / bucket_size
	for i := 0; i < bucket_count; i += 1 {
		start_idx := i * bucket_size
		end_idx := start_idx + min(len(events) - start_idx, bucket_size)
		scan_arr := events[start_idx:end_idx]

		start_ev := scan_arr[0]
		end_ev := scan_arr[len(scan_arr)-1]

		node := ChunkNode{}
		node.start_time = start_ev.timestamp - total_min_time
		node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - total_min_time
		node.start_idx = start_idx
		node.end_idx   = end_idx

		avg_color, weight := gen_event_color(scan_arr, tm.max_time)
		node.avg_color = avg_color
		node.weight = weight

		append(tree, node)
	}

	tree_start_idx := 0
	tree_end_idx := len(tree)

	row_count := len(tree)
	parent_row_count := (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
	for row_count > 1 {
		for i := 0; i < parent_row_count; i += 1 {
			start_idx := tree_start_idx + (i * CHUNK_NARY_WIDTH)
			end_idx := start_idx + min(tree_end_idx - start_idx, CHUNK_NARY_WIDTH)

			children := tree[start_idx:end_idx]

			start_node := children[0]
			end_node := children[len(children)-1]

			node := ChunkNode{}
			node.start_time = start_node.start_time
			node.end_time   = end_node.end_time
			node.start_idx  = start_node.start_idx
			node.end_idx    = end_node.end_idx

			avg_color := FVec4{}
			for j := 0; j < len(children); j += 1 {
				node.children[j] = start_idx + j
				avg_color += children[j].avg_color * children[j].weight
				node.weight += children[j].weight
			}
			node.child_count = i8(len(children))
			node.avg_color = avg_color / node.weight

			append(tree, node)
		}

		tree_start_idx = tree_end_idx
		tree_end_idx = len(tree)
		row_count = tree_end_idx - tree_start_idx
		parent_row_count = (row_count + (CHUNK_NARY_WIDTH - 1)) / CHUNK_NARY_WIDTH
	}

	return len(tree) - 1
}

print_tree :: proc(tree: []ChunkNode, head: int) {
	fmt.printf("mah tree!\n")
	// If we blow this, we're in space
	tree_stack := [128]int{}
	stack_len := 0
	pad_buf := [?]u8{0..<64 = '\t',}

	tree_stack[0] = head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := tree[tree_idx]

		//padding := pad_buf[len(pad_buf) - stack_len:]
		fmt.printf("%d | %v\n", tree_idx, cur_node)

		if cur_node.child_count == 0 {
			continue
		}

		for i := (cur_node.child_count - 1); i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}
	fmt.printf("ded!\n")
}

chunk_events :: proc() {
	for proc_v in &processes {
		for tm in &proc_v.threads {
			for depth, d_idx in &tm.depths {
				depth.tree = make([dynamic]ChunkNode, 0, big_global_allocator)
				depth.head = build_tree(&tm, d_idx, depth.events)

				//print_tree(depth.tree[:], depth.head)
			}
		}
	}
}

instant_count := 0
first_chunk: bool
init_loading_state :: proc(size: u32) {

	selected_event = EventID{-1, -1, -1, -1}
	free_all(scratch_allocator)
	free_all(small_global_allocator)
	free_all(big_global_allocator)
	free_all(temp_allocator)
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

	free_all(temp_allocator)
	free_all(scratch_allocator)

	start_bench("process events")
	if is_json {
		json_process_events()
	} else {
		bin_process_events()
	}
	stop_bench("process events")

	free_all(temp_allocator)
	free_all(scratch_allocator)

	// reset render state
	mem.zero_slice(color_choices[:])
	for i := 0; i < choice_count; i += 1 {

		h := rand.float32() * 0.5 + 0.5
		h *= h
		h *= h
		h *= h
		s := 0.5 + rand.float32() * 0.1
		v : f32 = 0.85

		color_choices[i] = hsv2rgb(FVec4{h, s, v, 255}) * 255
	}

	start_bench("chunk events")
	chunk_events()
	stop_bench("chunk events")

	t = 0
	frame_count = 0

	free_all(temp_allocator)
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
			bp.pos += i64(header_sz)
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
	{"cat":"function", "name":"4", "ph":"X", "pid":0, "tid": 0, "ts": 6, "dur": 1},
	{"cat":"function", "name":"5", "ph":"X", "pid":0, "tid": 1, "ts": 1, "dur": 1},
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
