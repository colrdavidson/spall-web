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
}

real_pos :: #force_inline proc(p: ^Parser) -> i64 { return p.pos }
chunk_pos :: #force_inline proc(p: ^Parser) -> i64 { return p.pos - p.offset }

init_parser :: proc(total_size: u32) -> Parser {
	p := Parser{total_size = total_size}
	return p
}

ms_v1_get_next_event :: proc(trace: ^Trace, chunk: []u8, temp_ev: ^TempEvent) -> BinaryState {
	p := &trace.parser

	header_sz := i64(size_of(u64))
	if chunk_pos(p) + header_sz > i64(len(chunk)) {
		return .PartialRead
	}

	data_start := chunk[chunk_pos(p):]
	type := (^spall.Event_Type)(raw_data(data_start))^
	#partial switch type {
	case .Begin:
		event_sz := i64(size_of(spall.Begin_Event))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall.Begin_Event)(raw_data(data_start))

		event_tail := i64(event.name_len) + i64(event.args_len)
		if (chunk_pos(p) + event_sz + event_tail) > i64(len(chunk)) {
			return .PartialRead
		}

		name := string(data_start[event_sz:event_sz+i64(event.name_len)])
		args := string(data_start[event_sz+i64(event.name_len):event_sz+i64(event.name_len)+i64(event.args_len)])

		temp_ev.type = .Begin
		temp_ev.timestamp = i64(event.time)
		temp_ev.thread_id = event.tid
		temp_ev.process_id = event.pid
		temp_ev.name = in_get(&trace.intern, &trace.string_block, name)
		temp_ev.args = in_get(&trace.intern, &trace.string_block, args)

		p.pos += event_sz + event_tail
		return .EventRead
	case .End:
		event_sz := i64(size_of(spall.End_Event))
		if chunk_pos(p) + event_sz > i64(len(chunk)) {
			return .PartialRead
		}
		event := (^spall.End_Event)(raw_data(data_start))

		temp_ev.type = .End
		temp_ev.timestamp = i64(event.time)
		temp_ev.thread_id = event.tid
		temp_ev.process_id = event.pid
		
		p.pos += event_sz
		return .EventRead
	case:
		return .Failure
	}

	return .PartialRead
}

ms_v1_load_binary_chunk :: proc(trace: ^Trace, chunk: []u8) {
	p := &trace.parser

	temp_ev := TempEvent{}
	ev := Event{}

	full_chunk := chunk
	load_loop: for p.pos < i64(p.total_size) {
		mem.zero(&temp_ev, size_of(TempEvent))
		state := ms_v1_get_next_event(trace, full_chunk, &temp_ev)

		#partial switch state {
		case .PartialRead:
			if p.pos == last_read {
				fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", p.pos, p.total_size, i64(p.total_size) - p.pos)
				break load_loop
			} else {
				last_read = p.pos
			}

			p.offset = p.pos
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
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
			ev.timestamp = temp_ev.timestamp

			p_idx, t_idx, e_idx := ms_v1_bin_push_event(trace, temp_ev.process_id, temp_ev.thread_id, &ev)

			thread := &trace.processes[p_idx].threads[t_idx]
			stack_push_back(&thread.bande_q, EVData{idx = e_idx, depth = thread.current_depth - 1, self_time = 0})

			trace.event_count += 1
		case .End:
			p_idx, ok1 := vh_find(&trace.process_map, temp_ev.process_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}
			t_idx, ok2 := vh_find(&trace.processes[p_idx].thread_map, temp_ev.thread_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}

			thread := &trace.processes[p_idx].threads[t_idx]
			if thread.bande_q.len > 0 {
				jev_data := stack_pop_back(&thread.bande_q)
				thread.current_depth -= 1

				depth := &thread.depths[thread.current_depth]
				jev := &depth.events[jev_data.idx]
				jev.duration = temp_ev.timestamp - jev.timestamp
				jev.self_time = jev.duration - jev.self_time
				thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[thread.current_depth - 1]
					parent_ev := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev.idx]

					pev.self_time += jev.duration
				}
			} else {
				fmt.printf("Got unexpected end event! [pid: %d, tid: %d, ts: %v]\n", temp_ev.process_id, temp_ev.thread_id, temp_ev.timestamp)
			}
		}
	}

	// cleanup unfinished events
	for &process in trace.processes {
		for &thread in process.threads {
			for thread.bande_q.len > 0 {
				ev_data := stack_pop_back(&thread.bande_q)

				depth := &thread.depths[ev_data.depth]
				jev := &depth.events[ev_data.idx]

				thread.max_time = max(thread.max_time, jev.timestamp)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp)

				duration := bound_duration(jev, thread.max_time)
				jev.self_time = duration - jev.self_time
				jev.self_time = max(jev.self_time, 0)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[ev_data.depth - 1]
					parent_ev := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev.idx]
					pev.self_time += duration
					pev.self_time = max(pev.self_time, 0)
				}
			}
		}
	}

	finish_loading(trace)
	return
}

ms_v1_bin_push_event :: proc(trace: ^Trace, process_id, thread_id: u32, event: ^Event) -> (i32, i32, i32) {
	p_idx := setup_pid(trace, process_id)
	t_idx := setup_tid(trace, p_idx, thread_id)

	p := &trace.processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)

	if t.max_time > event.timestamp {
		fmt.printf("Woah, time-travel? You just had a begin event that started before a previous one; [pid: %d, tid: %d, name: %s]\n", 
			process_id, thread_id, in_getstr(&trace.string_block, event.name))
		push_fatal(SpallError.InvalidFile)
	}
	t.max_time = event.timestamp + event.duration

	trace.total_min_time = min(trace.total_min_time, event.timestamp)
	trace.total_max_time = max(trace.total_max_time, event.timestamp + event.duration)

	if int(t.current_depth) >= len(t.depths) {
		depth := Depth{
			events = make([dynamic]Event, big_global_allocator),
		}
		append(&t.depths, depth)
	}

	depth := &t.depths[t.current_depth]
	t.current_depth += 1
	append_event(&depth.events, event^)

	return p_idx, t_idx, i32(len(depth.events)-1)
}

ms_v1_bin_process_events :: proc(trace: ^Trace) {
	for &process in trace.processes {
		slice.sort_by(process.threads[:], tid_sort_proc)
	}

	slice.sort_by(trace.processes[:], pid_sort_proc)
	return
}

ms_v2_load_binary_chunk :: proc(trace: ^Trace, chunk: []u8) {
	p := &trace.parser
	temp_ev := TempEvent{}
	ev := Event{}

	full_chunk := chunk
	load_loop: for p.pos < i64(p.total_size) {
		mem.zero(&temp_ev, size_of(TempEvent))
		state := ms_v1_get_next_event(trace, full_chunk, &temp_ev)

		#partial switch state {
		case .PartialRead:
			if p.pos == last_read {
				fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", p.pos, p.total_size, i64(p.total_size) - p.pos)
				break load_loop
			} else {
				last_read = p.pos
			}

			p.offset = p.pos
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
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
			ev.timestamp = temp_ev.timestamp

			p_idx, t_idx, e_idx := ms_v1_bin_push_event(trace, temp_ev.process_id, temp_ev.thread_id, &ev)

			thread := &trace.processes[p_idx].threads[t_idx]
			stack_push_back(&thread.bande_q, EVData{idx = e_idx, depth = thread.current_depth - 1, self_time = 0})

			trace.event_count += 1
		case .End:
			p_idx, ok1 := vh_find(&trace.process_map, temp_ev.process_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}
			t_idx, ok2 := vh_find(&trace.processes[p_idx].thread_map, temp_ev.thread_id)
			if !ok1 {
				fmt.printf("invalid end?\n")
				continue
			}

			thread := &trace.processes[p_idx].threads[t_idx]
			if thread.bande_q.len > 0 {
				jev_data := stack_pop_back(&thread.bande_q)
				thread.current_depth -= 1

				depth := &thread.depths[thread.current_depth]
				jev := &depth.events[jev_data.idx]
				jev.duration = temp_ev.timestamp - jev.timestamp
				jev.self_time = jev.duration - jev.self_time
				thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[thread.current_depth - 1]
					parent_ev := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev.idx]

					pev.self_time += jev.duration
				}
			} else {
				fmt.printf("Got unexpected end event! [pid: %d, tid: %d, ts: %f]\n", temp_ev.process_id, temp_ev.thread_id, temp_ev.timestamp)
			}
		}
	}

	// cleanup unfinished events
	for &process in trace.processes {
		for &thread in process.threads {
			for thread.bande_q.len > 0 {
				ev_data := stack_pop_back(&thread.bande_q)

				depth := &thread.depths[ev_data.depth]
				jev := &depth.events[ev_data.idx]

				thread.max_time = max(thread.max_time, jev.timestamp)
				trace.total_max_time = max(trace.total_max_time, jev.timestamp)

				duration := bound_duration(jev, thread.max_time)
				jev.self_time = duration - jev.self_time
				jev.self_time = max(jev.self_time, 0)

				if thread.bande_q.len > 0 {
					parent_depth := &thread.depths[ev_data.depth - 1]
					parent_ev := stack_peek_back(&thread.bande_q)

					pev := &parent_depth.events[parent_ev.idx]
					pev.self_time += duration
					pev.self_time = max(pev.self_time, 0)
				}
			}
		}
	}

	finish_loading(trace)
	return
}
