package main

import "core:fmt"
import "core:strings"
import "core:container/queue"
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
	case .Complete:
		event_sz := u32(size_of(spall.Complete_Event))
		if real_pos(p) + event_sz > p.total_size {
			return TempEvent{}, .Finished
		}
		if int(chunk_pos(p) + event_sz) > len(p.data) {
			return TempEvent{}, .PartialRead
		}
		event := (^spall.Complete_Event)(raw_data(p.data[chunk_pos(p):]))^

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
			type = .Complete,
			timestamp = event.time,
			duration = event.duration,
			thread_id = event.tid,
			process_id = event.pid,
			name = str,
		}

		p.pos += u32(event_sz) + u32(event.name_len)
		return ev, .EventRead
	case .Instant: fallthrough; // @Todo
	case .StreamOver: fallthrough; // @Todo

	case .Invalid: fallthrough;
	case:
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
		case .Complete:
			new_event := Event{
				type = .Complete,
				name = event.name,
				duration = (event.duration) * stamp_scale,
				timestamp = (event.timestamp) * stamp_scale,
			}

			event_count += 1
			push_event(&processes, event.process_id, event.thread_id, new_event)
		case .Begin:
			tm, ok1 := &bande_p_to_t[event.process_id]
			if !ok1 {
				bande_p_to_t[event.process_id] = make(ThreadMap, 0, scratch_allocator)
				tm = &bande_p_to_t[event.process_id]
			}

			ts, ok2 := tm[event.thread_id]
			if !ok2 {
				event_stack := new(queue.Queue(TempEvent), scratch_allocator)
				queue.init(event_stack, 0, scratch_allocator)
				tm[event.thread_id] = event_stack
				ts = event_stack
			}

			queue.push_back(ts, event)
		case .End:
			if tm, ok1 := &bande_p_to_t[event.process_id]; ok1 {
				if ts, ok2 := tm[event.thread_id]; ok2 {
					if queue.len(ts^) > 0 {
						ev := queue.pop_back(ts)

						new_event := Event{
							type = .Complete,
							name = ev.name,
							duration = (event.timestamp - ev.timestamp) * stamp_scale,
							timestamp = (ev.timestamp) * stamp_scale,
						}

						event_count += 1
						push_event(&processes, event.process_id, event.thread_id, new_event)
					}
				}
			}
		}
	}
}
