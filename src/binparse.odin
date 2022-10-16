package main

import "core:fmt"
import "core:strings"
import "core:container/queue"
import "core:slice"
import "formats:spall"

BinaryState :: enum {
	PartialRead,
	EventRead,
	Finished,
	Failed,
}

Parser :: struct {
	pos: i64,
	offset: i64,

	data: []u8,
	full_chunk: []u8,
	chunk_start: i64,
	total_size: i64,

	intern: INMap,
}

real_pos :: #force_inline proc(p: ^Parser) -> i64 { return p.pos }
chunk_pos :: #force_inline proc(p: ^Parser) -> i64 { return p.pos - p.offset }

init_parser :: proc(size: u32) -> Parser {
	p := Parser{}
	p.pos    = 0
	p.offset = 0
	p.total_size = i64(size)
	p.intern = in_init(big_global_allocator)

	return p
}

get_next_event :: proc(p: ^Parser) -> (TempEvent, BinaryState) {
	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	header_sz := i64(size_of(u64))
	if real_pos(p) + header_sz > p.total_size {
		return TempEvent{}, .Finished
	}
	if i64(chunk_pos(p) + header_sz) > i64(len(p.data)) {
		return TempEvent{}, .PartialRead
	}

	type := (^spall.Event_Type)(raw_data(p.data[chunk_pos(p):]))^
	switch type {
	case .Begin:
		event_sz := i64(size_of(spall.Begin_Event))
		if real_pos(p) + event_sz > p.total_size {
			return TempEvent{}, .Finished
		}
		if i64(chunk_pos(p) + event_sz) > i64(len(p.data)) {
			return TempEvent{}, .PartialRead
		}
		event := (^spall.Begin_Event)(raw_data(p.data[chunk_pos(p):]))^

		event_tail := i64(event.name_len) + i64(event.args_len)
		if (real_pos(p) + event_sz + event_tail) > p.total_size {
			return TempEvent{}, .Finished
		}
		if i64(chunk_pos(p) + event_sz + event_tail) > i64(len(p.data)) {
			return TempEvent{}, .PartialRead
		}

		name := string(p.data[chunk_pos(p)+event_sz:chunk_pos(p)+event_sz+i64(event.name_len)])
		str := in_get(&p.intern, name)

		ev := TempEvent{
			type = .Begin,
			timestamp = event.time,
			thread_id = event.tid,
			process_id = event.pid,
			name = str,
		}

		p.pos += i64(event_sz) + i64(event.name_len) + i64(event.args_len)
		return ev, .EventRead
	case .End:
		event_sz := i64(size_of(spall.End_Event))
		if real_pos(p) + event_sz > p.total_size {
			return TempEvent{}, .Finished
		}
		if i64(chunk_pos(p) + event_sz) > i64(len(p.data)) {
			return TempEvent{}, .PartialRead
		}
		event := (^spall.End_Event)(raw_data(p.data[chunk_pos(p):]))^

		ev := TempEvent{
			type = .End,
			timestamp = event.time,
			thread_id = event.tid,
			process_id = event.pid,
		}
		
		p.pos += i64(event_sz)
		return ev, .EventRead
	case .StreamOver:          fallthrough; // @Todo
	case .Custom_Data:         fallthrough; // @Todo
	case .Instant:             fallthrough; // @Todo
	case .Overwrite_Timestamp: fallthrough; // @Todo

	case .Invalid: fallthrough;
	case:
		fmt.printf("Unknown/invalid chunk (%v)\n", type)
		push_fatal(SpallError.InvalidFile)
	}

	return TempEvent{}, .PartialRead
}

load_binary_chunk :: proc(p: ^Parser, start, total_size: u32, chunk: []u8) {
	set_next_chunk(p, start, chunk)
	hot_loop: for {
		event, state := get_next_event(p)

		#partial switch state {
		case .PartialRead:
			p.offset = p.pos
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
			return
		case .Finished:
			finish_loading()
			return
		}

		#partial switch event.type {
		case .Begin:
			new_event := Event{
				name = event.name,
				duration = -1,
				self_time = -1,
				timestamp = (event.timestamp) * stamp_scale,
			}

			p_idx, t_idx, e_idx := bin_push_event(event.process_id, event.thread_id, new_event)
			thread := &processes[p_idx].threads[t_idx]
			queue.push_back(&thread.bande_q, e_idx)

			event_count += 1
		case .End:
			p_idx, ok1 := vh_find(&process_map, event.process_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}
			t_idx, ok2 := vh_find(&processes[p_idx].thread_map, event.thread_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}

			thread := &processes[p_idx].threads[t_idx]
			if queue.len(thread.bande_q) > 0 {
				e_idx := queue.pop_back(&thread.bande_q)

				thread.current_depth -= 1
				depth := &thread.depths[thread.current_depth]
				jev := &depth.bs_events[e_idx]
				jev.duration = (event.timestamp * stamp_scale) - jev.timestamp
				jev.self_time = jev.duration
				thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
				total_max_time = max(total_max_time, jev.timestamp + jev.duration)
			} else {
				fmt.printf("Got unexpected end event! [pid: %d, tid: %d, ts: %f]\n", event.process_id, event.thread_id, event.timestamp)
			}
		}
	}
}

bin_push_event :: proc(process_id, thread_id: u32, event: Event) -> (int, int, int) {
	p_idx, ok1 := vh_find(&process_map, process_id)
	if !ok1 {
		append(&processes, init_process(process_id))
		p_idx = len(processes) - 1
		vh_insert(&process_map, process_id, p_idx)
	}

	t_idx, ok2 := vh_find(&processes[p_idx].thread_map, thread_id)
	if !ok2 {
		threads := &processes[p_idx].threads
		append(threads, init_thread(thread_id))

		t_idx = len(threads) - 1
		thread_map := &processes[p_idx].thread_map
		vh_insert(thread_map, thread_id, t_idx)
	}

	p := &processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)
	t.max_time = max(t.max_time, event.timestamp + event.duration)

	total_min_time = min(total_min_time, event.timestamp)
	total_max_time = max(total_max_time, event.timestamp + event.duration)

	if int(t.current_depth) >= len(t.depths) {
		depth := Depth{
			bs_events = make([dynamic]Event, big_global_allocator)
		}
		append(&t.depths, depth)
	}

	depth := &t.depths[t.current_depth]
	t.current_depth += 1
	append_event(&depth.bs_events, event)

	return p_idx, t_idx, len(depth.bs_events)-1
}

bin_process_events :: proc() {
	ev_stack: queue.Queue(int)
	queue.init(&ev_stack, 0, context.temp_allocator)

	for process in &processes {
		slice.sort_by(process.threads[:], tid_sort_proc)
		for tm in &process.threads {
			for depth in &tm.depths {
				depth.events = depth.bs_events[:]
			}
		}
	}

	slice.sort_by(processes[:], pid_sort_proc)
	return
}
