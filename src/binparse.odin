package main

import "core:strings"

BinaryState :: enum {
	PartialRead,
	Finished,
}

real_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos }
chunk_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos - p.offset }

get_next_event :: proc(p: ^Parser) -> (Event, BinaryState) {
	return Event{}, .PartialRead
}

init_parser :: proc(size: u32) -> Parser {
	p := Parser{}
	p.pos    = 0
	p.offset = 0
	p.total_size = size
	strings.intern_init(&p.intern)

	return p
}
