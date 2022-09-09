package main

import "core:fmt"
import "core:strings"
import "core:container/queue"

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
	cur_event: Event,
}

BinEventType :: enum u64 {
	Begin,
	End,
}
BinHeader :: struct #packed {
	magic: u64,
	version: u64,
	timestamp_unit: f64,
}
BeginEvent :: struct #packed {
	type: BinEventType,
	pid: u64,
	tid: u64,
	time: f64,
	name_len: u8,
}
EndEvent :: struct #packed {
	type: BinEventType,
	pid: u64,
	tid: u64,
	time: f64,
}

real_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos }
chunk_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos - p.offset }

init_parser :: proc(size: u32) -> Parser {
	p := Parser{}
	p.pos    = 0
	p.offset = 0
	p.total_size = size
	p.cur_event = Event{}
	strings.intern_init(&p.intern)

	return p
}

get_next_event :: proc(p: ^Parser) -> (Event, BinaryState) {
	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	b := p.data[chunk_pos(p):]

	header_sz := u32(size_of(u64))
	if real_pos(p) + header_sz > p.total_size {
		return Event{}, .Finished
	}
	if int(chunk_pos(p) + header_sz) > len(p.data) {
		return Event{}, .PartialRead
	}

	type := (^BinEventType)(raw_data(p.data[chunk_pos(p):]))^
	switch type {
	case .Begin:
		event_sz := u32(size_of(BeginEvent))
		if real_pos(p) + event_sz > p.total_size {
			return Event{}, .Finished
		}
		if int(chunk_pos(p) + event_sz) > len(p.data) {
			return Event{}, .PartialRead
		}
		event := (^BeginEvent)(raw_data(p.data[chunk_pos(p):]))^

		if (real_pos(p) + event_sz + u32(event.name_len)) > p.total_size {
			return Event{}, .Finished
		}
		if int(chunk_pos(p) + event_sz + u32(event.name_len)) > len(p.data) {
			return Event{}, .PartialRead
		}

		name := string(p.data[chunk_pos(p)+event_sz:chunk_pos(p)+event_sz+u32(event.name_len)])
		str, err := strings.intern_get(&p.intern, name)
		if err != nil {
			trap()
		}

		ev := Event{
			type = .Begin,
			timestamp = event.time,
			thread_id = event.tid,
			process_id = event.pid,
			name = str,
		}

		p.pos += u32(event_sz) + u32(event.name_len)
		return ev, .EventRead
	case .End:
		event_sz := u32(size_of(EndEvent))
		if real_pos(p) + event_sz > p.total_size {
			return Event{}, .Finished
		}
		if int(chunk_pos(p) + event_sz) > len(p.data) {
			return Event{}, .PartialRead
		}
		event := (^EndEvent)(raw_data(p.data[chunk_pos(p):]))^

		ev := Event{
			type = .End,
			timestamp = event.time,
			thread_id = event.tid,
			process_id = event.pid,
		}
		
		p.pos += u32(event_sz)
		return ev, .EventRead
	case:
		trap()
	}

	return Event{}, .PartialRead
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
			tm, ok1 := &bande_p_to_t[event.process_id]
			if !ok1 {
				bande_p_to_t[event.process_id] = make(ThreadMap, 0, scratch_allocator)
				tm = &bande_p_to_t[event.process_id]
			}

			ts, ok2 := tm[event.thread_id]
			if !ok2 {
				event_stack := new(queue.Queue(Event), scratch_allocator)
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
							name = ev.name,
							type = .Complete,
							duration = event.timestamp - ev.timestamp,
							timestamp = ev.timestamp,
							thread_id = ev.thread_id,
							process_id = ev.process_id,
						}

						event_count += 1
						push_event(&processes, new_event)
					}
				}
			}
		}
	}
}
