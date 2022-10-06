package main

import "core:fmt"
import "core:strings"
import "core:container/queue"
import "core:strconv"
import "core:slice"
import "core:c"

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
	obj_map: KeyMap,
	seen_dur: bool,
	current_parent: IdPair,
}

fields := []string{ "dur", "name", "pid", "tid", "ts", "ph", "s" }

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
	str := string(p.p.full_chunk[tok.start-p.p.chunk_start:tok.end-p.p.chunk_start])
	return str
}

parse_primitive :: proc(jp: ^JSONParser) -> (token: Token, state: JSONState) {
	p := &jp.p

	start := real_pos(p)

	found := false
	top_loop: for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
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

	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		if ch == '\"' {
			token = init_token(jp, .String, i64(start + 1), i64(real_pos(p)))
			state = .TokenDone
			return
		}

		if ch == '\\' && (chunk_pos(p) + 1) < i64(len(p.data)) {
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

	jp.obj_map = km_init(scratch_allocator)
	for field in fields {
		km_insert(&jp.obj_map, field)
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

	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
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

			fmt.printf("Oops, I did a bad? '%c':%d,%d\n", ch, chunk_pos(p), real_pos(p))
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
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
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

			val, ok := km_find(&jp.obj_map, key)
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
				str := in_get(&p.intern, value)
				jp.cur_event.name = str
			}

			switch key {
			case "ph":
				if len(value) != 1 {
					continue
				}

				type_ch := value[0]
				switch type_ch {
				case 'X': jp.cur_event.type = .Complete
				case 'B': jp.cur_event.type = .Begin
				case 'E': jp.cur_event.type = .End
				case 'i': jp.cur_event.type = .Instant
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
				tid, ok := parse_u32(value)
				if !ok { continue }
				jp.cur_event.thread_id = tid
			case "pid": 
				pid, ok := parse_u32(value)
				if !ok { continue }
				jp.cur_event.process_id = pid
			case "s": 
				if len(value) != 1 {
					continue
				}

				scope_ch := value[0]
				switch scope_ch {
				case 'g': jp.cur_event.scope = .Global
				case 'p': jp.cur_event.scope = .Process
				case 't': jp.cur_event.scope = .Thread
				case:
					continue
				}
			}

			continue
		}


		// got the whole event
		if state == .ScopeExited && tok.id == jp.cur_event_id {
			defer {
				jp.cur_event = TempEvent{}
				jp.cur_event_id = -1
				jp.seen_dur = false
				jp.current_parent = IdPair{}
			}

			switch jp.cur_event.type {
			case .Instant:
				jp.cur_event.timestamp *= stamp_scale
				json_push_instant(jp.cur_event)
				event_count += 1
			case .Complete:
				if jp.seen_dur {
					event_count += 1

					new_event := Event{
						name = jp.cur_event.name,
						duration = jp.cur_event.duration,
						timestamp = jp.cur_event.timestamp,
					}
					json_push_event(u32(jp.cur_event.process_id), u32(jp.cur_event.thread_id), new_event)
				}
			case .Begin:
				new_event := Event{
					name = jp.cur_event.name,
					duration = -1,
					timestamp = (jp.cur_event.timestamp) * stamp_scale,
				}

				event_count += 1
				p_idx, t_idx, e_idx := json_push_event(u32(jp.cur_event.process_id), u32(jp.cur_event.thread_id), new_event)

				thread := &processes[p_idx].threads[t_idx]
				queue.push_back(&thread.bande_q, e_idx)
			case .End:
				p_idx, ok1 := vh_find(&process_map, u32(jp.cur_event.process_id))
				if !ok1 {
					fmt.printf("invalid end?\n")
					continue
				}
				t_idx, ok2 := vh_find(&processes[p_idx].thread_map, u32(jp.cur_event.thread_id))
				if !ok1 {
					fmt.printf("invalid end?\n")
					continue
				}

				thread := &processes[p_idx].threads[t_idx]
				if queue.len(thread.bande_q) > 0 {
					je_idx := queue.pop_back(&thread.bande_q)
					jev := &thread.events[je_idx]
					jev.duration = (jp.cur_event.timestamp - jev.timestamp) * stamp_scale
					thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
					total_max_time = max(total_max_time, jev.timestamp + jev.duration)
				}
			}
		}
	}
	return
}

json_push_instant :: proc(event: TempEvent) {
	instant := Instant{
		name = event.name,
		timestamp = event.timestamp,
	}

	instant_count += 1

	if event.scope == .Global {
		append(&global_instants, instant)
		return
	}

	p_idx, ok1 := vh_find(&process_map, event.process_id)
	if !ok1 {
		append(&processes, init_process(event.process_id))
		p_idx = len(processes) - 1
		vh_insert(&process_map, event.process_id, p_idx)
	}

	p := &processes[p_idx]

	if event.scope == .Process {
		append(&p.instants, instant)
		return
	}

	t_idx, ok2 := vh_find(&processes[p_idx].thread_map, event.thread_id)
	if !ok2 {
		threads := &processes[p_idx].threads
		append(threads, init_thread(event.thread_id))

		t_idx = len(threads) - 1
		thread_map := &processes[p_idx].thread_map
		vh_insert(thread_map, event.thread_id, t_idx)
	}

	t := &p.threads[t_idx]
	if event.scope == .Thread {
		append(&t.instants, instant)
		return
	}
}

json_push_event :: proc(process_id, thread_id: u32, event: Event) -> (int, int, int) {
	p_idx, ok1 := vh_find(&process_map, process_id)
	if !ok1 {
		append(&processes, init_process(process_id))
		p_idx = len(processes) - 1
		vh_insert(&process_map, process_id, p_idx)
	}

	t_idx, ok2 := vh_find(&processes[p_idx].thread_map, thread_id)
	if !ok2 {
		threads := &processes[p_idx].threads

		append(threads, init_thread(thread_id))

		t_idx = len(threads) - 1
		thread_map := &processes[p_idx].thread_map
		vh_insert(thread_map, thread_id, t_idx)
	}

	p := &processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)
	t.max_time = max(t.max_time, event.timestamp + event.duration)

	total_min_time = min(total_min_time, event.timestamp)
	total_max_time = max(total_max_time, event.timestamp + event.duration)

	append(&t.events, event)
	return p_idx, t_idx, len(t.events)-1
}

pid_sort_proc :: proc(a, b: Process) -> bool { return a.min_time < b.min_time }
tid_sort_proc :: proc(a, b: Thread) -> bool  { return a.min_time < b.min_time }
event_buildsort_proc :: proc(a, b: Event) -> bool {
	if a.timestamp == b.timestamp {
		return a.duration > b.duration
	}
	return a.timestamp < b.timestamp
}
event_rendersort_step1_proc :: proc(a, b: Event) -> bool {
	return a.depth < b.depth
}
event_rendersort_step2_proc :: proc(a, b: Event) -> bool {
	return a.timestamp < b.timestamp
}
instant_rendersort_proc :: proc(a, b: Instant) -> bool {
	return a.timestamp < b.timestamp
}

json_process_events :: proc() {
	ev_stack: queue.Queue(int)
	queue.init(&ev_stack, 0, context.temp_allocator)

	slice.sort_by(global_instants[:], instant_rendersort_proc)

	for pe, _ in process_map.entries {
		proc_idx := pe.val
		process := &processes[proc_idx]

		slice.sort_by(process.threads[:], tid_sort_proc)

		// generate depth mapping
		for tm in &process.threads {
			slice.sort_by(tm.events[:], event_buildsort_proc)

			queue.clear(&ev_stack)		
			for event, e_idx in &tm.events {
				cur_start := event.timestamp
				cur_end   := event.timestamp + bound_duration(event, tm.max_time)
				if queue.len(ev_stack) == 0 {
					queue.push_back(&ev_stack, e_idx)
				} else {
					prev_e_idx := queue.peek_back(&ev_stack)^
					prev_ev := tm.events[prev_e_idx]

					prev_start := prev_ev.timestamp
					prev_end   := prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

					// if it fits within the parent
					if cur_start >= prev_start && cur_end <= prev_end {
						queue.push_back(&ev_stack, e_idx)
					} else {

						// while it doesn't overlap the parent
						for queue.len(ev_stack) > 0 {
							prev_e_idx = queue.peek_back(&ev_stack)^
							prev_ev = tm.events[prev_e_idx]

							prev_start = prev_ev.timestamp
							prev_end   = prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)


							if cur_start >= prev_start && cur_end > prev_end {
								queue.pop_back(&ev_stack)
							} else {
								break;
							}
						}
						queue.push_back(&ev_stack, e_idx)
					}
				}

				event.depth = u16(queue.len(ev_stack))
			}
			slice.sort_by(tm.events[:], event_rendersort_step1_proc)

			i := 0
			ev_start := 0
			cur_depth : u16 = 0
			for ; i < len(tm.events) - 1; i += 1 {
				ev := tm.events[i]
				next_ev := tm.events[i+1]

				if ev.depth != next_ev.depth {
					depth := Depth{
						events = tm.events[ev_start:i+1]
					}

					append(&tm.depths, depth)
					ev_start = i + 1
					cur_depth = next_ev.depth
				}
			}

			if len(tm.events) > 0 {
				depth := Depth{
					events = tm.events[ev_start:i+1]
				}

				append(&tm.depths, depth)
			}

			for depth in tm.depths {
				slice.sort_by(depth.events, event_rendersort_step2_proc)
			}
		}
	}

	slice.sort_by(processes[:], pid_sort_proc)
	return
}
