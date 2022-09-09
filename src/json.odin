package main

import "core:fmt"
import "core:strings"
import "core:container/queue"

JSONState :: enum {
	InvalidToken,
	PartialRead,
	Finished,

	ScopeEntered,
	ScopeExited,
	TokenDone,
}

TokenType :: enum {
	Nil       = 0,
	Object    = 1,
	Array     = 2,
	String    = 4,
	Primitive = 8,
}

Token :: struct {
	type: TokenType,
	start: i64,
	end: i64,
	id: int,
}

IdPair :: struct {
	key: string,
	id: int,
}

JSONParser :: struct {
	p: Parser,

	parent_stack: queue.Queue(Token),
	tok_count: int,

	// Event parsing state
	events_id: int,
	cur_event_id: int,
	obj_map: map[string]string,
	cur_event: Event,
	seen_dur: bool,
	current_parent: IdPair,
}

fields := []string{ "dur", "name", "pid", "tid", "ts", "ph" }

init_token :: proc(p: ^JSONParser, type: TokenType, start, end: i64) -> Token {
	tok := Token{}
	tok.type = type
	tok.start = start
	tok.end = end
	tok.id = p.tok_count
	p.tok_count += 1

	return tok
}

pop_wrap :: #force_inline proc(p: ^JSONParser, loc := #caller_location) -> Token {
	tok := queue.pop_back(&p.parent_stack)
/*
	fmt.printf("Popped: %#v || %s ----------\n", tok, loc)
	print_queue(&p.parent_stack)
	fmt.printf("-----------\n")
*/
	return tok
}

push_wrap :: #force_inline proc(p: ^JSONParser, tok: Token, loc := #caller_location) {
	queue.push_back(&p.parent_stack, tok)

/*
	fmt.printf("Pushed: %#v || %s -----------\n", tok, loc)
	print_queue(&p.parent_stack)
	fmt.printf("-----------\n")
*/
}

get_token_str :: proc(p: ^JSONParser, tok: Token) -> string {
	str := string(p.p.full_chunk[u32(tok.start)-p.p.chunk_start:u32(tok.end)-p.p.chunk_start])
	return str
}

parse_primitive :: proc(jp: ^JSONParser) -> (token: Token, state: JSONState) {
	p := &jp.p

	start := real_pos(p)

	found := false
	top_loop: for ; chunk_pos(p) < u32(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		switch ch {
		case ':': fallthrough
		case '\t': fallthrough
		case '\r': fallthrough
		case '\n': fallthrough
		case ' ': fallthrough
		case ',': fallthrough
		case ']': fallthrough
		case '}':
			found = true
			break top_loop
		case ' '..='~':
		case:
			p.pos = start

			fmt.printf("Failed to parse token! 1\n")
			return
		}
	}

	if !found {
		p.pos = start
		state = .PartialRead
		return
	}

	token = init_token(jp, .Primitive, i64(start), i64(real_pos(p)))
	p.pos -= 1

	state = .TokenDone
	return
}


parse_string :: proc(jp: ^JSONParser) -> (token: Token, state: JSONState) {
	p := &jp.p

	start := real_pos(p)
	p.pos += 1

	for ; chunk_pos(p) < u32(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		if ch == '\"' {
			token = init_token(jp, .String, i64(start + 1), i64(real_pos(p)))
			state = .TokenDone
			return
		}

		if ch == '\\' && (chunk_pos(p) + 1) < u32(len(p.data)) {
			p.pos += 1
		}
	}

	p.pos = start
	state = .PartialRead
	return
}

init_json_parser :: proc(total_size: u32) -> JSONParser {
	p := JSONParser{}
	p.p = init_parser(total_size)
	queue.init(&p.parent_stack)

	p.obj_map = make(map[string]string, 0, scratch_allocator)
	for field in fields {
		p.obj_map[field] = field
	}

	p.cur_event = Event{}
	p.events_id    = -1
	p.cur_event_id = -1
	p.seen_dur = false
	p.current_parent = IdPair{}

	return p
}

get_next_token :: proc(jp: ^JSONParser) -> (token: Token, state: JSONState) {
	p := &jp.p

	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	for ; chunk_pos(p) < u32(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		switch ch {
		case '{': fallthrough
		case '[':
			type := (ch == '{') ? TokenType.Object : TokenType.Array
			token = init_token(jp, type, i64(real_pos(p)), -1)
			push_wrap(jp, token)

			p.pos += 1
			state = .ScopeEntered
			return
		case '}': fallthrough
		case ']':
			type := (ch == '}') ? TokenType.Object : TokenType.Array

			depth := queue.len(jp.parent_stack)
			if depth == 0 {
				fmt.printf("Expected first {{, got %c\n", ch)
				return
			}

			loop: for {
				token = pop_wrap(jp)
				if token.start != -1 && token.end == -1 {
					if token.type != type {
						fmt.printf("Got an unexpected scope close? Got %s, expected %s\n", token.type, type)
						return
					}

					token.end = i64(real_pos(p) + 1)
					p.pos += 1
					state = .ScopeExited
					return
				}

				depth = queue.len(jp.parent_stack)
				if depth == 0 {
					fmt.printf("unable to find closing %c\n", type)
					return
				}
			}

			fmt.printf("how am I here?\n")
			return
		// spaces are nops
		case '\t': fallthrough
		case '\r': fallthrough
		case '\n': fallthrough
		case ' ':
		case ':':
		case ',':
			depth := queue.len(jp.parent_stack)
			if depth == 0 {
				fmt.printf("Expected first {{, got %c\n", ch)
				return
			}
			parent := queue.peek_back(&jp.parent_stack)

			if parent.type != .Array && parent.type != .Object {
				pop_wrap(jp)
			}
		case '\"':
			token, state = parse_string(jp)
			if state != .TokenDone {
				return
			}

			parent := queue.peek_back(&jp.parent_stack)
			if parent.type == .Object {
				push_wrap(jp, token)
			}

			p.pos += 1
			return

		case '-': fallthrough
		case '0'..='9': fallthrough
		case 't': fallthrough
		case 'f': fallthrough
		case 'n':
			token, state = parse_primitive(jp)
			if state != .TokenDone {
				return
			}

			p.pos += 1
			return
		case:

			fmt.printf("Oops, I did a bad? '%c':%d %s\n", ch, chunk_pos(p), p.data)
			return
		}
	}

	depth := queue.len(jp.parent_stack)
	if depth != 0 {
		if p.pos != p.total_size {
			state = .PartialRead
			return
		}
	}

	state = .Finished
	return
}
