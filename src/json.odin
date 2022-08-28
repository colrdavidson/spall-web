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
	PartialToken,
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
	children: i16,
	parent: i32,
}

Parser :: struct {
	pos: i32,
	super: i32,
}

alloc_token :: proc(p: ^Parser, tokens: ^[dynamic]Token) -> ^Token {
	append(tokens, Token{})
	tok := &tokens[len(tokens)-1]

	tok.start = -1
	tok.end = -1
	tok.parent = -1
	tok.children = 0
	return tok
}

fill_token :: proc(token: ^Token, type: TokenType, start, end, parent: i32) {
	token.type = type
	token.start = start
	token.end = end
	token.parent = parent
	token.children = 0
}

label_to_string :: proc(token: ^Token, data: string) -> string {
	return string(data[token.start:token.end])
}

key_eq :: proc(token: ^Token, data, key: string) -> bool {
	tok_str := label_to_string(token, data)
	return (token.type == .String) && (strings.compare(tok_str, key) == 0)
}

count_children :: proc(idx: int, tokens: []Token, data: string) -> int {
	token := &tokens[idx]

	off := 1
	#partial switch token.type {
	case .Object:
		for i := 0; i < int(token.children); i += 1 {
			off += count_children(idx + off, tokens, data)
			off += count_children(idx + off, tokens, data)
		}
	case .Array:
		for i := 0; i < int(token.children); i += 1 {
			off += count_children(idx + off, tokens, data)
		}
	}
	return off
}

map_object :: proc(idx: int, tokens: []Token, data: string, obj: ^map[string]int) -> int {
	token := &tokens[idx]
	assert(token.type == .Object)

	cur_idx := idx + 1
	for i := 0; i < int(token.children); i += 1 {
		cur_token := &tokens[cur_idx]
		key := string(data[cur_token.start:cur_token.end]); cur_idx += 1

		obj[key] = cur_idx
		cur_idx += count_children(cur_idx, tokens, data)
	}

	return cur_idx
}

get_i64 :: proc(key: string, tokens: []Token, data: string, obj: ^map[string]int) -> (val: i64, ok: bool) {
	idx := obj[key] or_return
	tok := &tokens[idx]
	if tok.type != .Primitive {
		return 0, false
	}

	val_str := label_to_string(tok, data)
	val = strconv.parse_i64(val_str) or_return

	return val, true
}

get_string :: proc(key: string, tokens: []Token, data: string, obj: ^map[string]int) -> (val: string, ok: bool) {
	idx := obj[key] or_return
	tok := &tokens[idx]
	if tok.type != .String {
		return "", false
	}

	return label_to_string(tok, data), true
}

print_token :: proc(idx: int, tokens: []Token, data: string, depth := 0) -> int {
	token := &tokens[idx]

	off := 1
	switch token.type {
	case .Nil:
		fmt.printf("(nil)")
	case .String:
		fmt.printf("\"%s\"", label_to_string(token, data))
	case .Primitive:
		fmt.printf("%s", label_to_string(token, data))
	case .Object:
		fmt.printf("{{")

		for i := 0; i < int(token.children); i += 1 {
			off += print_token(idx + off, tokens, data, depth + 1)
			fmt.printf(": ")
			off += print_token(idx + off, tokens, data, depth + 1)

			if (i + 1) < int(token.children) {
				fmt.printf(", ")
			}
		}

		fmt.printf("}}")
	case .Array:
		fmt.printf("[")

		for i := 0; i < int(token.children); i += 1 {
			off += print_token(idx + off, tokens, data, depth + 1)
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

parse_primitive :: proc(p: ^Parser, data: string, tokens: ^[dynamic]Token) -> JSONError {
	start := p.pos

	found := false
	top_loop: for ; int(p.pos) < len(data); p.pos += 1 {
		ch := data[p.pos]

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
		fmt.printf("Failed to parse token! 2\n")
		return .PartialToken
	}

	token := alloc_token(p, tokens)
	fill_token(token, .Primitive, start, p.pos, p.super)
	p.pos -= 1
	return .Success
}

parse_string :: proc(p: ^Parser, data: string, tokens: ^[dynamic]Token) -> JSONError {

	start := p.pos
	p.pos += 1

	for ; int(p.pos) < len(data); p.pos += 1 {
		ch := data[p.pos]

		if ch == '\"' {
			token := alloc_token(p, tokens)
			fill_token(token, .String, start + 1, p.pos, p.super)
			return .Success
		}

		if ch == '\\' && int(p.pos + 1) < len(data) {
			p.pos += 1
			switch data[p.pos] {
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
				for i := 0; i < 4 && int(p.pos) < len(data); i += 1 {
					if (!((data[p.pos] >= 48 && data[p.pos] <= 57) ||
					   (data[p.pos] >= 65 && data[p.pos] <= 70) ||
					   (data[p.pos] >= 97 && data[p.pos] <= 102))) {
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
	fmt.printf("Failed to parse token! 5\n")
	return .PartialToken
}

parse_json :: proc(data: string) -> ([]Token, JSONError) {
	p := Parser{}
	tokens := make([dynamic]Token)

	p.pos    = 0
	p.super = -1

	token: ^Token
	for ; int(p.pos) < len(data); p.pos += 1 {
		ch := data[p.pos]

		switch ch {
		case '{': fallthrough
		case '[':
			token = alloc_token(&p, &tokens)

			if p.super != -1 {
				parent := &tokens[p.super]
				if parent.type == .Object {
					fmt.printf("Expected token Array parent, got %s\n", parent.type)
					fmt.printf("token: %#v, parent %#v\n", token, parent)
					return nil, .InvalidToken
				}
				parent.children += 1
				token.parent = p.super
			}
			token.type = (ch == '{') ? TokenType.Object : TokenType.Array
			token.start = p.pos
			p.super = i32(len(tokens) - 1)
		case '}': fallthrough
		case ']':
			type := (ch == '}') ? TokenType.Object : TokenType.Array
			if len(tokens) < 1 {
				fmt.printf("Failed to parse token! 7\n")
				return nil, .InvalidToken
			}
			token = &tokens[len(tokens) - 1]
			inner_loop: for {
				if token.start != -1 && token.end == -1 {
					if token.type != type {
						fmt.printf("Failed to parse token! 8\n")
						return nil, .InvalidToken
					}
					token.end = p.pos + 1
					p.super = token.parent
					break inner_loop
				}

				if token.parent == -1 {
					if token.type != type || p.super == -1 {
						fmt.printf("Failed to parse token! 9\n")
						return nil, .InvalidToken
					}
					break inner_loop
				}

				token = &tokens[token.parent]
			}
		case '\"':
			err := parse_string(&p, data, &tokens)
			if err != nil {
				fmt.printf("Failed to parse token! 10\n")
				return nil, .InvalidToken
			}
			if p.super != -1 {
				tokens[p.super].children += 1
			}
		case '\t': fallthrough
		case '\r': fallthrough
		case '\n': fallthrough
		case ' ':
		case ':':
			p.super = i32(len(tokens) - 1)
		case ',':
			if p.super != -1 &&
			   tokens[p.super].type != .Array &&
			   tokens[p.super].type != .Object {
				p.super = tokens[p.super].parent
			}
		case '-': fallthrough
		case '0'..='9': fallthrough
		case 't': fallthrough
		case 'f': fallthrough
		case 'n':
			if p.super != -1 {
				parent := &tokens[p.super]
				if parent.type == .Object || (parent.type == .String && parent.children != 0) {
					fmt.printf("Failed to parse token! 11\n")
					return nil, .InvalidToken
				}
			}

			err := parse_primitive(&p, data, &tokens)
			if err != nil {
				fmt.printf("Failed to parse token! 12\n")
				return nil, .InvalidToken
			}

			if p.super != -1 {
				tokens[p.super].children += 1
			}
		case:
			fmt.printf("Failed to parse token! 13\n")
			return nil, .InvalidToken
		}
	}

	for i := len(tokens) - 1; i >= 0; i -= 1 {
		if tokens[i].start != -1 && tokens[i].end == -1 {
			fmt.printf("Failed to parse token! 14\n")
			return nil, .PartialToken
		}
	}

	return tokens[:], .Success
}
