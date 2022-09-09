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

Parser :: struct {
	pos: u32,
	offset: u32,

	parent_stack: queue.Queue(Token),
	data: []u8,
	full_chunk: []u8,
	chunk_start: u32,
	total_size: u32,
	tok_count: int,

	intern: strings.Intern,
}

init_token :: proc(p: ^Parser, type: TokenType, start, end: i64) -> Token {
	tok := Token{}
	tok.type = type
	tok.start = start
	tok.end = end
	tok.id = p.tok_count
	p.tok_count += 1

	return tok
}

real_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos }
chunk_pos :: #force_inline proc(p: ^Parser) -> u32 { return p.pos - p.offset }

pop_wrap :: #force_inline proc(p: ^Parser, loc := #caller_location) -> Token {
	tok := queue.pop_back(&p.parent_stack)
/*
	fmt.printf("Popped: %#v || %s ----------\n", tok, loc)
	print_queue(&p.parent_stack)
	fmt.printf("-----------\n")
*/
	return tok
}

push_wrap :: #force_inline proc(p: ^Parser, tok: Token, loc := #caller_location) {
	queue.push_back(&p.parent_stack, tok)

/*
	fmt.printf("Pushed: %#v || %s -----------\n", tok, loc)
	print_queue(&p.parent_stack)
	fmt.printf("-----------\n")
*/
}

parse_primitive :: proc(p: ^Parser) -> (token: Token, state: JSONState) {
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

	token = init_token(p, .Primitive, i64(start), i64(real_pos(p)))
	p.pos -= 1

	state = .TokenDone
	return
}


parse_string :: proc(p: ^Parser) -> (token: Token, state: JSONState) {
	start := real_pos(p)
	p.pos += 1

	for ; chunk_pos(p) < u32(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		if ch == '\"' {
			token = init_token(p, .String, i64(start + 1), i64(real_pos(p)))
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


init_parser :: proc(total_size: u32) -> Parser {
	p := Parser{}
	p.pos    = 0
	p.offset = 0
	p.total_size = total_size
	queue.init(&p.parent_stack)
	strings.intern_init(&p.intern)

	return p
}

set_next_chunk :: proc(p: ^Parser, start: u32, chunk: []u8) {
	p.chunk_start = start
	p.full_chunk = chunk
}

get_next_token :: proc(p: ^Parser) -> (token: Token, state: JSONState) {
	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	for ; chunk_pos(p) < u32(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		switch ch {
		case '{': fallthrough
		case '[':
			type := (ch == '{') ? TokenType.Object : TokenType.Array
			token = init_token(p, type, i64(real_pos(p)), -1)
			push_wrap(p, token)

			p.pos += 1
			state = .ScopeEntered
			return
		case '}': fallthrough
		case ']':
			type := (ch == '}') ? TokenType.Object : TokenType.Array

			depth := queue.len(p.parent_stack)
			if depth == 0 {
				fmt.printf("Expected first {{, got %c\n", ch)
				return
			}

			loop: for {
				token = pop_wrap(p)
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

				depth = queue.len(p.parent_stack)
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
			depth := queue.len(p.parent_stack)
			if depth == 0 {
				fmt.printf("Expected first {{, got %c\n", ch)
				return
			}
			parent := queue.peek_back(&p.parent_stack)

			if parent.type != .Array && parent.type != .Object {
				pop_wrap(p)
			}
		case '\"':
			token, state = parse_string(p)
			if state != .TokenDone {
				return
			}

			parent := queue.peek_back(&p.parent_stack)
			if parent.type == .Object {
				push_wrap(p, token)
			}

			p.pos += 1
			return

		case '-': fallthrough
		case '0'..='9': fallthrough
		case 't': fallthrough
		case 'f': fallthrough
		case 'n':
			token, state = parse_primitive(p)
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

	depth := queue.len(p.parent_stack)
	if depth != 0 {
		if p.pos != p.total_size {
			state = .PartialRead
			return
		}
	}

	state = .Finished
	return
}
