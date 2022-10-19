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
	EventDone,
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

JSONParser :: struct {
	p: Parser,

	state: PS,
	obj_map: KeyMap,

	// skippy state
	got_first_char: bool,
	skipper_objs: int,
	event_start: bool,
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

FieldType :: enum u8 {
	Invalid = 0,
	Dur,
	Name,
	Pid,
	Tid,
	Ts,
	Ph,
	S,
}
Field :: struct {
	name: string,
	type: FieldType,
}
fields := [?]Field{ 
	{"dur", .Dur}, 
	{"name", .Name}, 
	{"pid", .Pid},
	{"tid", .Tid}, 
	{"ts", .Ts},
	{"ph", .Ph},
	{"s", .S},
}

init_json_parser :: proc(total_size: u32) -> JSONParser {
	jp := JSONParser{}
	jp.p = init_parser(total_size)

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

	jp.obj_map = km_init(scratch_allocator)
	for field in fields {
		km_insert(&jp.obj_map, field.name, field.type)
	}

	jp.state = .Starting

	jp.got_first_char = false
	jp.skipper_objs = 0

	return jp
}

dfa := [?][10]PS{
	// Any,    ArrOpen, ArrClose,     
	// Quote,  ObjOpen, ObjClose,
	// Escape, Colon,   Comma, Primitive

	// starting
	[?]PS{
		PS.Starting, PS.ArrOpen, PS.ArrClose, 
		PS.String,   PS.ObjOpen, PS.ObjClose, 
		PS.Escape,   PS.Colon,   PS.Comma, PS.Primitive,
	},

	// string
	[?]PS{
		PS.String,   PS.String, PS.String, 
		PS.Starting, PS.String, PS.String, 
		PS.Escape,   PS.String, PS.String, PS.String,
	},

	// escape
	[?]PS{
		PS.String, PS.String, PS.String, 
		PS.String, PS.String, PS.String, 
		PS.String, PS.String, PS.String, PS.String,
	},

	// colon
	[?]PS{
		PS.Starting, PS.ArrOpen, PS.ArrClose, 
		PS.String,   PS.ObjOpen, PS.ObjClose, 
		PS.Escape,   PS.Colon,   PS.Comma,  PS.Primitive,
	},

	// []{}
	[?]PS{
		PS.Starting, PS.ArrOpen,  PS.ArrClose, 
		PS.String,   PS.ObjOpen,  PS.ObjClose, 
		PS.Escape,   PS.Colon,    PS.Comma, PS.Primitive,
	},
	[?]PS{
		PS.Starting, PS.ArrOpen,  PS.ArrClose, 
		PS.String,   PS.ObjOpen,  PS.ObjClose, 
		PS.Escape,   PS.Colon,    PS.Comma, PS.Primitive,
	},
	[?]PS{
		PS.Starting, PS.ArrOpen,  PS.ArrClose, 
		PS.String,   PS.ObjOpen,  PS.ObjClose, 
		PS.Escape,   PS.Colon,    PS.Comma, PS.Primitive,
	},
	[?]PS{
		PS.Starting, PS.ArrOpen,  PS.ArrClose, 
		PS.String,   PS.ObjOpen,  PS.ObjClose, 
		PS.Escape,   PS.Colon,    PS.Comma, PS.Primitive,
	},

	// ,
	[?]PS{
		PS.Starting, PS.ArrOpen,  PS.ArrClose, 
		PS.String,   PS.ObjOpen,  PS.ObjClose, 
		PS.Escape,   PS.Colon,    PS.Comma, PS.Primitive,
	},

	// -, 0-9, t, f, n
	[?]PS{
		PS.Primitive, PS.ArrOpen,  PS.ArrClose, 
		PS.Starting,  PS.ObjOpen,  PS.ObjClose, 
		PS.Starting,  PS.Starting, PS.Comma, PS.Primitive,
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
			state = .Finished
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
			p.pos += 1
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

				p.pos += 1
				return .Finished
			}
		case '{': jp.skipper_objs += 1
		case '}': jp.skipper_objs -= 1
		}
	}

	return .PartialRead
}

// skip until we've got a { or a ]
skip_to_start_or_end :: proc(jp: ^JSONParser) -> JSONState {
	p := &jp.p

	ret := eat_spaces(p)
	if !ret {
		return .PartialRead
	}

	ch := p.data[chunk_pos(p)]
	if ch == '{' || ch == ']' {
		return .Finished
	}

	if ch == ',' {
		p.pos += 1

		ret = eat_spaces(p)
		if !ret {
			return .PartialRead
		}

		ch = p.data[chunk_pos(p)]
		if ch == '{' || ch == ']' {
			return .Finished
		}
	}

	fmt.printf("Unable to find next event! %c\n", ch)
	push_fatal(SpallError.InvalidFile)
	return .InvalidToken
}

process_key_value :: proc(jp: ^JSONParser, ev: ^TempEvent, key, value: string) {

	type, ok := km_find(&jp.obj_map, key)
	if !ok {
		return
	}

	#partial switch type {
	case .Name:
		str := in_get(&jp.p.intern, value)
		ev.name = str
	case .Ph:
		if len(value) != 1 {
			return
		}

		type_ch := value[0]
		switch type_ch {
		case 'X': ev.type = .Complete
		case 'B': ev.type = .Begin
		case 'E': ev.type = .End
		case 'i': ev.type = .Instant
		}
	case .Dur: 
		dur, ok := parse_f64(value)
		if !ok { return }
		ev.duration = dur
	case .Ts: 
		ts, ok := parse_f64(value)
		if !ok { return }
		ev.timestamp = ts
	case .Tid: 
		tid, ok := parse_u32(value)
		if !ok { return }
		ev.thread_id = tid
	case .Pid: 
		pid, ok := parse_u32(value)
		if !ok { return }
		ev.process_id = pid
	case .S: 
		if len(value) != 1 {
			return
		}

		scope_ch := value[0]
		switch scope_ch {
		case 'g': ev.scope = .Global
		case 'p': ev.scope = .Process
		case 't': ev.scope = .Thread
		}
	}
}

process_next_json_event :: proc(jp: ^JSONParser) -> (state: JSONState) {
	p := &jp.p

	p.data = p.full_chunk[chunk_pos(p):]
	p.offset = p.chunk_start+chunk_pos(p)

	start := real_pos(p)

	// skip to the start of the next event, or quit if we've got them all
	ret := skip_to_start_or_end(jp)
	if ret == .PartialRead {
		p.pos = start
		state = .PartialRead
		return
	}
	if p.data[chunk_pos(p)] == ']' {
		state = .Finished
		return
	}

	start = real_pos(p)

	str_start : i64 = 0
	primitive_start : i64 = 0
	in_string := false
	in_primitive := false
	in_key := false
	key_str := ""

	ev := TempEvent{}

	depth_count := 0

	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		#no_bounds_check ch := p.data[chunk_pos(p)]
		#no_bounds_check class := char_class[ch]
		#no_bounds_check next_state := dfa[jp.state][class]
		jp.state = next_state

		if next_state != .String && in_string {
			str := string(p.data[str_start:chunk_pos(p)])
			if depth_count == 1 {
				if in_key {
					key_str = str
				} else {
					process_key_value(jp, &ev, key_str, str)
				}
			}

			in_string = false
		} else if next_state != .Primitive && in_primitive {
			str := string(p.data[primitive_start:chunk_pos(p)])
			if depth_count == 1 {
				process_key_value(jp, &ev, key_str, str)
			}

			in_primitive = false
		}

		#partial switch next_state {
		case .ArrOpen:
			in_key = false
		case .ObjOpen:
			in_key = true
			depth_count += 1
		case .ObjClose:
			in_key := false
			depth_count -= 1
			if depth_count == 0 {
				p.pos += 1
				state = .EventDone

				switch ev.type {
				case .Instant:
					ev.timestamp *= stamp_scale
					json_push_instant(ev)
				case .Complete:
					new_event := JSONEvent{
						name = ev.name,
						duration = ev.duration,
						self_time = ev.duration,
						timestamp = ev.timestamp,
					}
					json_push_event(u32(ev.process_id), u32(ev.thread_id), new_event)
				case .Begin:
					new_event := JSONEvent{
						name = ev.name,
						duration = -1,
						timestamp = (ev.timestamp) * stamp_scale,
					}

					p_idx, t_idx, e_idx := json_push_event(u32(ev.process_id), u32(ev.thread_id), new_event)

					thread := &processes[p_idx].threads[t_idx]
					queue.push_back(&thread.bande_q, e_idx)
				case .End:
					p_idx, ok1 := vh_find(&process_map, u32(ev.process_id))
					if !ok1 {
						fmt.printf("invalid end?\n")
						return
					}
					t_idx, ok2 := vh_find(&processes[p_idx].thread_map, u32(ev.thread_id))
					if !ok2 {
						fmt.printf("invalid end?\n")
						return
					}

					thread := &processes[p_idx].threads[t_idx]
					if queue.len(thread.bande_q) > 0 {
						je_idx := queue.pop_back(&thread.bande_q)
						jev := &thread.json_events[je_idx]
						jev.duration = (ev.timestamp - jev.timestamp) * stamp_scale
						jev.self_time = jev.duration
						thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
						total_max_time = max(total_max_time, jev.timestamp + jev.duration)
					}
				}
				return
			}
		case .Colon: in_key = false
		case .Comma: in_key = true
		case .String:
			if !in_string {
				str_start = chunk_pos(p) + 1
				in_string = true
			}
		case .Primitive:
			if !in_primitive {
				primitive_start = chunk_pos(p)
				in_primitive = true
			}
		}
	}

	// we ran out of chunk to process
	jp.state = .Starting
	p.pos = start
	state = .PartialRead
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
		state := process_next_json_event(jp)
		#partial switch state {
		case .PartialRead:
			p.offset = p.pos
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
			return
		case .Finished:
			finish_loading()
			return
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

	event_count += 1

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
