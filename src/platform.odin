package main

import "core:mem"
import "core:runtime"
import "core:fmt"
import "core:container/queue"
import "core:strings"
import "core:strconv"

shift_down := false

@export
set_text_height :: proc "contextless" (height: f32) {
	text_height = height
	line_gap = height + (height * (3/4))
}

// eww, this is not a good way to do it
last_frame_count := 0

@export
mouse_move :: proc "contextless" (x, y: f32) {
	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}

	mouse_pos = Vec2{x, y}
}

@export
mouse_down :: proc "contextless" (x, y: f32) {
	is_mouse_down = true
	mouse_pos = Vec2{x, y}

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}

	clicked = true
	clicked_pos = mouse_pos
}

@export
mouse_up :: proc "contextless" (x, y: f32) {
	is_mouse_down = false

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}
	mouse_pos = Vec2{x, y}
}

@export
scroll :: proc "contextless" (x, y: f64) {
	zoom_velocity += y
}

@export
zoom :: proc "contextless" (x, y: f64) {
	zoom_velocity += y
}

@export
key_down :: proc "contextless" (key: int) { }

@export
key_up :: proc "contextless" (key: int) { }

@export
text_input :: proc "contextless" (key, code: string) { }

@export
blur :: proc "contextless" () {}

@export
temp_allocate :: proc(n: int) -> rawptr {
    context = wasmContext
    return mem.alloc(n, mem.DEFAULT_ALIGNMENT, context.temp_allocator)
}

// This is gross..
@export
loaded_session_result :: proc "contextless" (key, val: string) {
}

@export
load_build_hash :: proc "contextless" (_hash: int) {
	hash = _hash
}

CHUNK_SIZE :: 1024 * 1024

get_token_str :: proc(p: ^Parser, tok: Token) -> string {
	str := string(p.full_chunk[int(tok.start)-p.chunk_start:int(tok.end)-p.chunk_start])
	return str
}

is_obj_start :: proc(p: ^Parser, tok: Token, state: JSONState, key: string, depth: int) -> bool {
	return is_scoped_start(p, tok, state, key, .Object, depth)
}

is_arr_start :: proc(p: ^Parser, tok: Token, state: JSONState, key: string, depth: int) -> bool {
	return is_scoped_start(p, tok, state, key, .Array, depth)
}

is_scoped_start :: proc(p: ^Parser, tok: Token, state: JSONState, key: string, type: TokenType, depth: int) -> bool {
	cur_depth := queue.len(p.parent_stack)
	if state == .ScopeEntered && tok.type == type && cur_depth > 1 && (cur_depth - 2) == depth {
		parent := queue.get_ptr(&p.parent_stack, cur_depth - 2)
		return key == get_token_str(p, parent^)
	}
	return false
}

events_id: int
cur_event_id: int

obj_map: map[string]string
parent_map: map[int]string
seen_pair_map: map[string]bool
cur_event: Event

reset_token_maps :: proc() {
	clear_map(&parent_map)
	clear_map(&seen_pair_map)
}

manual_load :: proc(config: string) {
	init_loading_state(len(config))
	load_config_chunk(0, len(config), transmute([]u8)config)
}

init_loading_state :: proc(size: int) {
	loading_config = true

	free_all(context.allocator)
	free_all(context.temp_allocator)

	events = make([dynamic]Event)	

	fields := []string{ "dur", "name", "pid", "tid", "ts" }
	obj_map = make(map[string]string, 0, scratch_allocator)

	for field in fields {
		obj_map[field] = field
	}

	parent_map    = make(map[int]string, 0, scratch_allocator)
	seen_pair_map = make(map[string]bool, 0, scratch_allocator)
	cur_event = Event{}
	events_id    = -1
	cur_event_id = -1

	fmt.printf("Loading a %.1f MB config\n", f32(size) / 1024 / 1024)
	start_bench("tokenize config")
	p = init_parser(size)
}

@export
start_loading_file :: proc "contextless" (size: int) {
	context = wasmContext

	init_loading_state(size)
	get_chunk(p.pos, CHUNK_SIZE)
}

// this is gross + brittle. I'm sorry. I need a better way to do JSON streaming
@export
load_config_chunk :: proc "contextless" (start, total_size: int, chunk: []u8) -> bool {
	context = wasmContext
	defer free_all(context.temp_allocator)

	hot_loop: for {
		tok, state := get_next_token(&p, start, chunk, chunk[chunk_pos(&p):], start+chunk_pos(&p))

		#partial switch state {
		case .PartialRead:
			p.offset = p.pos
			get_chunk(p.pos, CHUNK_SIZE)
			return true
		case .InvalidToken:
			trap()
			return false
		case .Finished:
			stop_bench("tokenize config")
			fmt.printf("Got %d events!\n", len(events))

			config_updated = true
			init()
			loading_config = false
			return true
		}

		// get start of traceEvents
		if events_id == -1 {
			if is_arr_start(&p, tok, state, "traceEvents", 1) {
				events_id = tok.id
			}
			continue
		}

		// get start of an event
		if cur_event_id == -1 {
			depth := queue.len(p.parent_stack)
			if depth > 1 {
				parent := queue.get_ptr(&p.parent_stack, depth - 2)
				if state == .ScopeEntered && tok.type == .Object && parent.id == events_id {
					cur_event_id = tok.id
				}
			}
			continue
		}

		// eww.
		depth := queue.len(p.parent_stack)
		parent := queue.get_ptr(&p.parent_stack, depth - 1)
		if parent.id == tok.id {
			parent = queue.get_ptr(&p.parent_stack, depth - 2)
		}

		// gather keys for event
		if state == .TokenDone && tok.type == .String && parent.id == cur_event_id {
			key := get_token_str(&p, tok)
			if key in obj_map {
				parent_map[tok.id] = obj_map[key]
			}
			continue
		}


		// gather values for event
		if state == .TokenDone &&
		   (tok.type == .String || tok.type == .Primitive) {

			if !(parent.id in parent_map) {
				continue
			}

			key := parent_map[parent.id]
			value := get_token_str(&p, tok)

			if key == "name" {
				cur_event.name = strings.clone(value)
			}

			switch parent_map[parent.id] {
			case "dur": 
				dur, ok := strconv.parse_u64(value)
				if !ok { continue }
				cur_event.duration = dur
			case "ts": 
				ts, ok := strconv.parse_u64(value)
				if !ok { continue }
				cur_event.timestamp = ts
			case "tid": 
				tid, ok := strconv.parse_u64(value)
				if !ok { continue }
				cur_event.thread_id = tid
			case "pid": 
				pid, ok := strconv.parse_u64(value)
				if !ok { continue }
				cur_event.process_id = pid
			}

			seen_pair_map[key] = true
			continue
		}

		// got the whole event
		if state == .ScopeExited && tok.id == cur_event_id {
			if ("dur" in seen_pair_map) {
				append(&events, cur_event)
			}

			cur_event = Event{}
			reset_token_maps()
			cur_event_id = -1
			continue
		}
	}

	return false
}

foreign import "js"

foreign js {
    canvas_clear :: proc() ---
    canvas_clip :: proc(x, y, w, h: f32) ---
    canvas_rect :: proc(x, y, w, h, radius: f32, r, g, b, a: f32) ---
    canvas_circle :: proc(x, y, radius: f32, r, g, b, a: f32) ---
    canvas_text :: proc(str: string, x, y: f32, r, g, b, a: f32, scale: f32, font: string) ---
    canvas_line :: proc(x1, y1, x2, y2: f32, r, g, b, a: f32, strokeWidth: f32) ---
    canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f32, r, g, b, a: f32, strokeWidth: f32) ---
    measure_text :: proc(str: string, scale: f32, font: string) -> f32 ---
    get_text_height :: proc(scale: f32, font: string) -> f32 ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---

	get_session_storage :: proc(key: string) ---
	set_session_storage :: proc(key: string, val: string) ---
	get_time :: proc() -> f64 ---
	change_cursor :: proc(cursor: string) ---
	get_system_color :: proc() -> bool ---

	get_chunk :: proc(offset: int, size: int) ---
}

draw_rect :: proc(rect: Rect, radius: f32, color: Vec3, a: f32 = 255) {
    canvas_rect(rect.pos.x, rect.pos.y, rect.size.x, rect.size.y, radius, color.x, color.y, color.z, a)
}
draw_circle :: proc(center: Vec2, radius: f32, color: Vec3, a: f32 = 255) {
    canvas_circle(center.x, center.y, radius, color.x, color.y, color.z, a)
}
draw_text :: proc(str: string, pos: Vec2, scale: f32, font: string, color: Vec3, a: f32 = 255) {
    canvas_text(str, pos.x, pos.y, color.x, color.y, color.z, a, scale, font)
}
draw_line :: proc(start, end: Vec2, strokeWidth: f32, color: Vec3, a: f32 = 255) {
    canvas_line(start.x, start.y, end.x, end.y, color.x, color.y, color.z, a, strokeWidth)
}
draw_arc :: proc(center: Vec2, radius, angleStart, angleEnd: f32, strokeWidth: f32, color: Vec3, a: f32) {
    canvas_arc(center.x, center.y, radius, angleStart, angleEnd, color.x, color.y, color.z, a, strokeWidth)
}

draw_rect_outline :: proc(rect: Rect, width: f32, color: Vec3, a: f32 = 255) {
	x1 := rect.pos.x
	y1 := rect.pos.y
	x2 := rect.pos.x + rect.size.x
	y2 := rect.pos.y + rect.size.y

	draw_line(Vec2{x1, y1}, Vec2{x2, y1}, width, color, a)
	draw_line(Vec2{x1, y1}, Vec2{x1, y2}, width, color, a)
	draw_line(Vec2{x2, y1}, Vec2{x2, y2}, width, color, a)
	draw_line(Vec2{x1, y2}, Vec2{x2, y2}, width, color, a)
}

set_cursor :: proc(cursor: string) {
	change_cursor(cursor)
	is_hovering = true
}

reset_cursor :: proc() {
	change_cursor("auto")
}
