package main

import "core:fmt"
import "core:strings"
import "core:container/queue"
import "core:strconv"

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
	cur_event: TempEvent,
	cur_event_id: int,
	obj_map: map[string]string,
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
	jp := JSONParser{}
	jp.p = init_parser(total_size)
	queue.init(&jp.parent_stack)

	jp.obj_map = make(map[string]string, 0, scratch_allocator)
	for field in fields {
		jp.obj_map[field] = field
	}

	jp.events_id    = -1
	jp.cur_event_id = -1
	jp.cur_event = TempEvent{}
	jp.seen_dur = false
	jp.current_parent = IdPair{}

	return jp
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

			fmt.printf("Oops, I did a bad? '%c':%d\n", ch, chunk_pos(p))
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

// this is gross + brittle. I'm sorry. I need a better way to do JSON streaming
load_json_chunk :: proc (jp: ^JSONParser, start, total_size: u32, chunk: []u8) {
	p := &jp.p
	set_next_chunk(p, start, chunk)
	hot_loop: for {
		tok, state := get_next_token(jp)

		#partial switch state {
		case .PartialRead:
			p.offset = p.pos
			get_chunk(u32(p.pos), CHUNK_SIZE)
			return
		case .InvalidToken:
			trap()
			return
		case .Finished:
			finish_loading(p)
			return
		}

		depth := queue.len(jp.parent_stack)

		// get start of traceEvents
		if jp.events_id == -1 {
			if state == .ScopeEntered && tok.type == .Array && depth == 1 {
				jp.events_id = tok.id
			} else if state == .ScopeEntered && tok.type == .Array && depth == 3 {
				parent := queue.get_ptr(&jp.parent_stack, depth - 2)
				if "traceEvents" == get_token_str(jp, parent^) {
					jp.events_id = tok.id
				}
			}
			continue
		}

		// get start of an event
		if jp.cur_event_id == -1 {
			if depth > 1 && state == .ScopeEntered && tok.type == .Object {
				parent := queue.get_ptr(&jp.parent_stack, depth - 2)
				if parent.id == jp.events_id {
					jp.cur_event_id = tok.id
				}
			}
			continue
		}

		// eww.
		parent := queue.get_ptr(&jp.parent_stack, depth - 1)
		if parent.id == tok.id {
			parent = queue.get_ptr(&jp.parent_stack, depth - 2)
		}

		// gather keys for event
		if state == .TokenDone && tok.type == .String && parent.id == jp.cur_event_id {
			key := get_token_str(jp, tok)
			val, ok := jp.obj_map[key]
			if ok {
				jp.current_parent = IdPair{val, tok.id}
			}
			continue
		}

		// gather values for event
		if state == .TokenDone &&
		   (tok.type == .String || tok.type == .Primitive) {
			if parent.id != jp.current_parent.id {
				continue
			}
			key := jp.current_parent.key

			value := get_token_str(jp, tok)
			if key == "name" {
				str, err := strings.intern_get(&p.intern, value)
				if err != nil {
					return
				}

				jp.cur_event.name = str
			}

			switch key {
			case "ph":
				if value == "X" {
					jp.cur_event.type = .Complete
				} else if value == "B" {
					jp.cur_event.type = .Begin
				} else if value == "E" {
					jp.cur_event.type = .End
				}
			case "dur": 
				dur, ok := strconv.parse_f64(value)
				if !ok { continue }
				jp.cur_event.duration = dur
				jp.seen_dur = true
			case "ts": 
				ts, ok := strconv.parse_f64(value)
				if !ok { continue }
				jp.cur_event.timestamp = ts
			case "tid": 
				tid, ok := strconv.parse_u64(value)
				if !ok { continue }
				jp.cur_event.thread_id = u32(tid)
			case "pid": 
				pid, ok := strconv.parse_u64(value)
				if !ok { continue }
				jp.cur_event.process_id = u32(pid)
			}

			continue
		}

		// got the whole event
		if state == .ScopeExited && tok.id == jp.cur_event_id {
			switch jp.cur_event.type {
			case .Complete:
				if jp.seen_dur {
					event_count += 1

					new_event := Event{
						type = .Complete,
						name = jp.cur_event.name,
						duration = jp.cur_event.duration,
						timestamp = jp.cur_event.timestamp,
					}
					push_event(&processes, jp.cur_event.process_id, jp.cur_event.thread_id, new_event)
				}
			case .Begin:
				tm, ok1 := &bande_p_to_t[jp.cur_event.process_id]
				if !ok1 {
					bande_p_to_t[jp.cur_event.process_id] = make(ThreadMap, 0, scratch_allocator)
					tm = &bande_p_to_t[jp.cur_event.process_id]
				}

				ts, ok2 := &tm[jp.cur_event.thread_id]
				if !ok2 {
					event_stack: queue.Queue(TempEvent)
					queue.init(&event_stack, 0, scratch_allocator)
					tm[jp.cur_event.thread_id] = event_stack
					ts = &tm[jp.cur_event.thread_id]
				}

				queue.push_back(ts, jp.cur_event)
			case .End:
				if tm, ok1 := &bande_p_to_t[jp.cur_event.process_id]; ok1 {
					if ts, ok2 := &tm[jp.cur_event.thread_id]; ok2 {
						if queue.len(ts^) > 0 {
							ev := queue.pop_back(ts)

							new_event := Event{
								type = .Complete,
								name = ev.name,
								duration = jp.cur_event.timestamp - ev.timestamp,
								timestamp = ev.timestamp,
							}

							event_count += 1
							push_event(&processes, ev.process_id, ev.thread_id, new_event)
						}
					}
				}
			}

			jp.cur_event = TempEvent{}
			jp.cur_event_id = -1
			jp.seen_dur = false
			jp.current_parent = IdPair{}
			continue
		}
	}
	return
}
