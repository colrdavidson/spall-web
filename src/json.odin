package main

import "core:fmt"
import "core:strings"
import "core:slice"
import "core:mem"
import "core:c"
import "core:encoding/json"

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

Sample :: struct {
	node_id: i64,
	event_idx: i64,
}

ProfileState :: struct {
	pid: u32,
	tid: u32,
	time: f64,
	nodes: map[i64]SampleNode,
	id_stack: Stack(Sample),
}

JSONParser :: struct {
	p: Parser,

	state: PS,
	obj_map: KeyMap,
	profiles: map[u64]ProfileState,

	// skippy state
	got_first_char: bool,
	skipper_objs: int,
	event_start: bool,
}

SampleNode :: struct {
	id: i64,
	parent: i64,
	name: INStr,
	is_other: bool,
}

Node :: struct {
	id: i64,
	parent: i64,
	callFrame: struct {
		lineNumber: i64,
		columnNumber: i64,
		scriptId: i64,

		codeType: string,
		functionName: string,
		url: string,
	},
}
ChunkArgs :: struct {
	data: struct {
		cpuProfile: struct {
			nodes:   [dynamic]Node,
			samples: [dynamic]i64,
		},
		timeDeltas: [dynamic]i64,
	},
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

char_class := [256]CharType{}

FieldType :: enum u8 {
	Invalid = 0,
	Args,
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
	{"args", .Args}, 
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
	char_class[u8('.')] = .Primitive

	jp.obj_map = km_init()
	for field in fields {
		km_insert(&jp.obj_map, field.name, field.type)
	}

	jp.state = .Starting

	jp.got_first_char = false
	jp.skipper_objs = 0
	jp.profiles = make(map[u64]ProfileState, 16, scratch_allocator)

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

	// -, ., 0-9, t, f, n
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
}

process_key_value :: proc(jp: ^JSONParser, ev: ^TempEvent, key: FieldType, value: string) #no_bounds_check {
	#partial switch key {
	case .Name:
		str := in_get(&jp.p.intern, value)
		ev.name = str
	case .Ph:
		if len(value) != 1 {
			fmt.printf("Invalid type!\n")
			push_fatal(SpallError.InvalidFile)
		}

		type_ch := value[0]
		switch type_ch {
		case 'X': ev.type = .Complete
		case 'B': ev.type = .Begin
		case 'E': ev.type = .End
		case 'i': ev.type = .Instant
		case 'I': ev.type = .Instant
		case 'M': ev.type = .Metadata
		case 'P': ev.type = .Sample
		}
	case .Dur: 
		dur, ok := parse_f64(value)
		if !ok {
			fmt.printf("Invalid number!\n")
			push_fatal(SpallError.InvalidFile)
		}
		ev.duration = dur
	case .Ts: 
		ts, ok := parse_f64(value)
		if !ok {
			fmt.printf("Invalid number!\n")
			push_fatal(SpallError.InvalidFile)
		}
		ev.timestamp = ts
	case .Tid: 
		tid, ok := parse_u32(value)
		if !ok {
			fmt.printf("Invalid number!\n")
			push_fatal(SpallError.InvalidFile)
		}
		ev.thread_id = tid
	case .Pid: 
		pid, ok := parse_u32(value)
		if !ok {
			fmt.printf("Invalid number!\n")
			push_fatal(SpallError.InvalidFile)
		}
		ev.process_id = pid
	case .S: 
		if len(value) != 1 {
			fmt.printf("Invalid scope!\n")
			push_fatal(SpallError.InvalidFile)
		}

		scope_ch := value[0]
		switch scope_ch {
		case 'g': ev.scope = .Global
		case 'p': ev.scope = .Process
		case 't': ev.scope = .Thread
		}
	}
}

process_sample :: proc(ev: TempEvent) {
	meta_str := in_getstr(ev.name)
	profile_key := u64(ev.process_id) << 32 | u64(ev.thread_id)
	if meta_str == "Profile" {
		blob, err := json.parse_string(in_getstr(ev.args), json.DEFAULT_SPECIFICATION, false, scratch2_allocator)
		if err != nil {
			fmt.printf("Failed to parse args?\n")
			push_fatal(SpallError.InvalidFile)
		}

		arg_map, _ := blob.(json.Object)
		data_map, ok := arg_map["data"].(json.Object)
		if !ok {
			fmt.printf("Invalid %s\n", meta_str)
			push_fatal(SpallError.InvalidFile)
		}
		start_time, ok2 := data_map["startTime"].(json.Float)
		if !ok2 {
			fmt.printf("Invalid %s\n", meta_str)
			push_fatal(SpallError.InvalidFile)
		}
		free_all(scratch2_allocator)

		p_idx := setup_pid(ev.process_id)
		t_idx := setup_tid(p_idx, ev.thread_id)

		ps := ProfileState{
			pid = ev.process_id,
			tid = ev.thread_id,
			time = start_time,
			nodes = make(map[i64]SampleNode, 16, scratch_allocator),
		}
		stack_init(&ps.id_stack, scratch_allocator)

		jp.profiles[profile_key] = ps
	} else if meta_str == "ProfileChunk" {
		p_idx := setup_pid(ev.process_id)
		t_idx := setup_tid(p_idx, ev.thread_id)

		profile, ok := &jp.profiles[profile_key]
		if !ok {
			ps := ProfileState{
				pid   = ev.process_id,
				tid   = ev.thread_id,
				time  = ev.timestamp,
				nodes = make(map[i64]SampleNode, 16, scratch_allocator),
			}
			stack_init(&ps.id_stack, scratch_allocator)
			jp.profiles[profile_key] = ps
			profile, _ = &jp.profiles[profile_key]
		}

		thread := &processes[p_idx].threads[t_idx]

		chunk := ChunkArgs{}

		err := json.unmarshal_string(in_getstr(ev.args), &chunk, json.DEFAULT_SPECIFICATION, scratch2_allocator)
		if err != nil {
			fmt.printf("Failed to parse args?\n")
			push_fatal(SpallError.InvalidFile)
		}

		for node in chunk.data.cpuProfile.nodes {
			func_name := in_get(&jp.p.intern, node.callFrame.functionName)
			is_other := node.callFrame.codeType == "other"
			profile.nodes[node.id] = SampleNode{
				id = node.id,
				parent = node.parent,
				name = func_name,
				is_other = is_other,
			}
		}

		for _, i in chunk.data.cpuProfile.samples {
			cur_sample_id := chunk.data.cpuProfile.samples[i]
			cur_sample_node := profile.nodes[cur_sample_id]
			delta := chunk.data.timeDeltas[i]
			if delta < 0 {
				continue
			}

			profile.time += f64(delta)
			stack_top_id : i64 = 0
			if profile.id_stack.len > 0 {
				tmp := stack_peek_back(&profile.id_stack)
				stack_top_id = tmp.node_id
			}

			if stack_top_id == cur_sample_id {
				// keep accruing dt
				continue
			} else if cur_sample_node.is_other && in_getstr(cur_sample_node.name) == "(garbage collector)" {

				// ugh. thanks Google. GC events are weird.
				new_event := JSONEvent{
					name = cur_sample_node.name,
					duration = -1,
					timestamp = profile.time,
				}

				_, _, e_idx := json_push_event(ev.process_id, ev.thread_id, new_event)

				sample := Sample{node_id = cur_sample_id, event_idx = i64(e_idx)}
				stack_push_back(&profile.id_stack, sample)
			} else {
				// changing to a new stack

				ancestor_idx := -1
				for i := 0; i < profile.id_stack.len; i += 1 {
					tmp := profile.id_stack.arr[i]
					if tmp.node_id == cur_sample_id {
						ancestor_idx = i
						break
					}
				}

				cycle_count := 0
				nodes_to_begin: [dynamic]i64 
				if ancestor_idx < 0 {
					nodes_to_begin = make([dynamic]i64, scratch2_allocator)
					cur_node_id := cur_sample_id

					find_ancestor:
					for cur_node_id != 0 {
						for i := profile.id_stack.len - 1; i >= 0; i -= 1 {
							sample := profile.id_stack.arr[i]
							if sample.node_id == cur_node_id {
								ancestor_idx = i
								break find_ancestor
							}
						}

						append(&nodes_to_begin, cur_node_id)
						cur_node_id = profile.nodes[cur_node_id].parent

						if cycle_count > 1000 {
							fmt.printf("stack too deep, do we have a cycle?\n")
							push_fatal(SpallError.InvalidFile)
						}
						cycle_count += 1
					}
				}

				for i := profile.id_stack.len - 1; i > ancestor_idx; i -= 1 {
					sample := stack_pop_back(&profile.id_stack)
					node := profile.nodes[sample.node_id]
					json_patch_end(p_idx, t_idx, sample.event_idx, profile.time)
				}

				for i := len(nodes_to_begin) - 1; i >= 0; i -= 1 {
					node_id := nodes_to_begin[i]
					node := profile.nodes[node_id]

					if node.name.len == 0 {
						node.name = in_get(&jp.p.intern, "(anonymous)")
					}

					new_event := JSONEvent{
						name = node.name,
						duration = -1,
						timestamp = profile.time,
					}

					_, _, e_idx := json_push_event(ev.process_id, ev.thread_id, new_event)
					sample := Sample{node_id = node_id, event_idx = i64(e_idx)}
					stack_push_back(&profile.id_stack, sample)
				}
			}
		}
		free_all(scratch2_allocator)
	}
}

process_event :: proc(ev: TempEvent) {
	#partial switch ev.type {
	case .Instant:
		e := ev
		e.timestamp *= stamp_scale
		json_push_instant(e)
	case .Complete:
		new_event := JSONEvent{
			name = ev.name,
			args = ev.args,
			duration = ev.duration,
			self_time = ev.duration,
			timestamp = ev.timestamp,
		}
		json_push_event(u32(ev.process_id), u32(ev.thread_id), new_event)
	case .Begin:
		new_event := JSONEvent{
			name = ev.name,
			args = ev.args,
			duration = -1,
			timestamp = ev.timestamp,
		}

		p_idx, t_idx, e_idx := json_push_event(u32(ev.process_id), u32(ev.thread_id), new_event)

		thread := &processes[p_idx].threads[t_idx]
		stack_push_back(&thread.bande_q, e_idx)
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
		if thread.bande_q.len > 0 {
			je_idx := stack_pop_back(&thread.bande_q)
			jev := &thread.json_events[je_idx]
			jev.duration = ev.timestamp - jev.timestamp
			jev.self_time = jev.duration
			thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
			total_max_time = max(total_max_time, jev.timestamp + jev.duration)
		}
	case .Sample:
		process_sample(ev)
	case .Metadata:
		meta_str := in_getstr(ev.name)
		if meta_str == "thread_name" || meta_str == "process_name" {
			blob, err := json.parse_string(in_getstr(ev.args), json.DEFAULT_SPECIFICATION, false, scratch2_allocator)
			if err != nil {
				fmt.printf("Failed to parse args?\n")
				push_fatal(SpallError.InvalidFile)
			}

			arg_map, _ := blob.(json.Object)
			m_name, ok := arg_map["name"].(json.String)
			if !ok {
				fmt.printf("Invalid %s\n", meta_str)
				push_fatal(SpallError.InvalidFile)
			}

			name := in_get(&jp.p.intern, m_name)
			free_all(scratch2_allocator)

			if meta_str == "thread_name" {
				p_idx := setup_pid(ev.process_id)
				t_idx := setup_tid(p_idx, ev.thread_id)
				processes[p_idx].threads[t_idx].name = name
			} else if meta_str == "process_name" {
				p_idx := setup_pid(ev.process_id)
				processes[p_idx].name = name
			}
		}
	}
}

process_next_json_event :: proc(jp: ^JSONParser) -> (state: JSONState) #no_bounds_check {
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
	args_start : i64 = 0
	in_string := false
	in_primitive := false
	in_key := false
	key_type := FieldType.Invalid

	ev := TempEvent{}

	depth_count := 0

	for ; chunk_pos(p) < i64(len(p.data)); p.pos += 1 {
		ch := p.data[chunk_pos(p)]
		class := char_class[ch]
		next_state := dfa[jp.state][class]
		jp.state = next_state

		if next_state != .String && in_string {
			str := string(p.data[str_start:chunk_pos(p)])
			if depth_count == 1 {
				if in_key {
					key_type, _ = km_find(&jp.obj_map, str)
				} else {
					process_key_value(jp, &ev, key_type, str)
					key_type = .Invalid
				}
			}

			in_string = false
		} else if next_state != .Primitive && in_primitive {
			str := string(p.data[primitive_start:chunk_pos(p)])
			if depth_count == 1 {
				process_key_value(jp, &ev, key_type, str)
				key_type = .Invalid
			}

			in_primitive = false
		}

		#partial switch next_state {
		case .ArrOpen:
			in_key = false
		case .ObjOpen:
			if depth_count == 1 && key_type == .Args {
				args_start = chunk_pos(p)
			}

			in_key = true
			depth_count += 1
		case .ObjClose:
			in_key := false
			depth_count -= 1

			if depth_count == 1 && key_type == .Args {
				str := string(p.data[args_start:chunk_pos(p)+1])

				// skip storing args: {}
				if len(str) > 2 {
					ev.args = in_get(&jp.p.intern, str)
				}

				key_type = .Invalid
			} else if depth_count == 0 {
				p.pos += 1
				state = .EventDone

				process_event(ev)
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
				json_finish_loading(jp)
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
			json_finish_loading(jp)
			return
		}
	}
	return
}

json_finish_loading :: proc(jp: ^JSONParser) {
	for _, profile in &jp.profiles {
		p_idx, ok1 := vh_find(&process_map, profile.pid)
		if !ok1 {
			fmt.printf("finish_loading | invalid end in profile?\n")
			continue
		}

		t_idx, ok2 := vh_find(&processes[p_idx].thread_map, profile.tid)
		if !ok2 {
			fmt.printf("finish_loading | invalid end in profile?\n")
			continue
		}

		for i := profile.id_stack.len - 1; i >= 0; i -= 1 {
			sample := stack_pop_back(&profile.id_stack)
			json_patch_end(p_idx, t_idx, sample.event_idx, profile.time)
			node := profile.nodes[sample.node_id]
		}
	}

	free_all(scratch2_allocator)
	finish_loading()
}

json_patch_end :: proc(p_idx, t_idx: int, e_idx: i64, end_time: f64) {
	thread := &processes[p_idx].threads[t_idx]
	jev := &thread.json_events[e_idx]
	jev.duration = end_time - jev.timestamp
	jev.self_time = jev.duration
	thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
	total_max_time = max(total_max_time, jev.timestamp + jev.duration)
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

	p_idx := setup_pid(event.process_id)
	p := &processes[p_idx]

	if event.scope == .Process {
		append(&p.instants, instant)
		return
	}

	t_idx := setup_tid(p_idx, event.thread_id)

	t := &p.threads[t_idx]
	if event.scope == .Thread {
		append(&t.instants, instant)
		return
	}
}


json_push_event :: proc(process_id, thread_id: u32, event: JSONEvent) -> (int, int, int) {
	p_idx := setup_pid(process_id)
	t_idx := setup_tid(p_idx, thread_id)

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
	ev_stack: Stack(int)
	stack_init(&ev_stack, context.temp_allocator)

	slice.sort_by(global_instants[:], instant_rendersort_proc)

	for pe, _ in process_map.entries {
		proc_idx := pe.val
		process := &processes[proc_idx]

		slice.sort_by(process.threads[:], tid_sort_proc)

		// generate depth mapping
		for tm in &process.threads {
			if len(tm.json_events) == 0 {
				continue
			}

			insertion_sort(tm.json_events[:], event_buildsort_proc)

			free_all(scratch_allocator)
			depth_counts := make([dynamic]uint, 0, 64, scratch_allocator)

			stack_clear(&ev_stack)
			for event, e_idx in &tm.json_events {
				cur_start := event.timestamp
				cur_end   := event.timestamp + bound_duration(event, tm.max_time)
				if ev_stack.len == 0 {
					stack_push_back(&ev_stack, e_idx)
				} else {
					prev_e_idx := stack_peek_back(&ev_stack)
					prev_ev := tm.json_events[prev_e_idx]

					prev_start := prev_ev.timestamp
					prev_end   := prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

					// if it fits within the parent
					if cur_start >= prev_start && cur_end <= prev_end {
						stack_push_back(&ev_stack, e_idx)
					} else {

						// while it doesn't overlap the parent
						for ev_stack.len > 0 {
							prev_e_idx = stack_peek_back(&ev_stack)
							prev_ev = tm.json_events[prev_e_idx]

							prev_start = prev_ev.timestamp
							prev_end   = prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

							if cur_start >= prev_start && cur_end > prev_end {
								stack_pop_back(&ev_stack)
							} else {
								break;
							}
						}
						stack_push_back(&ev_stack, e_idx)
					}
				}

				cur_depth := ev_stack.len - 1
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
					args = event.args,
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
