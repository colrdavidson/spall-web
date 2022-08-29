package main

import "core:mem"
import "core:fmt"
import "core:unicode/utf8"
import "core:strconv"
import "core:strings"

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

JSONError :: enum {
	Success,
	InvalidToken,
	PartialRead,
}

TokenType :: enum u8 {
	Nil       = 0,
	Object    = 1,
	Array     = 2,
	String    = 4,
	Primitive = 8,
}

Token :: struct #packed {
	type: TokenType,
	start: i32,
	end: i32,
	children: i32,
	parent: i32,

	s: string,
}

Parser :: struct {
	pos: int,
	super: int,
	offset: int,

	tokens: [dynamic]Token,
	data: string,
	intern: strings.Intern,
	total_size: int,
}

alloc_token :: proc(p: ^Parser) -> ^Token {
	append(&p.tokens, Token{})
	tok := &p.tokens[len(p.tokens)-1]

	tok.start = -1
	tok.end = -1
	tok.parent = -1
	tok.children = 0
	return tok
}

fill_token :: proc(p: ^Parser, token: ^Token, type: TokenType, start, end, parent: int) {
	token.type = type
	if type == .String || type == .Primitive {
		str, err := strings.intern_get(&p.intern, p.data[start-p.offset:end-p.offset])
		assert(err == nil)

		token.s = str
	}

	token.start = i32(start)
	token.end = i32(end)
	token.parent = i32(parent)
	token.children = 0
}

label_to_string :: proc(token: ^Token, data: string) -> string {
	return string(data[token.start:token.end])
}

key_eq :: proc(token: ^Token, data, key: string) -> bool {
	tok_str := label_to_string(token, data)
	return (token.type == .String) && (strings.compare(tok_str, key) == 0)
}

count_children :: proc(idx: int, tokens: []Token) -> int {
	token := &tokens[idx]

	off := 1
	#partial switch token.type {
	case .Object:
		for i := 0; i < int(token.children); i += 1 {
			off += count_children(idx + off, tokens)
			off += count_children(idx + off, tokens)
		}
	case .Array:
		for i := 0; i < int(token.children); i += 1 {
			off += count_children(idx + off, tokens)
		}
	}
	return off
}

map_object :: proc(idx: int, tokens: []Token, obj: ^map[string]int) -> int {
	token := &tokens[idx]
	assert(token.type == .Object)

	cur_idx := idx + 1
	for i := 0; i < int(token.children); i += 1 {
		cur_token := &tokens[cur_idx]
		key := cur_token.s; cur_idx += 1

		obj[key] = cur_idx
		cur_idx += count_children(cur_idx, tokens)
	}

	return cur_idx
}

get_i64 :: proc(key: string, tokens: []Token, obj: ^map[string]int) -> (val: i64, ok: bool) {
	idx := obj[key] or_return
	tok := &tokens[idx]
	if tok.type != .Primitive {
		return 0, false
	}

	val = strconv.parse_i64(tok.s) or_return

	return val, true
}

get_string :: proc(key: string, tokens: []Token, obj: ^map[string]int) -> (val: string, ok: bool) {
	idx := obj[key] or_return
	tok := &tokens[idx]
	if tok.type != .String {
		return "", false
	}

	return tok.s, true
}

print_token :: proc(idx: int, tokens: []Token, depth := 0) -> int {
	token := &tokens[idx]

	off := 1
	switch token.type {
	case .Nil:
		fmt.printf("(nil)")
	case .String:
		fmt.printf("\"%s\"", token.s)
	case .Primitive:
		fmt.printf("%s", token.s)
	case .Object:
		fmt.printf("{{")

		for i := 0; i < int(token.children); i += 1 {
			off += print_token(idx + off, tokens, depth + 1)
			fmt.printf(": ")
			off += print_token(idx + off, tokens, depth + 1)

			if (i + 1) < int(token.children) {
				fmt.printf(", ")
			}
		}

		fmt.printf("}}")
	case .Array:
		fmt.printf("[")

		for i := 0; i < int(token.children); i += 1 {
			off += print_token(idx + off, tokens, depth + 1)
			if (i + 1) < int(token.children) {
				fmt.printf(", ")
			}
		}

		fmt.printf("]")
	}

	if depth == 0 {
		fmt.printf("\n")
	}

	return off
}

real_pos :: proc(p: ^Parser) -> int { return p.pos }
chunk_pos :: proc(p: ^Parser) -> int { return p.pos - p.offset }

parse_primitive :: proc(p: ^Parser, data: string) -> JSONError {
	start := real_pos(p)

	found := false
	top_loop: for ; chunk_pos(p) < len(data); p.pos += 1 {
		ch := data[chunk_pos(p)]

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
			return .InvalidToken
		}
	}

	if !found {
		p.pos = start
		return .PartialRead
	}

	token := alloc_token(p)
	fill_token(p, token, .Primitive, start, real_pos(p), p.super)
	p.pos -= 1
	return .Success
}


parse_string :: proc(p: ^Parser, data: string) -> JSONError {
	start := real_pos(p)
	p.pos += 1

	for ; chunk_pos(p) < len(data); p.pos += 1 {
		ch := data[chunk_pos(p)]

		if ch == '\"' {
			token := alloc_token(p)
			fill_token(p, token, .String, start + 1, real_pos(p), p.super)
			return .Success
		}

		if ch == '\\' && (chunk_pos(p) + 1) < len(data) {
			p.pos += 1
			switch data[chunk_pos(p)] {
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
				for i := 0; i < 4 && chunk_pos(p) < len(data); i += 1 {
					if (!((data[chunk_pos(p)] >= 48 && data[chunk_pos(p)] <= 57) ||
					   (data[chunk_pos(p)] >= 65 && data[p.pos] <= 70) ||
					   (data[chunk_pos(p)] >= 97 && data[chunk_pos(p)] <= 102))) {
						p.pos = start
						fmt.printf("Failed to parse token! 3\n")
						return .InvalidToken
					}
					p.pos += 1
				}
				p.pos -= 1
			case:
				p.pos = start
				fmt.printf("Failed to parse token! 4\n")
				return .InvalidToken
			}
		}
	}

	p.pos = start
	return .PartialRead
}

init_parser :: proc(total_size: int) -> Parser {
	p := Parser{}
	p.tokens = make([dynamic]Token)
	p.pos    = 0
	p.super  = -1
	p.offset = 0
	p.total_size = total_size

	strings.intern_init(&p.intern)

	return p
}

parse_json :: proc(p: ^Parser, data: string, offset: int) -> JSONError {
	p.offset = offset
	p.data = data

	token: ^Token
	for ; chunk_pos(p) < len(data); p.pos += 1 {

		ch := data[chunk_pos(p)]

		switch ch {
		case '{': fallthrough
		case '[':
			token = alloc_token(p)

			if p.super != -1 {
				parent := &p.tokens[p.super]
				if parent.type == .Object {
					fmt.printf("Expected token Array parent, got %s\n", parent.type)
					fmt.printf("token: %#v, parent %#v\n", token, parent)
					return .InvalidToken
				}
				parent.children += 1
				token.parent = i32(p.super)
			}
			token.type = (ch == '{') ? TokenType.Object : TokenType.Array
			token.start = i32(real_pos(p))
			p.super = len(p.tokens) - 1
		case '}': fallthrough
		case ']':
			type := (ch == '}') ? TokenType.Object : TokenType.Array
			if len(p.tokens) < 1 {
				fmt.printf("Failed to parse token! 7\n")
				return .InvalidToken
			}
			token = &p.tokens[len(p.tokens) - 1]
			inner_loop: for {
				if token.start != -1 && token.end == -1 {
					if token.type != type {
						fmt.printf("Failed to parse token! 8\n")
						return .InvalidToken
					}
					token.end = i32(real_pos(p) + 1)
					p.super = int(token.parent)
					break inner_loop
				}

				if token.parent == -1 {
					if token.type != type || p.super == -1 {
						fmt.printf("Failed to parse token! 9\n")
						return .InvalidToken
					}
					break inner_loop
				}

				token = &p.tokens[token.parent]
			}
		case '\"':
			err := parse_string(p, data)
			if err != nil {
				return err
			}

			if p.super != -1 {
				p.tokens[p.super].children += 1
			}
		case '\t': fallthrough
		case '\r': fallthrough
		case '\n': fallthrough
		case ' ':
		case ':':
			p.super = len(p.tokens) - 1
		case ',':
			if p.super != -1 &&
			   p.tokens[p.super].type != .Array &&
			   p.tokens[p.super].type != .Object {
				p.super = int(p.tokens[p.super].parent)
			}
		case '-': fallthrough
		case '0'..='9': fallthrough
		case 't': fallthrough
		case 'f': fallthrough
		case 'n':
			if p.super != -1 {
				parent := &p.tokens[p.super]
				if parent.type == .Object || (parent.type == .String && parent.children != 0) {
					fmt.printf("Failed to parse token! 11\n")
					return .InvalidToken
				}
			}

			err := parse_primitive(p, data)
			if err != nil {
				return err
			}

			if p.super != -1 {
				p.tokens[p.super].children += 1
			}
		case:
			fmt.printf("Failed to parse token! 13\n")
			return .InvalidToken
		}
	}

	for i := len(p.tokens) - 1; i >= 0; i -= 1 {
		if p.tokens[i].start != -1 && p.tokens[i].end == -1 {
			return .PartialRead
		}
	}

	return .Success
}
