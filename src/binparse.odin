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
	pos: u32,
	offset: u32,

	data: []u8,
	full_chunk: []u8,
	chunk_start: u32,
	total_size: u32,

	intern: strings.Intern,
}

real_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos }
chunk_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos - p.offset }

init_parser :: proc(size: u32) -> Parser {
	p := Parser{}
	p.pos    = 0
	p.offset = 0
	p.total_size = size
	strings.intern_init(&p.intern)

	return p
}

get_next_event :: proc(p: ^Parser) -> (TempEvent, BinaryState) {
	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	b := p.data[chunk_pos(p):]

	header_sz := u32(size_of(u64))
	if real_pos(p) + header_sz > p.total_size {
		return TempEvent{}, .Finished
	}
	if int(chunk_pos(p) + header_sz) > len(p.data) {
		return TempEvent{}, .PartialRead
	}

	type := (^spall.Event_Type)(raw_data(p.data[chunk_pos(p):]))^
	switch type {
	case .Begin:
		event_sz := u32(size_of(spall.Begin_Event))
		if real_pos(p) + event_sz > p.total_size {
			return TempEvent{}, .Finished
		}
		if int(chunk_pos(p) + event_sz) > len(p.data) {
			return TempEvent{}, .PartialRead
		}
		event := (^spall.Begin_Event)(raw_data(p.data[chunk_pos(p):]))^

		if (real_pos(p) + event_sz + u32(event.name_len)) > p.total_size {
			return TempEvent{}, .Finished
		}
		if int(chunk_pos(p) + event_sz + u32(event.name_len)) > len(p.data) {
			return TempEvent{}, .PartialRead
		}

		name := string(p.data[chunk_pos(p)+event_sz:chunk_pos(p)+event_sz+u32(event.name_len)])
		str, err := strings.intern_get(&p.intern, name)
		if err != nil {
			trap()
		}

		ev := TempEvent{
			type = .Begin,
			timestamp = event.time,
			thread_id = event.tid,
			process_id = event.pid,
			name = str,
		}

		p.pos += u32(event_sz) + u32(event.name_len)
		return ev, .EventRead
	case .End:
		event_sz := u32(size_of(spall.End_Event))
		if real_pos(p) + event_sz > p.total_size {
			return TempEvent{}, .Finished
		}
		if int(chunk_pos(p) + event_sz) > len(p.data) {
			return TempEvent{}, .PartialRead
		}
		event := (^spall.End_Event)(raw_data(p.data[chunk_pos(p):]))^

		ev := TempEvent{
			type = .End,
			timestamp = event.time,
			thread_id = event.tid,
			process_id = event.pid,
		}
		
		p.pos += u32(event_sz)
		return ev, .EventRead
	case .StreamOver:
		fmt.printf("Got what was formerly a Complete event. Delete the file you tried to load!!!\n@Todo: Remove this message when all the files are deleted, and start utilizing StreamOver.\n", type)
		trap()
	case .Custom_Data:         fallthrough; // @Todo
	case .Instant:             fallthrough; // @Todo
	case .Overwrite_Timestamp: fallthrough; // @Todo
	case .Update_Checksum:     fallthrough; // @Todo

	case .Invalid: fallthrough;
	case:
		fmt.printf("Unknown/invalid chunk (%v)\n", type)
		trap() // @Todo: Handle invalid chunks
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
			get_chunk(u32(p.pos), CHUNK_SIZE)
			return
		case .Finished:
			finish_loading(p)
			return
		}

		#partial switch event.type {
		case .Begin:
			new_event := Event{
				type = .Complete,
				name = event.name,
				duration = -1,
				timestamp = (event.timestamp) * stamp_scale,
			}

			event_count += 1
			p_idx, t_idx, e_idx := bin_push_event(&processes, event.process_id, event.thread_id, new_event)

			thread := &processes[p_idx].threads[t_idx]
			queue.push_back(&thread.bande_q, e_idx)
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
				jev_idx := queue.pop_back(&thread.bande_q)
				jev := &thread.events[jev_idx]
				jev.duration = (jp.cur_event.timestamp - jev.timestamp) * stamp_scale
				thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
				total_max_time = max(total_max_time, jev.timestamp + jev.duration)
			}
		}
	}
}

bin_push_event :: proc(processes: ^[dynamic]Process, process_id, thread_id: u32, event: Event) -> (int, int, int) {
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

	total_min_time = min(total_min_time, event.timestamp)
	total_max_time = max(total_max_time, event.timestamp + event.duration)

	append(&t.events, event)
	return p_idx, t_idx, len(t.events)-1
}

bin_process_events :: proc(processes: ^[dynamic]Process) {

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
				cur_end   := event.timestamp + bound_duration(event, tm.max_time)
				if queue.len(ev_stack) == 0 {
					queue.push_back(&ev_stack, e_idx)
				} else {
					prev_e_idx := queue.peek_back(&ev_stack)^
					prev_ev := tm.events[prev_e_idx]

					prev_start := prev_ev.timestamp
					prev_end   := prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

					// if it fits within the parent
					if cur_start >= prev_start && cur_end <= prev_end {
						queue.push_back(&ev_stack, e_idx)
					} else {

						// while it doesn't overlap the parent
						for queue.len(ev_stack) > 0 {
							prev_e_idx = queue.peek_back(&ev_stack)^
							prev_ev = tm.events[prev_e_idx]

							prev_start = prev_ev.timestamp
							prev_end   = prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

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
	return
}
