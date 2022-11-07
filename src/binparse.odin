package main

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:mem"
import "formats:spall"

BinaryState :: enum {
	PartialRead,
	EventRead,
	Finished,
	Failure,
}

Parser :: struct {
	pos: i64,
	offset: i64,
	total_size: u32,

	intern: INMap,
}

real_pos :: #force_inline proc() -> i64 { return bp.pos }
chunk_pos :: #force_inline proc() -> i64 { return bp.pos - bp.offset }

init_parser :: proc(total_size: u32) -> Parser {
	p := Parser{total_size = total_size}
	p.intern = in_init(big_global_allocator)
	return p
}

setup_pid :: proc(process_id: u32) -> int {
	p_idx, ok := vh_find(&process_map, process_id)
	if !ok {
		append(&processes, init_process(process_id))
		p_idx = len(processes) - 1
		vh_insert(&process_map, process_id, p_idx)
	}

	return p_idx
}

setup_tid :: proc(p_idx: int, thread_id: u32) -> int {
	t_idx, ok := vh_find(&processes[p_idx].thread_map, thread_id)
	if !ok {
		threads := &processes[p_idx].threads

		append(threads, init_thread(thread_id))

		t_idx = len(threads) - 1
		thread_map := &processes[p_idx].thread_map
		vh_insert(thread_map, thread_id, t_idx)
	}

	return t_idx
}

get_next_event :: proc(chunk: []u8, temp_ev: ^TempEvent) -> BinaryState {

	header_sz := i64(size_of(u64))
	if chunk_pos() + header_sz > i64(len(chunk)) {
		return .PartialRead
	}

	data_start := chunk[chunk_pos():]
	type := (^spall.Event_Type)(raw_data(data_start))^
	#partial switch type {
	case .Begin:
		event_sz := i64(size_of(spall.Begin_Event))
		if chunk_pos() + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall.Begin_Event)(raw_data(data_start))

		event_tail := i64(event.name_len) + i64(event.args_len)
		if (chunk_pos() + event_sz + event_tail) > i64(len(chunk)) {
			return .PartialRead
		}

		name := string(data_start[event_sz:event_sz+i64(event.name_len)])
		args := string(data_start[event_sz+i64(event.name_len):event_sz+i64(event.name_len)+i64(event.args_len)])

		temp_ev.type = .Begin
		temp_ev.timestamp = event.time
		temp_ev.thread_id = event.tid
		temp_ev.process_id = event.pid
		temp_ev.name = in_get(&bp.intern, name)
		temp_ev.args = in_get(&bp.intern, args)

		bp.pos += event_sz + event_tail
		return .EventRead
	case .End:
		event_sz := i64(size_of(spall.End_Event))
		if chunk_pos() + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall.End_Event)(raw_data(data_start))

		temp_ev.type = .End
		temp_ev.timestamp = event.time
		temp_ev.thread_id = event.tid
		temp_ev.process_id = event.pid
		
		bp.pos += event_sz
		return .EventRead
	case:
		return .Failure
	}

	return .PartialRead
}

load_binary_chunk :: proc(chunk: []u8) {
	temp_ev := TempEvent{}
	ev := Event{}

	full_chunk := chunk
	load_loop: for bp.pos < i64(bp.total_size) {
		mem.zero(&temp_ev, size_of(TempEvent))
		state := get_next_event(full_chunk, &temp_ev)

		#partial switch state {
		case .PartialRead:
			if bp.pos == last_read {
				fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", bp.pos, bp.total_size, i64(bp.total_size) - bp.pos)
				break load_loop
			} else {
				last_read = bp.pos
			}

			bp.offset = bp.pos
			get_chunk(f64(bp.pos), f64(CHUNK_SIZE))
			return
		case .Failure:
			push_fatal(SpallError.InvalidFile)
		}

		#partial switch temp_ev.type {
		case .Begin:
			ev.name = temp_ev.name
			ev.args = temp_ev.args
			ev.duration = -1
			ev.self_time = 0 
			ev.timestamp = temp_ev.timestamp * stamp_scale

			p_idx, t_idx, e_idx := bin_push_event(temp_ev.process_id, temp_ev.thread_id, &ev)

			thread := &processes[p_idx].threads[t_idx]
			stack_push_back(&thread.bande_q, EVData{idx = e_idx, depth = thread.current_depth - 1, self_time = 0})

			event_count += 1
		case .End:
			p_idx, ok1 := vh_find(&process_map, temp_ev.process_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}
			t_idx, ok2 := vh_find(&processes[p_idx].thread_map, temp_ev.thread_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}

			thread := &processes[p_idx].threads[t_idx]
			if thread.bande_q.len > 0 {
				jev_data := stack_pop_back(&thread.bande_q)
				thread.current_depth -= 1

				depth := &thread.depths[thread.current_depth]
				jev := &depth.bs_events[jev_data.idx]
				jev.duration = (temp_ev.timestamp * stamp_scale) - jev.timestamp
				jev.self_time = jev.duration - jev.self_time
				thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
				total_max_time = max(total_max_time, jev.timestamp + jev.duration)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[thread.current_depth - 1]
					parent_ev := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.bs_events[parent_ev.idx]

					pev.self_time += jev.duration
				}
			} else {
				fmt.printf("Got unexpected end event! [pid: %d, tid: %d, ts: %f]\n", temp_ev.process_id, temp_ev.thread_id, temp_ev.timestamp)
			}
		}
	}

	// cleanup unfinished events
	for process in &processes {
		for thread in &process.threads {
			for thread.bande_q.len > 0 {
				ev_data := stack_pop_back(&thread.bande_q)

				depth := &thread.depths[ev_data.depth]
				jev := &depth.bs_events[ev_data.idx]

				thread.max_time = max(thread.max_time, jev.timestamp)
				total_max_time = max(total_max_time, jev.timestamp)

				duration := bound_duration(jev, thread.max_time)
				jev.self_time = duration - jev.self_time
				jev.self_time = max(jev.self_time, 0)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[ev_data.depth - 1]
					parent_ev := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.bs_events[parent_ev.idx]
					pev.self_time += duration
					pev.self_time = max(pev.self_time, 0)
				}
			}
		}
	}

	finish_loading()
	return
}

bin_push_event :: proc(process_id, thread_id: u32, event: ^Event) -> (int, int, int) {
	p_idx := setup_pid(process_id)
	t_idx := setup_tid(p_idx, thread_id)

	p := &processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)

	if t.max_time > event.timestamp {
		fmt.printf("Woah, time-travel? You just had a begin event that started before a previous one; [pid: %d, tid: %d, name: %s]\n", 
			process_id, thread_id, in_getstr(event.name))
		push_fatal(SpallError.InvalidFile)
	}
	t.max_time = event.timestamp + event.duration

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
	append_event(&depth.bs_events, event^)

	return p_idx, t_idx, len(depth.bs_events)-1
}

bin_process_events :: proc() {
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
