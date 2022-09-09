package main

import "core:strings"

BinaryState :: enum {
	PartialRead,
	Finished,
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

get_next_event :: proc(p: ^Parser) -> (Event, BinaryState) {
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
	}
}
