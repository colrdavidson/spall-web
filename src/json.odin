package main

import "core:fmt"
import "core:strings"
import "core:container/queue"
import "core:strconv"
import "core:slice"
import "core:mem"
import "core:c"

JSONState :: enum {
	InvalidToken,
	PartialRead,
	Finished,

	ScopeEntered,
	ScopeExited,
	TokenDone,
}

TokenType :: enum u8 {
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

TmpKey :: struct {
	start: i64,
	end: i64,
}

IdPair :: struct {
	key: string,
	id: int,
}

JSONParser :: struct {
	p: Parser,

	parent_stack: queue.Queue(Token),
	tok_count: int,

	state: PS,

	// Event parsing state
	cur_event: TempEvent,
	cur_event_id: int,
	obj_map: KeyMap,
	seen_dur: bool,
	current_parent: IdPair,

	// skippy state
	got_first_char: bool,
	skipper_objs: int,
	event_start: bool,
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

CharType :: enum u8 {
	Any = 0,
	ArrOpen,
	ArrClose,
	Quote,
	ObjOpen,
	ObjClose,
	Escape,
	Colon,
	Comma,
	Primitive,
}

PS :: enum u8 {
	Starting = 0,
	String,
	Escape,
	Colon,
	ObjOpen,
	ObjClose,
	ArrOpen,
	ArrClose,
	Comma,
	Primitive,
}

char_class := [128]CharType{}

init_json_parser :: proc(total_size: u32) -> JSONParser {
	jp := JSONParser{}
	jp.p = init_parser(total_size)
	queue.init(&jp.parent_stack, 16, scratch_allocator)

	jp.obj_map = km_init(scratch_allocator)
	for field in fields {
		km_insert(&jp.obj_map, field)
	}

	jp.cur_event_id = -1
	jp.cur_event = TempEvent{}
	jp.seen_dur = false
	jp.current_parent = IdPair{}

	// flesh out char classes
	char_class[u8('{')] = .ObjOpen
	char_class[u8('}')] = .ObjClose
	char_class[u8('"')] = .Quote
	char_class[u8('[')] = .ArrOpen
	char_class[u8(']')] = .ArrClose
	char_class[u8('\\')] = .Escape
	char_class[u8(':')] = .Colon
	char_class[u8(',')] = .Comma

	char_class[u8('-')] = .Primitive
	for i : u8 = 0; i < 10; i += 1 {
		char_class[u8('0') + i] = .Primitive
	}
	char_class[u8('t')] = .Primitive
	char_class[u8('f')] = .Primitive
	char_class[u8('n')] = .Primitive

	jp.state = .Starting

	jp.got_first_char = false
	jp.skipper_objs = 0

	return jp
}

dfa := [][]u8{
	// Any,    ArrOpen, ArrClose,     
	// Quote,  ObjOpen, ObjClose,
	// Escape, Colon,   Comma, Primitive

	// starting
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma), u8(PS.Primitive),
	},

	// string
	{
		u8(PS.String),   u8(PS.String), u8(PS.String), 
		u8(PS.Starting), u8(PS.String), u8(PS.String), 
		u8(PS.Escape),   u8(PS.String), u8(PS.String), u8(PS.String),
	},

	// escape
	{
		u8(PS.String), u8(PS.String), u8(PS.String), 
		u8(PS.String), u8(PS.String), u8(PS.String), 
		u8(PS.String), u8(PS.String), u8(PS.String), u8(PS.String),
	},

	// colon
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma),  u8(PS.Primitive),
	},

	// []{}
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma), u8(PS.Primitive),
	},
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma), u8(PS.Primitive),
	},
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma), u8(PS.Primitive),
	},
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma), u8(PS.Primitive),
	},

	// ,
	{
		u8(PS.Starting), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.String),   u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Escape),   u8(PS.Colon),    u8(PS.Comma), u8(PS.Primitive),
	},

	// -, 0-9, t, f, n
	{
		u8(PS.Primitive), u8(PS.ArrOpen),  u8(PS.ArrClose), 
		u8(PS.Starting), u8(PS.ObjOpen),  u8(PS.ObjClose), 
		u8(PS.Starting), u8(PS.Starting), u8(PS.Comma), u8(PS.Primitive),
	},
}

eat_spaces :: proc(p: ^Parser) -> bool {
	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]
		if ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t' {
			return true
		}
	}

	return false
}

skip_string :: proc(jp: ^JSONParser) -> (key: TmpKey, state: JSONState) {
	p := &jp.p

	start := real_pos(p)
	p.pos += 1

	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		if ch == '\"' {
			key = TmpKey{i64(start + 1), i64(real_pos(p))}
			p.pos += 1
			state = .TokenDone
			return
		}

		if ch == '\\' && (chunk_pos(p) + 1) < i64(len(p.data)) {
			p.pos += 1
		}
	}

	state = .PartialRead
	return
}

the_skipper :: proc(jp: ^JSONParser) -> JSONState {
	p := &jp.p

	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	// speed-skip until we have data we care about
	if !jp.got_first_char {
		ret := eat_spaces(p)
		if !ret {
			return .PartialRead
		}

		ch := p.data[chunk_pos(p)]
		if ch != '{' && ch != '[' {
			fmt.printf("Your JSON file is invalid! got %c, expected [ or {{\n", ch)
			push_fatal(SpallError.InvalidFile)
		}

		if ch == '[' {
			return .Finished
		}
	}

	// scan until we've got the token for the first object in the traceEvents array
	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]

		switch ch {
		case '"': 
			start := real_pos(p)

			key, state := skip_string(jp)
			if state == .PartialRead {
				p.pos = start
				return .PartialRead
			}

			key_str := string(p.full_chunk[key.start-p.chunk_start:key.end-p.chunk_start])
			if jp.skipper_objs == 1 && key_str == "traceEvents" {
				ret := eat_spaces(p)
				if !ret {
					p.pos = start
					return .PartialRead
				}

				ch := p.data[chunk_pos(p)]
				if ch != ':' {
					fmt.printf("Your JSON file is invalid! got %c, expected :\n", ch)
					push_fatal(SpallError.InvalidFile)
				}
				p.pos += 1

				ret = eat_spaces(p)
				if !ret {
					p.pos = start
					return .PartialRead
				}

				ch = p.data[chunk_pos(p)]
				if ch != '[' {
					fmt.printf("Your JSON file is invalid! got %c, expected [\n", ch)
					push_fatal(SpallError.InvalidFile)
				}

				return .Finished
			}
		case '{': jp.skipper_objs += 1
		case '}': jp.skipper_objs -= 1
		}
	}

	return .PartialRead
}

get_next_token :: proc(jp: ^JSONParser) -> (token: Token, state: JSONState) {
	p := &jp.p

	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	count := 0

	str_start : i64 = 0
	primitive_start : i64 = 0
	in_string := false
	in_primitive := false

	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]
		class := char_class[ch]
		next_state := PS(dfa[jp.state][class])
		jp.state = next_state

		if next_state != .String && in_string {
			token = init_token(jp, .String, str_start+1, i64(real_pos(p)))

			parent := queue.peek_back(&jp.parent_stack)
			if parent.type == .Object {
				push_wrap(jp, token)
			}

			//fmt.printf("string: %s\n", get_token_str(jp, token))
			p.pos += 1
			state = .TokenDone
			return
		} else if next_state != .Primitive && in_primitive {
			token = init_token(jp, .Primitive, primitive_start, i64(real_pos(p)))

			//fmt.printf("primitive: %s\n", get_token_str(jp, token))
			state = .TokenDone
			return
		}

		#partial switch next_state {
		case .ObjOpen: fallthrough
		case .ArrOpen:
			type := (ch == '{') ? TokenType.Object : TokenType.Array
			token = init_token(jp, type, i64(real_pos(p)), -1)
			push_wrap(jp, token)

			p.pos += 1
			state = .ScopeEntered
			return
		case .ObjClose: fallthrough
		case .ArrClose:
			type := (ch == '}') ? TokenType.Object : TokenType.Array

			depth := queue.len(jp.parent_stack)
			if depth == 0 {
				fmt.printf("1 Expected first {{, got %c\n", ch)
				push_fatal(SpallError.InvalidFile)
			}

			loop: for {
				token = pop_wrap(jp)
				depth = queue.len(jp.parent_stack)

				if token.start != -1 && token.end == -1 {
					if token.type != type {
						fmt.printf("Got an unexpected scope close? Got %s, expected %s\n", token.type, type)
						push_fatal(SpallError.InvalidFile)
					}


					token.end = i64(real_pos(p) + 1)
					p.pos += 1
					state = .ScopeExited
					if depth == 0 && token.type == .Array {
						state = .Finished
					}

					return
				}

				if depth == 0 {
					fmt.printf("unable to find closing %c\n", type)
					push_fatal(SpallError.InvalidFile)
				}
			}

			fmt.printf("how am I here?\n")
			return
		case .Colon:
		case .Comma:
			depth := queue.len(jp.parent_stack)
			if depth == 0 {
				fmt.printf("2 Expected first {{, got %c\n", ch)
				push_fatal(SpallError.InvalidFile)
			}

			parent := queue.peek_back(&jp.parent_stack)

			if parent.type != .Array && parent.type != .Object {
				pop_wrap(jp)
			}
		case .String:
			if !in_string {
				str_start = real_pos(p)
				in_string = true
			}
		case .Primitive:
			if !in_primitive {
				primitive_start = real_pos(p)
				in_primitive = true
			}
		case .Starting:
		case .Escape:
		}
	}

	if p.pos != p.total_size {
		if in_string {
			jp.state = .Starting
			p.pos = str_start
			state = .PartialRead
			return
		}
		if in_primitive {
			jp.state = .Starting
			p.pos = primitive_start
			state = .PartialRead
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
		// skip until we hit the start of the traceEvents arr
		if !jp.event_start {
			state := the_skipper(jp)
			if p.pos >= p.total_size {
				finish_loading()
				return
			}

			#partial switch state {
			case .PartialRead:
				p.offset = p.pos
				get_chunk(f64(p.pos), f64(CHUNK_SIZE))
				return
			case .Finished:
				jp.event_start = true
			}
		}

		// start tokenizing normally now
		tok, state := get_next_token(jp)
		#partial switch state {
		case .PartialRead:
			p.offset = p.pos
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
			return
		case .InvalidToken:
			fmt.printf("Your JSON file contains an invalid token!\n")
			push_fatal(SpallError.Bug) // @Todo: Better reporting about invalid tokens
			return
		case .Finished:
			finish_loading()
			return
		}


		// get start of an event
		if jp.cur_event_id == -1 {
			if state == .ScopeEntered && tok.type == .Object {
				jp.cur_event_id = tok.id
			}
			continue
		}

		// eww.
		depth := queue.len(jp.parent_stack)
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

					new_event := JSONEvent{
						name = jp.cur_event.name,
						duration = jp.cur_event.duration,
						self_time = jp.cur_event.duration,
						timestamp = jp.cur_event.timestamp,
					}

					json_push_event(u32(jp.cur_event.process_id), u32(jp.cur_event.thread_id), new_event)
				}
			case .Begin:
				new_event := JSONEvent{
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
					jev := &thread.json_events[je_idx]
					jev.duration = (jp.cur_event.timestamp - jev.timestamp) * stamp_scale
					jev.self_time = jev.duration
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

json_push_event :: proc(process_id, thread_id: u32, event: JSONEvent) -> (int, int, int) {
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

	append(&t.json_events, event)
	return p_idx, t_idx, len(t.json_events)-1
}

pid_sort_proc :: proc(a, b: Process) -> bool { return a.min_time < b.min_time }
tid_sort_proc :: proc(a, b: Thread) -> bool  { return a.min_time < b.min_time }
event_buildsort_proc :: proc(a, b: JSONEvent) -> bool {
	if a.timestamp == b.timestamp {
		return a.duration > b.duration
	}
	return a.timestamp < b.timestamp
}
instant_rendersort_proc :: proc(a, b: Instant) -> bool {
	return a.timestamp < b.timestamp
}

insertion_sort :: proc(data: $T/[]$E, less: proc(i, j: E) -> bool) {
	for i := 1; i < len(data); i += 1 {
		j := i - 1

		temp := data[i]
		for ; j >= 0 && less(temp, data[j]); {
			data[j+1] = data[j]
			j -= 1
		}

		data[j+1] = temp
	}
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
			if len(tm.json_events) == 0 {
				fmt.printf("Thread contains no events? How did we even get here?\n")
				push_fatal(SpallError.Bug)
			}

			insertion_sort(tm.json_events[:], event_buildsort_proc)

			free_all(scratch_allocator)
			depth_counts := make([dynamic]uint, 0, 64, scratch_allocator)

			queue.clear(&ev_stack)		
			for event, e_idx in &tm.json_events {
				cur_start := event.timestamp
				cur_end   := event.timestamp + bound_duration(event, tm.max_time)
				if queue.len(ev_stack) == 0 {
					queue.push_back(&ev_stack, e_idx)
				} else {
					prev_e_idx := queue.peek_back(&ev_stack)^
					prev_ev := tm.json_events[prev_e_idx]

					prev_start := prev_ev.timestamp
					prev_end   := prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

					// if it fits within the parent
					if cur_start >= prev_start && cur_end <= prev_end {
						queue.push_back(&ev_stack, e_idx)
					} else {

						// while it doesn't overlap the parent
						for queue.len(ev_stack) > 0 {
							prev_e_idx = queue.peek_back(&ev_stack)^
							prev_ev = tm.json_events[prev_e_idx]

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

				cur_depth := queue.len(ev_stack) - 1
				if len(depth_counts) <= cur_depth {
					append(&depth_counts, 0)
				}
				depth_counts[cur_depth] += 1
				event.depth = u16(cur_depth)
			}

			depth_offsets := make([]uint, len(depth_counts), scratch_allocator)
			cur_offset : uint = 0
			for i := 0; i < len(depth_counts); i += 1 {
				depth_offsets[i] = cur_offset
				cur_offset += depth_counts[i]
			}

			depth_counters := make([]uint, len(depth_counts), scratch_allocator)
			mem.zero_slice(depth_counters)

			sorted_events := make([]Event, len(tm.json_events), big_global_allocator)
			for event in tm.json_events {
				depth := event.depth

				sort_idx := depth_offsets[depth] + depth_counters[depth]

				sorted_events[sort_idx] = Event{
					name = event.name,
					timestamp = event.timestamp,
					duration = event.duration,
					self_time = event.self_time,
				}

				depth_counters[depth] += 1
			}

			ev_start : uint = 0
			for i := 0; i < len(depth_counts); i += 1 {
				count := depth_counts[i]
				depth := Depth{
					events = sorted_events[ev_start:ev_start+count]
				}
				ev_start += count

				append(&tm.depths, depth)
			}
		}
	}

	slice.sort_by(processes[:], pid_sort_proc)
	return
}
