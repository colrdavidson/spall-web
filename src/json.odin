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
	time: i64,
	nodes: map[i64]SampleNode,
	id_stack: Stack(Sample),
}

JSONParser :: struct {
	state: PS,
	obj_map: KeyMap,
	profiles: map[u64]ProfileState,

	// skippy state
	got_first_char: bool,
	skipper_objs: i32,
	event_start: bool,
}

SampleNode :: struct {
	id: i64,
	parent: i64,
	name: u32,
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

init_json_parser :: proc() -> JSONParser {

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

	jp := JSONParser{
		obj_map = km_init(),
		state = .Starting,
		got_first_char = false,
		skipper_objs = 0,
		profiles = make(map[u64]ProfileState, 16, big_global_allocator),
	}

	for field in fields {
		km_insert(&jp.obj_map, field.name, field.type)
	}

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
		PS.Starting, PS.ArrOpen,  PS.ArrClose, 
		PS.Starting,  PS.ObjOpen,  PS.ObjClose, 
		PS.Starting,  PS.Starting, PS.Comma, PS.Primitive,
	},
}

eat_spaces :: proc(trace: ^Trace, chunk: []u8) -> bool {
	p := &trace.parser

	for ; chunk_pos(p) < i64(len(chunk)); p.pos += 1 {
		ch := chunk[chunk_pos(p)]
		if ch != ' ' && ch != '\n' && ch != '\r' && ch != '\t' {
			return true
		}
	}

	return false
}

skip_string :: proc(trace: ^Trace, chunk: []u8) -> (key: TmpKey, state: JSONState) {
	p := &trace.parser

	start := real_pos(p)
	p.pos += 1

	for ; chunk_pos(p) < i64(len(chunk)); p.pos += 1 {
		ch := chunk[chunk_pos(p)]

		if ch == '\"' {
			key = TmpKey{i64(start + 1), i64(real_pos(p))}
			p.pos += 1
			state = .Finished
			return
		}

		if ch == '\\' && (chunk_pos(p) + 1) < i64(len(chunk)) {
			p.pos += 1
		}
	}

	state = .PartialRead
	p.pos = start
	return
}

the_skipper :: proc(trace: ^Trace, jp: ^JSONParser, chunk: []u8) -> JSONState {
	p := &trace.parser

	// speed-skip until we have data we care about
	if !jp.got_first_char {
		ret := eat_spaces(trace, chunk)
		if !ret {
			return .PartialRead
		}

		ch := chunk[chunk_pos(p)]
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
	for ; chunk_pos(p) < i64(len(chunk)); p.pos += 1 {
		ch := chunk[chunk_pos(p)]

		switch ch {
		case '"': 
			start := real_pos(p)

			key, state := skip_string(trace, chunk)
			if state == .PartialRead {
				p.pos = start
				return .PartialRead
			}

			key_str := string(chunk[key.start:key.end])
			if jp.skipper_objs == 1 && key_str == "traceEvents" {
				ret := eat_spaces(trace, chunk)
				if !ret {
					p.pos = start
					return .PartialRead
				}

				ch := chunk[chunk_pos(p)]
				if ch != ':' {
					fmt.printf("Your JSON file is invalid! got %c, expected :\n", ch)
					push_fatal(SpallError.InvalidFile)
				}
				p.pos += 1

				ret = eat_spaces(trace, chunk)
				if !ret {
					p.pos = start
					return .PartialRead
				}

				ch = chunk[chunk_pos(p)]
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
skip_to_start_or_end :: proc(trace: ^Trace, chunk: []u8) -> JSONState {
	p := &trace.parser

	ret := eat_spaces(trace, chunk)
	if !ret {
		return .PartialRead
	}

	ch := chunk[chunk_pos(p)]
	if ch == '{' || ch == ']' {
		return .Finished
	}

	if ch == ',' {
		p.pos += 1

		ret = eat_spaces(trace, chunk)
		if !ret {
			return .PartialRead
		}

		ch = chunk[chunk_pos(p)]
		if ch == '{' || ch == ']' {
			return .Finished
		}
	}

	fmt.printf("Unable to find next event! %c\n", ch)
	push_fatal(SpallError.InvalidFile)
}

process_key_value :: proc(trace: ^Trace, ev: ^TempEvent, key: FieldType, value: string) #no_bounds_check {
	#partial switch key {
	case .Name:
		str := in_get(&trace.intern, &trace.string_block, value)
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
		ev.duration = i64(dur * 1000)
	case .Ts: 
		ts, ok := parse_f64(value)
		if !ok {
			fmt.printf("Invalid number!\n")
			push_fatal(SpallError.InvalidFile)
		}
		ev.timestamp = i64(ts * 1000)
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

process_sample :: proc(trace: ^Trace, jp: ^JSONParser, ev: ^TempEvent) {
	p := &trace.parser
	new_event: JSONEvent = ---

	meta_str := in_getstr(&trace.string_block, ev.name)
	profile_key := u64(ev.process_id) << 32 | u64(ev.thread_id)
	if meta_str == "Profile" {
		blob, err := json.parse_string(in_getstr(&trace.string_block, ev.args), json.DEFAULT_SPECIFICATION, false, scratch2_allocator)
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
		start_time_us, ok2 := data_map["startTime"].(json.Float)
		if !ok2 {
			fmt.printf("Invalid %s\n", meta_str)
			push_fatal(SpallError.InvalidFile)
		}
		free_all(scratch2_allocator)

		p_idx := setup_pid(trace, ev.process_id)
		t_idx := setup_tid(trace, p_idx, ev.thread_id)

		ps := ProfileState{
			pid = ev.process_id,
			tid = ev.thread_id,
			time = i64(start_time_us * 1000),
			nodes = make(map[i64]SampleNode, 16, big_global_allocator),
		}
		stack_init(&ps.id_stack, scratch_allocator)

		jp.profiles[profile_key] = ps
	} else if meta_str == "ProfileChunk" {
		p_idx := setup_pid(trace, ev.process_id)
		t_idx := setup_tid(trace, p_idx, ev.thread_id)

		profile, ok := &jp.profiles[profile_key]
		if !ok {
			ps := ProfileState{
				pid   = ev.process_id,
				tid   = ev.thread_id,
				time  = ev.timestamp,
				nodes = make(map[i64]SampleNode, 16, big_global_allocator),
			}
			stack_init(&ps.id_stack, scratch_allocator)
			jp.profiles[profile_key] = ps
			profile, _ = &jp.profiles[profile_key]
		}

		thread := &trace.processes[p_idx].threads[t_idx]

		chunk := ChunkArgs{}
		err := json.unmarshal_string(in_getstr(&trace.string_block, ev.args), &chunk, json.DEFAULT_SPECIFICATION, scratch2_allocator)
		if err != nil {
			fmt.printf("Failed to parse args?\n")
			push_fatal(SpallError.InvalidFile)
		}

		for node in chunk.data.cpuProfile.nodes {
			func_name := in_get(&trace.intern, &trace.string_block, node.callFrame.functionName)
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

			profile.time += i64(delta * 1000)
			stack_top_id : i64 = 0
			if profile.id_stack.len > 0 {
				tmp := stack_peek_back(&profile.id_stack)
				stack_top_id = tmp.node_id
			}

			// keep accruing dt
			if stack_top_id == cur_sample_id {
				continue
			}

			if cur_sample_node.is_other && in_getstr(&trace.string_block, cur_sample_node.name) == "(garbage collector)" {

				// ugh. thanks Google. GC events are weird.
				mem.zero(&new_event, size_of(JSONEvent))
				new_event.name = cur_sample_node.name
				new_event.duration = -1
				new_event.timestamp = profile.time

				_, _, e_idx := json_push_event(trace, ev.process_id, ev.thread_id, &new_event)

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
					json_patch_end(trace, p_idx, t_idx, sample.event_idx, profile.time)
				}

				for i := len(nodes_to_begin) - 1; i >= 0; i -= 1 {
					node_id := nodes_to_begin[i]
					node := profile.nodes[node_id]

					if node.name == 0 {
						node.name = in_get(&trace.intern, &trace.string_block, "(anonymous)")
					}

					mem.zero(&new_event, size_of(JSONEvent))
					new_event.name = node.name
					new_event.duration = -1
					new_event.timestamp = profile.time

					_, _, e_idx := json_push_event(trace, ev.process_id, ev.thread_id, &new_event)
					sample := Sample{node_id = node_id, event_idx = i64(e_idx)}
					stack_push_back(&profile.id_stack, sample)
				}
			}
		}
		free_all(scratch2_allocator)
	}
}

process_event :: proc(trace: ^Trace, jp: ^JSONParser, ev: ^TempEvent) {
	#partial switch ev.type {
	case .Instant:
		json_push_instant(trace, ev)
	case .Complete:
		new_event := JSONEvent{
			name = ev.name,
			args = ev.args,
			duration = ev.duration,
			self_time = ev.duration,
			timestamp = ev.timestamp,
		}
		json_push_event(trace, u32(ev.process_id), u32(ev.thread_id), &new_event)
	case .Begin:
		new_event := JSONEvent{
			name = ev.name,
			args = ev.args,
			duration = -1,
			timestamp = ev.timestamp,
		}

		p_idx, t_idx, e_idx := json_push_event(trace, u32(ev.process_id), u32(ev.thread_id), &new_event)

		thread := &trace.processes[p_idx].threads[t_idx]
		stack_push_back(&thread.bande_q, EVData{idx = e_idx, depth = 0, self_time = -1})
	case .End:
		p_idx, ok1 := vh_find(&trace.process_map, u32(ev.process_id))
		if !ok1 {
			fmt.printf("Invalid pid: %d\n", ev.process_id)
			push_fatal(SpallError.InvalidFile)
		}
		t_idx, ok2 := vh_find(&trace.processes[p_idx].thread_map, u32(ev.thread_id))
		if !ok2 {
			fmt.printf("Invalid tid: %d\n", ev.thread_id)
			push_fatal(SpallError.InvalidFile)
		}

		thread := &trace.processes[p_idx].threads[t_idx]
		if thread.bande_q.len > 0 {
			jev_data := stack_pop_back(&thread.bande_q)
			jev := &thread.json_events[jev_data.idx]
			jev.duration = ev.timestamp - jev.timestamp
			jev.self_time = jev.duration
			thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
			trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)
		}
	case .Sample:
		process_sample(trace, jp, ev)
	case .Metadata:
		meta_str := in_getstr(&trace.string_block, ev.name)
		if meta_str == "thread_name" || meta_str == "process_name" {
			blob, err := json.parse_string(in_getstr(&trace.string_block, ev.args), json.DEFAULT_SPECIFICATION, false, scratch2_allocator)
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

			name := in_get(&trace.intern, &trace.string_block, m_name)
			free_all(scratch2_allocator)

			if meta_str == "thread_name" {
				p_idx := setup_pid(trace, ev.process_id)
				t_idx := setup_tid(trace, p_idx, ev.thread_id)
				trace.processes[p_idx].threads[t_idx].name = name
			} else if meta_str == "process_name" {
				p_idx := setup_pid(trace, ev.process_id)
				trace.processes[p_idx].name = name
			}
		}
	}
}

process_next_json_event :: proc(trace: ^Trace, jp: ^JSONParser, chunk: []u8) -> (state: JSONState) #no_bounds_check {
	p := &trace.parser
	start := real_pos(p)

	// skip to the start of the next event, or quit if we've got them all
	ret := skip_to_start_or_end(trace, chunk)
	if ret == .PartialRead {
		p.pos = start
		state = .PartialRead
		return
	}

	if chunk[chunk_pos(p)] == ']' {
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
	for ; chunk_pos(p) < i64(len(chunk)); p.pos += 1 {
		ch := chunk[chunk_pos(p)]
		class := char_class[ch]
		next_state := dfa[jp.state][class]
		jp.state = next_state

		if next_state != .String && next_state != .Escape && in_string {
			str := string(chunk[str_start:chunk_pos(p)])
			if depth_count == 1 {
				if in_key {
					key_type, _ = km_find(&jp.obj_map, str)
				} else {
					process_key_value(trace, &ev, key_type, str)
					key_type = .Invalid
				}
			}

			in_string = false
		} else if next_state != .Primitive && in_primitive {
			str := string(chunk[primitive_start:chunk_pos(p)])
			if depth_count == 1 {
				process_key_value(trace, &ev, key_type, str)
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
				str := string(chunk[args_start:chunk_pos(p)+1])

				// skip storing args: {}
				if len(str) > 2 {
					ev.args = in_get(&trace.intern, &trace.string_block, str)
				}

				key_type = .Invalid
			} else if depth_count == 0 {
				p.pos += 1
				state = .EventDone

				process_event(trace, jp, &ev)
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
load_json_chunk :: proc (trace: ^Trace, chunk: []u8) {
	p := &trace.parser
	jp := &trace.json_parser

	hot_loop: for p.pos <= i64(p.total_size) {
		// skip until we hit the start of the traceEvents arr
		if !jp.event_start {
			state := the_skipper(trace, jp, chunk)
			if p.pos >= i64(p.total_size) {
				break hot_loop
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
		state := process_next_json_event(trace, jp, chunk)
		#partial switch state {
		case .PartialRead:
			if p.pos == last_read {
				fmt.printf("Invalid trailing data? dropping from [%d -> %d] (%d bytes)\n", p.pos, p.total_size, i64(p.total_size) - p.pos)
				break hot_loop
			} else {
				last_read = p.pos
			}

			p.offset = p.pos
			get_chunk(f64(p.pos), f64(CHUNK_SIZE))
			return
		case .Finished:
			break hot_loop
		}
	}

	for _, profile in &jp.profiles {
		p_idx, ok1 := vh_find(&trace.process_map, profile.pid)
		if !ok1 {
			fmt.printf("finish_loading | invalid end in profile?\n")
			continue
		}

		t_idx, ok2 := vh_find(&trace.processes[p_idx].thread_map, profile.tid)
		if !ok2 {
			fmt.printf("finish_loading | invalid end in profile?\n")
			continue
		}

		for i := profile.id_stack.len - 1; i >= 0; i -= 1 {
			sample := stack_pop_back(&profile.id_stack)
			json_patch_end(trace, p_idx, t_idx, sample.event_idx, profile.time)
			node := profile.nodes[sample.node_id]
		}
	}

	free_all(scratch2_allocator)
	finish_loading(trace)
	return
}

json_patch_end :: proc(trace: ^Trace, p_idx, t_idx: i32, e_idx: i64, end_time: i64) {
	thread := &trace.processes[p_idx].threads[t_idx]
	jev := &thread.json_events[e_idx]
	jev.duration = end_time - jev.timestamp
	jev.self_time = jev.duration

	thread.max_time = max(thread.max_time, jev.timestamp + jev.duration)
	trace.total_max_time = max(trace.total_max_time, jev.timestamp + jev.duration)
}

json_push_instant :: proc(trace: ^Trace, event: ^TempEvent) {
	instant := Instant{
		name = event.name,
		timestamp = event.timestamp,
	}

	instant_count += 1

	if event.scope == .Global {
		append(&trace.global_instants, instant)
		return
	}

	p_idx := setup_pid(trace, event.process_id)
	p := &trace.processes[p_idx]

	if event.scope == .Process {
		append(&p.instants, instant)
		return
	}

	t_idx := setup_tid(trace, p_idx, event.thread_id)

	t := &p.threads[t_idx]
	if event.scope == .Thread {
		append(&t.instants, instant)
		return
	}
}


json_push_event :: proc(trace: ^Trace, process_id, thread_id: u32, event: ^JSONEvent) -> (i32, i32, i32) {
	p_idx := setup_pid(trace, process_id)
	t_idx := setup_tid(trace, p_idx, thread_id)

	trace.event_count += 1

	p := &trace.processes[p_idx]
	p.min_time = min(p.min_time, event.timestamp)

	t := &p.threads[t_idx]
	t.min_time = min(t.min_time, event.timestamp)
	t.max_time = max(t.max_time, event.timestamp + event.duration)

	trace.total_min_time = min(trace.total_min_time, event.timestamp)
	trace.total_max_time = max(trace.total_max_time, event.timestamp + event.duration)

	append(&t.json_events, event^)
	return p_idx, t_idx, i32(len(t.json_events)-1)
}

pid_sort_proc :: proc(a, b: Process) -> bool { return a.min_time < b.min_time }
tid_sort_proc :: proc(a, b: Thread) -> bool  { return a.min_time < b.min_time }
instant_rendersort_proc :: proc(a, b: Instant) -> bool {
	return a.timestamp < b.timestamp
}

// duration bounding is important when sorting, we don't want to accidentally a -1 somewhere
insertion_sort_events :: proc(events: []JSONEvent, max_time: i64) {
	event_buildsort :: proc(max_time: i64, a, b: JSONEvent) -> bool {
		if a.timestamp == b.timestamp {
			return bound_duration(a, max_time) > bound_duration(b, max_time)
		}
		return a.timestamp < b.timestamp
	}

	for i := 1; i < len(events); i += 1 {
		j := i - 1

		temp := events[i]
		for ; j >= 0 && event_buildsort(max_time, temp, events[j]); {
			events[j+1] = events[j]
			j -= 1
		}

		events[j+1] = temp
	}
}

json_process_events :: proc(trace: ^Trace) {
	ev_stack: Stack(i32)
	stack_init(&ev_stack, context.temp_allocator)

	slice.sort_by(trace.global_instants[:], instant_rendersort_proc)

	for pe, _ in trace.process_map.entries {
		proc_idx := pe.val
		process := &trace.processes[proc_idx]

		slice.sort_by(process.threads[:], tid_sort_proc)

		// generate depth mapping
		for tm in &process.threads {
			if len(tm.json_events) == 0 {
				continue
			}

			insertion_sort_events(tm.json_events[:], tm.max_time)

			free_all(scratch2_allocator)
			depth_counts := make([dynamic]u32, 0, 64, scratch2_allocator)

			stack_clear(&ev_stack)
			for event, e_idx in &tm.json_events {
				cur_start := event.timestamp
				cur_end   := event.timestamp + bound_duration(event, tm.max_time)
				if ev_stack.len == 0 {
					stack_push_back(&ev_stack, i32(e_idx))
				} else {
					prev_e_idx := stack_peek_back(&ev_stack)
					prev_ev := tm.json_events[prev_e_idx]

					prev_start := prev_ev.timestamp
					prev_end   := prev_ev.timestamp + bound_duration(prev_ev, tm.max_time)

					// if it fits within the parent
					if cur_start >= prev_start && cur_end <= prev_end {
						stack_push_back(&ev_stack, i32(e_idx))
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
						stack_push_back(&ev_stack, i32(e_idx))
					}
				}

				cur_depth := ev_stack.len - 1
				if len(depth_counts) <= cur_depth {
					append(&depth_counts, 0)
				}
				depth_counts[cur_depth] += 1
				event.depth = u16(cur_depth)
			}

			depth_offsets := make([]u32, len(depth_counts), scratch2_allocator)
			cur_offset : u32 = 0
			for i := 0; i < len(depth_counts); i += 1 {
				depth_offsets[i] = cur_offset
				cur_offset += depth_counts[i]
			}

			depth_counters := make([]u32, len(depth_counts), scratch2_allocator)
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

			ev_start : u32 = 0
			for i := 0; i < len(depth_counts); i += 1 {
				count := depth_counts[i]
				temp_events := slice_to_dyn(sorted_events[ev_start:ev_start+count])
				depth := Depth{
					events = temp_events,
				}
				ev_start += count
				append(&tm.depths, depth)
			}
		}
	}

	slice.sort_by(trace.processes[:], pid_sort_proc)
	return
}

json_generate_selftimes :: proc(trace: ^Trace) {
	for proc_v, p_idx in &trace.processes {
		for tm, t_idx in &proc_v.threads {

			// skip the bottom rank, it's already set up correctly
			if len(tm.depths) == 1 {
				continue
			}

			for depth, d_idx in &tm.depths {
				// skip the last depth
				if d_idx == (len(tm.depths) - 1) {
					continue
				}

				for ev, e_idx in &depth.events {
					depth := &tm.depths[d_idx+1]
					tree := &depth.tree

					tree_stack := [128]int{}
					stack_len := 0

					start_time := ev.timestamp - trace.total_min_time
					end_time := ev.timestamp + bound_duration(&ev, tm.max_time) - trace.total_min_time

					child_time : i64 = 0
					tree_stack[0] = 0; stack_len += 1
					for stack_len > 0 {
						stack_len -= 1

						tree_idx := tree_stack[stack_len]
						cur_node := tree[tree_idx]

						if end_time < cur_node.start_time || start_time > cur_node.end_time {
							continue
						}

						if cur_node.start_time >= start_time && cur_node.end_time <= end_time {
							child_time += cur_node.weight
							continue
						}

						child_count := get_child_count(depth, tree_idx)
						if child_count <= 0 {
							event_count := get_event_count(depth, tree_idx)
							event_start_idx := get_event_start_idx(depth, tree_idx)
							scan_arr := depth.events[event_start_idx:event_start_idx+event_count]
							weight : i64 = 0
							scan_loop: for scan_ev in &scan_arr {
								scan_ev_start_time := scan_ev.timestamp - trace.total_min_time
								if scan_ev_start_time < start_time {
									continue
								}

								scan_ev_end_time := scan_ev.timestamp + bound_duration(&scan_ev, tm.max_time) - trace.total_min_time
								if scan_ev_end_time > end_time {
									break scan_loop
								}

								weight += bound_duration(&scan_ev, tm.max_time)
							}
							child_time += weight
							continue
						}

						for i := child_count; i > 0; i -= 1 {
							tree_stack[stack_len] = get_left_child(tree_idx) + i - 1; stack_len += 1
						}
					}

					ev.self_time = bound_duration(&ev, tm.max_time) - child_time
				}
			}
		}
	}
}
