package main

import "base:runtime"

import "core:fmt"
import "core:strings"
import "core:mem"
import "core:math/rand"
import "core:strconv"
import "core:container/queue"
import "formats:spall"

find_idx :: proc(trace: ^Trace, events: []Event, val: i64) -> int {
	low := 0
	max := len(events)
	high := max - 1

	for low < high {
		mid := (low + high) / 2

		ev := events[mid]
		ev_start := ev.timestamp - trace.total_min_time
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

@export
start_loading_file :: proc "contextless" (size: u32, name: string) {
	context = wasmContext
	init_loading_state(&_trace, size, name)
	get_chunk(0.0, f64(CHUNK_SIZE))

}

manual_load :: proc(config, name: string) {
	init_loading_state(&_trace, u32(len(config)), name)
	load_config_chunk(transmute([]u8)config)
}

gen_event_color :: proc(trace: ^Trace, _events: []Event, thread_max: i64, node: ^ChunkNode) {
	total_weight : i64 = 0

	events := _events

	if len(events) == 1 {
		ev := &events[0]
		duration := bound_duration(ev, thread_max)
		idx := name_color_idx(ev.name)
		node.avg_color = trace.color_choices[idx]

		// if the event was started with no end, *right* as the trace quit, we'll get a duration of 0
		// make this 1 so it has *some* LOD contribution
		node.weight = max(duration, 1)
		return
	}

	color := FVec3{}
	color_weights := [COLOR_CHOICES]i64{}
	for &ev in events {
		idx := name_color_idx(ev.name)
		duration := bound_duration(&ev, thread_max)

		color_weights[idx] += duration
		total_weight += duration
	}

	weights_sum : i64 = 0
	for weight, idx in color_weights {
		color += trace.color_choices[idx] * f32(weight)
		weights_sum += weight
	}
	color /= f32(weights_sum)

	node.avg_color = color
	node.weight = total_weight
}

print_tree :: proc(depth: ^Depth) {
	fmt.printf("mah tree!\n")
	// If we blow this, we're in space
	tree_stack := [128]int{}
	stack_len := 0
	pad_buf := [?]u8{0..<64 = '\t',}

	tree_stack[0] = 0; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := &depth.tree[tree_idx]

		fmt.printf("%d | start: %v, end: %v, weight: %v\n", tree_idx, cur_node.start_time, cur_node.end_time, cur_node.weight)

		if tree_idx > (len(depth.tree) - depth.leaf_count - 1) {
			continue
		}

		start_idx := (CHUNK_NARY_WIDTH * tree_idx) + 1
		end_idx := min(start_idx + CHUNK_NARY_WIDTH - 1, len(depth.tree) - 1)
		child_count := end_idx - start_idx
		for i := child_count; i >= 0; i -= 1 {
			tree_stack[stack_len] = start_idx + i; stack_len += 1
		}
	}
	fmt.printf("ded!\n")
}

chunk_events :: proc(trace: ^Trace) {
	lod_mem_usage := 0
	ev_mem_usage := 0

	// using an eytzinger LOD tree for each depth array
	for &proc_v, p_idx in trace.processes {
		for &tm, t_idx in proc_v.threads {
			for &depth, d_idx in tm.depths {
				leaf_count := i_round_up(len(depth.events), BUCKET_SIZE) / BUCKET_SIZE
				depth.leaf_count = leaf_count

				width := CHUNK_NARY_WIDTH - 1
				internal_node_count := i_round_up((leaf_count - 1), width) / width
				total_node_count := internal_node_count + leaf_count

				tm.depths[d_idx].tree = make([]ChunkNode, total_node_count, big_global_allocator)
				zero_slice(tm.depths[d_idx].tree)

				lod_mem_usage += size_of(ChunkNode) * total_node_count
				ev_mem_usage += size_of(Event) * len(depth.events)

				tree := tm.depths[d_idx].tree
				tree_start_idx := len(tree) - leaf_count

				cur_node := 0
				overhang_idx := 0
				prehang_rank := 0
				for ; cur_node < total_node_count; {
					overhang_idx = cur_node
					cur_node = (CHUNK_NARY_WIDTH * cur_node) + 1

					prehang_rank += 1
				}

				posthang_rank := 1
				tmp_idx := len(tree) - leaf_count
				for ; tmp_idx > 0; {
					tmp_idx = (tmp_idx - 1) / CHUNK_NARY_WIDTH
					posthang_rank += 1
				}

				_tmp := 1
				for _tmp < leaf_count {
					_tmp = _tmp * CHUNK_NARY_WIDTH
				}
				depth.full_leaves = _tmp

				overhang_len := len(tree) - overhang_idx
				if prehang_rank == posthang_rank {
					overhang_len = 0
				}
				depth.overhang_len = overhang_len

				for i := 0; i < overhang_len; i += 1 {
					start_idx := i * BUCKET_SIZE
					end_idx := start_idx + min(len(depth.events) - start_idx, BUCKET_SIZE)
					scan_arr := depth.events[start_idx:end_idx]

					start_ev := &scan_arr[0]
					end_ev := &scan_arr[len(scan_arr)-1]
					tree_idx := overhang_idx + i

					node := &tree[tree_idx]
					node.start_time = start_ev.timestamp - trace.total_min_time
					node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - trace.total_min_time
					gen_event_color(trace, scan_arr, tm.max_time, node)

				}

				previous_len := leaf_count - overhang_len
				ev_offset := overhang_len * BUCKET_SIZE
				for i := 0; i < previous_len; i += 1 {
					start_idx := (i * BUCKET_SIZE) + ev_offset
					end_idx := start_idx + min(len(depth.events) - start_idx, BUCKET_SIZE)
					scan_arr := depth.events[start_idx:end_idx]

					start_ev := &scan_arr[0]
					end_ev := &scan_arr[len(scan_arr)-1]
					tree_idx := tree_start_idx + i

					node := &tree[tree_idx]
					node.start_time = start_ev.timestamp - trace.total_min_time
					node.end_time   = end_ev.timestamp + bound_duration(end_ev, tm.max_time) - trace.total_min_time
					gen_event_color(trace, scan_arr, tm.max_time, node)
				}

				avg_color := FVec3{}
				for i := tree_start_idx - 1; i >= 0; i -= 1 {
					node := &tree[i]

					start_idx := (CHUNK_NARY_WIDTH * i) + 1
					end_idx := min(start_idx + (CHUNK_NARY_WIDTH - 1), len(tree) - 1)

					node.start_time = tree[start_idx].start_time
					node.end_time   = tree[end_idx].end_time

					avg_color = {}
					for j := start_idx; j <= end_idx; j += 1 {
						avg_color += tree[j].avg_color * f32(tree[j].weight)
						node.weight += tree[j].weight
					}
					node.avg_color = avg_color / f32(node.weight)
				}
			}
		}
	}

	fmt.printf("LOD memory: %M | Event memory: %M\n", lod_mem_usage, ev_mem_usage)
}

get_left_child :: #force_inline proc(idx: int) -> int {
	return (CHUNK_NARY_WIDTH * idx) + 1
}
get_child_count :: proc(depth: ^Depth, idx: int) -> int {
	start_idx := get_left_child(idx)
	end_idx := min(start_idx + CHUNK_NARY_WIDTH - 1, len(depth.tree) - 1)
	child_count := end_idx - start_idx + 1

	return child_count
}

linearize_leaf :: proc(depth: ^Depth, idx: int, loc := #caller_location) -> int {
	overhang_start := len(depth.tree) - depth.overhang_len
	leaf_start := len(depth.tree) - depth.leaf_count

	ret := 0
	if depth.overhang_len == 0 {
		ret = idx - leaf_start
	} else if idx >= overhang_start {
		ret = idx - overhang_start
	} else {
		ret = (idx - leaf_start) + depth.overhang_len
	}
	return ret
}

// This *must* take a leaf idx
get_event_count :: proc(depth: ^Depth, idx: int) -> int {
	linear_idx := linearize_leaf(depth, idx)

	ret := BUCKET_SIZE
	// if we're the last index in the tree, determine the leftover
	if linear_idx == (depth.leaf_count - 1) {
		ret = len(depth.events) % BUCKET_SIZE


		// If we fall exactly in the bucket?
		if ret == 0 {
			ret = BUCKET_SIZE
		}
	}

	return ret
}
// This *must* take a leaf idx
get_event_start_idx :: proc(depth: ^Depth, idx: int) -> int {
	linear_idx := linearize_leaf(depth, idx)
	return linear_idx * BUCKET_SIZE
}

is_leaf :: proc(depth: ^Depth, idx: int) -> bool {
	ret := idx >= (len(depth.tree) - depth.leaf_count)
	return ret
}

get_left_leaf :: proc(depth: ^Depth, idx: int) -> int {
	tmp_idx := idx
	last_tmp := idx
	for tmp_idx < len(depth.tree) {
		last_tmp = tmp_idx
		tmp_idx = (CHUNK_NARY_WIDTH * tmp_idx) + 1
	}
	return last_tmp
}
get_right_leaf :: proc(depth: ^Depth, idx: int) -> int {
	if is_leaf(depth, idx) {
		return idx
	}

	full_internal_nodes := depth.full_leaves / (CHUNK_NARY_WIDTH - 1)
	full_tree_count := full_internal_nodes + depth.full_leaves

	internal_nodes := depth.leaf_count / (CHUNK_NARY_WIDTH - 1)
	total_tree_count := internal_nodes + depth.leaf_count

	prev_leaves := depth.full_leaves / CHUNK_NARY_WIDTH

	tmp_idx := idx
	last_tmp := idx
	for tmp_idx < len(depth.tree) {
		last_tmp = tmp_idx
		tmp_idx = (CHUNK_NARY_WIDTH * tmp_idx) + CHUNK_NARY_WIDTH
	}

	ret := last_tmp
	edge_case_count := total_tree_count + CHUNK_NARY_WIDTH - 1
	if edge_case_count >= full_tree_count {
		ret = len(depth.tree) - 1
	}
	return ret
}

get_event_range :: proc(depth: ^Depth, idx: int) -> (int, int) {
	left_idx := get_left_leaf(depth, idx)
	right_idx := get_right_leaf(depth, idx)
	event_start_idx := get_event_start_idx(depth, left_idx)
	event_count := get_event_count(depth, right_idx)

	linear_right_leaf := linearize_leaf(depth, right_idx)
	linear_left_leaf := linearize_leaf(depth, left_idx)
	leaf_count := linear_right_leaf - linear_left_leaf
	ev_count := (leaf_count * BUCKET_SIZE) + event_count

	start := event_start_idx
	end := event_start_idx + ev_count
	return start, end
}

instant_count := 0
first_chunk: bool
init_loading_state :: proc(trace: ^Trace, size: u32, name: string) {
	ingest_start_time = u64(get_time())

	b := strings.builder_from_slice(trace.file_name_store[:])
	strings.write_string(&b, name)
	trace.file_name = strings.to_string(b)

	// reset selection state
	clicked_on_rect = false
	stats_state = .NoStats
	total_tracked_time = 0.0
	selected_event = EventID{-1, -1, -1, -1}

	// wipe all allocators
	free_all(scratch_allocator)
	free_all(scratch2_allocator)
	free_all(small_global_allocator)
	free_all(big_global_allocator)
	free_all(temp_allocator)

	trace.processes = make([dynamic]Process, small_global_allocator)
	trace.stats = sm_init(big_global_allocator)
	trace.selected_ranges = make([dynamic]Range, 0, big_global_allocator)
	trace.process_map = vh_init(scratch_allocator)
	trace.total_max_time = min(i64)
	trace.total_min_time = max(i64)
	trace.event_count = 0
	trace.instant_count = 0
	trace.stamp_scale = 1
	trace.intern = in_init(big_global_allocator)
	trace.string_block = make([dynamic]u8, big_global_allocator)
	trace.global_instants = make([dynamic]Instant, big_global_allocator)
	trace.parser = init_parser(size)
	trace.error_message = ""

	// deliberately setting the first elem to 0, to simplify string interactions
	append_elem(&trace.string_block, 0)
	append_elem(&trace.string_block, 0)

	last_read = 0
	first_chunk = true
	
	loading_config = true
	post_loading = false

	fmt.printf("Loading a %M config\n", size)
	start_bench("parse config")
}

is_json := false
finish_loading :: proc (trace: ^Trace) {
	stop_bench("parse config")
	fmt.printf("Got %d events, %d instants\n", trace.event_count, trace.instant_count)

	free_all(temp_allocator)
	free_all(scratch_allocator)
	free_all(scratch2_allocator)

	start_bench("process and sort events")
	if is_json {
		json_process_events(trace)
	} else {
		ms_v1_bin_process_events(trace)
	}
	stop_bench("process and sort events")

	free_all(temp_allocator)
	free_all(scratch_allocator)

	generate_color_choices(trace)

	start_bench("generate spatial partitions")
	chunk_events(trace)
	stop_bench("generate spatial partitions")

	start_bench("generate self-time")
	if is_json {
		json_generate_selftimes(trace)
	}
	stop_bench("generate self-time")

	t = 0
	frame_count = 0

	free_all(temp_allocator)
	free_all(scratch_allocator)

	loading_config = false
	post_loading = true


	ingest_end_time := u64(get_time())
	time_range := ingest_end_time - ingest_start_time
	fmt.printf("runtime: %fs (%dms)\n", f32(time_range) / 1000, time_range)
	return
}

@export
load_config_chunk :: proc "contextless" (chunk: []u8) {
	context = wasmContext
	defer free_all(context.temp_allocator)

	if first_chunk {
		header_sz := size_of(spall.Header)
		if len(chunk) < header_sz {
			fmt.printf("Uh, you passed me an empty file?\n")
			finish_loading(&_trace)
			return
		}
		magic := (^u64)(raw_data(chunk))^

		is_json = false
		if magic == spall.MANUAL_MAGIC {
			hdr := cast(^spall.Header)raw_data(chunk)
			if hdr.version != 1 {
				fmt.printf("Your file version (%d) is not supported!\n", hdr.version)
				push_fatal(SpallError.InvalidFileVersion)
			}

			_trace.stamp_scale = hdr.timestamp_unit
			_trace.stamp_scale *= 1000
			_trace.parser.pos += i64(header_sz)
		} else if magic == spall.NATIVE_MAGIC {
			fmt.printf("You're trying to use a native-version file on the web!\n")
			push_fatal(SpallError.NativeFileDetected)
		} else {
			is_json = true
			_trace.stamp_scale = 1
			_trace.json_parser = init_json_parser()
		}

		first_chunk = false
	}

	if is_json {
		load_json_chunk(&_trace, chunk)
	} else {
		ms_v1_load_binary_chunk(&_trace, chunk)
	}

	return
}

bound_duration :: proc(ev: $T, max_ts: i64) -> i64 {
	return ev.duration == -1 ? (max_ts - ev.timestamp) : ev.duration
}

append_event :: proc(array: ^[dynamic]Event, arg: Event) {
	if cap(array) < (len(array) + 1) {

		capacity := 2 * cap(array)
		a := (^runtime.Raw_Dynamic_Array)(array)

		old_size  := a.cap * size_of(Event)
		new_size  := capacity * size_of(Event)

		allocator := a.allocator

		new_data, err := allocator.procedure(
			allocator.data, .Resize, new_size, align_of(Event),
			a.data, old_size)

		a.data = raw_data(new_data)
		a.cap = capacity
	}

	if (cap(array) - len(array)) > 0 {
		a := (^runtime.Raw_Dynamic_Array)(array)
		data := ([^]Event)(a.data)
		data[a.len] = arg
		a.len += 1
	}
}

setup_pid :: proc(trace: ^Trace, process_id: u32) -> i32 {
	p_idx, ok := vh_find(&trace.process_map, process_id)
	if !ok {
		append(&trace.processes, init_process(process_id))
		p_idx = i32(len(trace.processes) - 1)
		vh_insert(&trace.process_map, process_id, p_idx)
	}

	return p_idx
}

setup_tid :: proc(trace: ^Trace, p_idx: i32, thread_id: u32) -> i32 {
	t_idx, ok := vh_find(&trace.processes[p_idx].thread_map, thread_id)
	if !ok {
		threads := &trace.processes[p_idx].threads

		append(threads, init_thread(thread_id))

		t_idx = i32(len(threads) - 1)
		thread_map := &trace.processes[p_idx].thread_map
		vh_insert(thread_map, thread_id, t_idx)
	}

	return t_idx
}

default_config_name :: "../demos/cuik_c_compiler.json"
default_config := string(#load(default_config_name))
