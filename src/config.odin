package main

import "core:fmt"
import "core:strings"
import "core:slice"
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

process_map: ValHash
push_event :: proc(processes: ^[dynamic]Process, process_id, thread_id: u32, event: Event) {

	p_idx, ok1 := vh_find(&process_map, process_id)
	if !ok1 {
		append(processes, Process{
			min_time = 0x7fefffffffffffff, 
			process_id = process_id,
			threads = make([dynamic]Thread),
			thread_map = vh_init(scratch_allocator),
		})
		p_idx = len(processes) - 1
		vh_insert(&process_map, process_id, p_idx)
	}

	t_idx, ok2 := vh_find(&processes[p_idx].thread_map, thread_id)
	if !ok2 {
		threads := &processes[p_idx].threads

		append(threads, Thread{ 
			min_time = 0x7fefffffffffffff, 
			thread_id = thread_id,
			events = make([dynamic]Event),
			depths = make([dynamic][]Event),
		})

		t_idx = len(threads) - 1
		thread_map := &processes[p_idx].thread_map
		vh_insert(thread_map, thread_id, t_idx)
	}

	p := &processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)

	total_max_time = max(total_max_time, event.timestamp, event.timestamp + event.duration)
	total_min_time = min(total_min_time, event.timestamp)

	event_to_push := event
	if event_to_push.duration < 0 { event_to_push.duration = 0 }
	append(&t.events, event_to_push)
}

pid_sort_proc :: proc(a, b: Process) -> bool { return a.min_time < b.min_time }
tid_sort_proc :: proc(a, b: Thread) -> bool  { return a.min_time < b.min_time }
event_buildsort_proc :: proc(a, b: Event) -> bool {
	if a.timestamp == b.timestamp {
		return a.duration > b.duration
	}
	return a.timestamp < b.timestamp
}
event_rendersort_step1_proc :: proc(a, b: Event) -> bool {
	return a.depth < b.depth
}
event_rendersort_step2_proc :: proc(a, b: Event) -> bool {
	return a.timestamp < b.timestamp
}

process_events :: proc(processes: ^[dynamic]Process) -> u16 {
	total_max_depth : u16 = 0

	ev_stack: queue.Queue(int)
	queue.init(&ev_stack, 0, context.temp_allocator)

	for pe, _ in process_map.entries {
		proc_idx := pe.val
		process := &processes[proc_idx]

		slice.sort_by(process.threads[:], tid_sort_proc)

		// generate depth mapping
		for tm in &process.threads {
			slice.sort_by(tm.events[:], event_buildsort_proc)

			queue.clear(&ev_stack)		
			for event, e_idx in &tm.events {
				cur_start := event.timestamp
				cur_end   := event.timestamp + event.duration
				if queue.len(ev_stack) == 0 {
					queue.push_back(&ev_stack, e_idx)
				} else {
					prev_e_idx := queue.peek_back(&ev_stack)^
					prev_ev := tm.events[prev_e_idx]

					prev_start := prev_ev.timestamp
					prev_end   := prev_ev.timestamp + prev_ev.duration

					// if it fits within the parent
					if cur_start >= prev_start && cur_end <= prev_end {
						queue.push_back(&ev_stack, e_idx)
					} else {

						// while it doesn't overlap the parent
						for queue.len(ev_stack) > 0 {
							prev_e_idx = queue.peek_back(&ev_stack)^
							prev_ev = tm.events[prev_e_idx]

							prev_start = prev_ev.timestamp
							prev_end   = prev_ev.timestamp + prev_ev.duration


							if cur_start >= prev_start && cur_end > prev_end {
								queue.pop_back(&ev_stack)
							} else {
								break;
							}
						}
						queue.push_back(&ev_stack, e_idx)
					}
				}

				event.depth = u16(queue.len(ev_stack))
				tm.max_depth = max(tm.max_depth, event.depth)
			}
			total_max_depth = max(total_max_depth, tm.max_depth)
			slice.sort_by(tm.events[:], event_rendersort_step1_proc)

			i := 0
			ev_start := 0
			cur_depth : u16 = 0
			for ; i < len(tm.events) - 1; i += 1 {
				ev := tm.events[i]
				next_ev := tm.events[i+1]

				if ev.depth != next_ev.depth {
					append(&tm.depths, tm.events[ev_start:i+1])
					ev_start = i + 1
					cur_depth = next_ev.depth
				}
			}

			if len(tm.events) > 0 {
				append(&tm.depths, tm.events[ev_start:i+1])
			}

			for depth_arr in tm.depths {
				slice.sort_by(depth_arr, event_rendersort_step2_proc)
			}
		}
	}

	slice.sort_by(processes[:], pid_sort_proc)
	return total_max_depth
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


ThreadMap :: distinct map[u32]queue.Queue(TempEvent)
bande_p_to_t: map[u32]ThreadMap
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

first_chunk: bool
@export
init_loading_state :: proc "contextless" (size: u32) {
	context = wasmContext

	started_loading = true
	finished_loading = false
	selected_event = EventID{-1, -1, -1}
	free_all(scratch_allocator)
	free_all(context.allocator)
	free_all(context.temp_allocator)

	processes = make([dynamic]Process)
	process_map = vh_init(scratch_allocator)

	total_max_time = 0
	total_min_time = 0x7fefffffffffffff

	bande_p_to_t  = make(map[u32]ThreadMap, 0, scratch_allocator)

	first_chunk = true
	event_count = 0

	fmt.printf("Loading a %.1f MB config\n", f64(size) / 1024 / 1024)
	start_bench("parse config")
}

finish_loading :: proc (p: ^Parser) {
	for k, v in &bande_p_to_t {
		for q, v2 in &v {
			qlen := queue.len(v2)
			for i := 0; i < qlen; i += 1 {
				ev := queue.pop_back(&v2)

				mod_name, err := strings.intern_get(&p.intern, fmt.tprintf("%s (Did Not Finish)", ev.name))
				if err != nil {
					fmt.printf("OOM!\n")
					trap()
				}

				new_event := Event{
					name = mod_name,
					type = .Complete,
					duration = total_max_time - (ev.timestamp * stamp_scale),
					timestamp = (ev.timestamp) * stamp_scale,
				}

				event_count += 1
				push_event(&processes, ev.process_id, ev.thread_id, new_event)
			}

		}
	}

	stop_bench("parse config")
	fmt.printf("Got %d events\n", event_count)

	start_bench("process events")
	total_max_depth = process_events(&processes)
	stop_bench("process events")

	// reset render state
	color_choices = make([dynamic]Vec3)
	for i := 0; i < 32; i += 1 {
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

	started_loading = false
	finished_loading = true
	return
}

stamp_scale: f64
is_json := false
@export
load_config_chunk :: proc "contextless" (start, total_size: u32, chunk: []u8) {
	context = wasmContext
	defer free_all(context.temp_allocator)

	if first_chunk {
		if len(chunk) < size_of(u64) {
			return
		}
		magic := (^u64)(raw_data(chunk))^

		is_json = magic != spall.MAGIC
		if is_json {
			stamp_scale = 1
			jp = init_json_parser(total_size)
		} else {
			header_sz := size_of(spall.Header)
			if len(chunk) < header_sz {
				return
			}
			
			hdr := cast(^spall.Header)raw_data(chunk)
			if hdr.version != 0 {
				return
			}

			stamp_scale = hdr.timestamp_unit
			bp = init_parser(total_size)
			bp.pos += u32(header_sz)
		}

		started_loading = true
		first_chunk = false
	}

	if is_json {
		load_json_chunk(&jp, start, total_size, chunk)
	} else {
		load_binary_chunk(&bp, start, total_size, chunk)
	}

	return
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

default_config := string(#load("../demos/example_config.json"))
