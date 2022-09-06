package main

import "core:mem"
import "core:fmt"
import "core:unicode/utf8"
import "core:strconv"
import "core:strings"
import "core:container/queue"

// This is barely JSMN anymore, but it was definitely a strong reference
/*
 * MIT License
 *
 * Copyright (c) 2010 Serge Zaitsev
 *
 * Permission is hereby granted, free of charge, to any person obtaining a copy
 * of this software and associated documentation files (the "Software"), to deal
 * in the Software without restriction, including without limitation the rights
 * to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
 * copies of the Software, and to permit persons to whom the Software is
 * furnished to do so, subject to the following conditions:
 *
 * The above copyright notice and this permission notice shall be included in
 * all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
 * IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
 * FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
 * AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
 * LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
 * OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
 * SOFTWARE.
 */

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
		case:
		}

		if ch < 32 || ch >= 127 {
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
			switch p.data[chunk_pos(p)] {
			case '\"': fallthrough
			case '/': fallthrough
			case '\\': fallthrough
			case 'b': fallthrough
			case 'f': fallthrough
			case 'r': fallthrough
			case 'n': fallthrough
			case 't':

			case 'u':
				p.pos += 1
				for i := 0; i < 4 && chunk_pos(p) < u32(len(p.data)); i += 1 {
					if (!((p.data[chunk_pos(p)] >= 48 && p.data[chunk_pos(p)] <= 57) ||
					   (p.data[chunk_pos(p)] >= 65 && p.data[chunk_pos(p)] <= 70) ||
					   (p.data[chunk_pos(p)] >= 97 && p.data[chunk_pos(p)] <= 102))) {
						p.pos = start
						fmt.printf("Failed to parse token! 3\n")

						return
					}
					p.pos += 1
				}
				p.pos -= 1
			case:
				p.pos = start
				fmt.printf("Failed to parse token! 4\n")

				return
			}
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
		if p.pos == p.total_size {
			fmt.printf("unexpected leftovers?\n")
			return
		} else {
			state = .PartialRead
			return
		}
	}

	state = .Finished
	return
}
