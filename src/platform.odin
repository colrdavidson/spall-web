package main

import "core:mem"
import "core:runtime"
import "core:fmt"
import "core:container/queue"
import "core:strings"
import "core:strconv"
import "core:c"

shift_down := false

@export
set_text_height :: proc "contextless" (_height: f32) {
	text_height = _height
	line_gap = 1.125 * _height
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

get_token_str :: proc(p: ^Parser, tok: Token) -> string {
	str := string(p.full_chunk[u32(tok.start)-p.chunk_start:u32(tok.end)-p.chunk_start])
	return str
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
	init_loading_state(u32(len(config)))
	load_config_chunk(0, u32(len(config)), transmute([]u8)config)
}

fields := []string{ "dur", "name", "pid", "tid", "ts" }
init_loading_state :: proc(size: u32) {
	loading_config = true

	free_all(scratch_allocator)
	free_all(context.allocator)
	free_all(context.temp_allocator)
	processes = make([dynamic]Process)
	process_map = make(map[u64]int, 0, scratch_allocator)
	total_max_time = 0
	total_min_time = c.UINT64_MAX

	obj_map = make(map[string]string, 0, scratch_allocator)
	for field in fields {
		obj_map[field] = field
	}

	parent_map    = make(map[int]string, 0, scratch_allocator)
	seen_pair_map = make(map[string]bool, 0, scratch_allocator)
	cur_event = Event{}
	events_id    = -1
	cur_event_id = -1
	event_count = 0

	fmt.printf("Loading a %.1f MB config\n", f64(size) / 1024 / 1024)
	start_bench("parse config")
	p = init_parser(size)
}

@export
start_loading_file :: proc "contextless" (size: u32) {
	context = wasmContext

	init_loading_state(u32(size))
	get_chunk(u32(p.pos), CHUNK_SIZE)
}

// this is gross + brittle. I'm sorry. I need a better way to do JSON streaming
@export
load_config_chunk :: proc "contextless" (start, total_size: u32, chunk: []u8) {
	context = wasmContext
	defer free_all(context.temp_allocator)

	set_next_chunk(&p, start, chunk)
	hot_loop: for {
		tok, state := get_next_token(&p)

		#partial switch state {
		case .PartialRead:
			p.offset = p.pos
			get_chunk(u32(p.pos), CHUNK_SIZE)
			return
		case .InvalidToken:
			trap()
			return
		case .Finished:
			stop_bench("parse config")
			fmt.printf("Got %d events and %d tokens!\n", event_count, p.tok_count)

			start_bench("process events")
			total_max_depth = process_events(&processes)
			stop_bench("process events")

			// reset render state
			color_choices = make([dynamic]Vec3)
			for i := 0; i < total_max_depth; i += 1 {
				r := f32(205 + rand_int(0, 50))
				g := f32(0 + rand_int(0, 230))
				b := f32(0 + rand_int(0, 55))

				append(&color_choices, Vec3{r, g, b})
			}

			t = 0
			frame_count = 0
			scale = 1
			pan = Vec2{}

			free_all(context.temp_allocator)
			free_all(scratch_allocator)

			loading_config = false
			return
		}

		depth := queue.len(p.parent_stack)

		// get start of traceEvents
		if events_id == -1 {
			if state == .ScopeEntered && tok.type == .Array && depth == 3 {
				parent := queue.get_ptr(&p.parent_stack, depth - 2)
				if "traceEvents" == get_token_str(&p, parent^) {
					events_id = tok.id
				}
			}
			continue
		}

		// get start of an event
		if cur_event_id == -1 {
			if depth > 1 && state == .ScopeEntered && tok.type == .Object {
				parent := queue.get_ptr(&p.parent_stack, depth - 2)
				if parent.id == events_id {
					cur_event_id = tok.id
				}
			}
			continue
		}

		// eww.
		parent := queue.get_ptr(&p.parent_stack, depth - 1)
		if parent.id == tok.id {
			parent = queue.get_ptr(&p.parent_stack, depth - 2)
		}

		// gather keys for event
		if state == .TokenDone && tok.type == .String && parent.id == cur_event_id {
			key := get_token_str(&p, tok)
			val, ok := obj_map[key]
			if ok {
				parent_map[tok.id] = val
			}
			continue
		}


		// gather values for event
		if state == .TokenDone &&
		   (tok.type == .String || tok.type == .Primitive) {

			key, ok := parent_map[parent.id]
			if !ok {
				continue
			}

			value := get_token_str(&p, tok)
			if key == "name" {
				str, err := strings.intern_get(&p.intern, value)
				if err != nil {
					return
				}

				cur_event.name = str
			}

			switch key {
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
				event_count += 1
				push_event(&processes, cur_event)
			}

			cur_event = Event{}
			reset_token_maps()
			cur_event_id = -1
			continue
		}
	}

	return
}

foreign import "js"

foreign js {
    _canvas_clear :: proc() ---
    _canvas_clip :: proc(x, y, w, h: f32) ---
    _canvas_rect :: proc(x, y, w, h: f32, r, g, b, a: f32) ---
    _canvas_rectc :: proc(x, y, w, h, radius: f32, r, g, b, a: f32) ---
    _canvas_circle :: proc(x, y, radius: f32, r, g, b, a: f32) ---
    _canvas_text :: proc(str: string, x, y: f32, r, g, b, a: f32, scale: f32, font: string) ---
    _canvas_line :: proc(x1, y1, x2, y2: f32, r, g, b, a: f32, strokeWidth: f32) ---
    _canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f32, r, g, b, a: f32, strokeWidth: f32) ---
    _measure_text :: proc(str: string, scale: f32, font: string) -> f32 ---
    _get_text_height :: proc(scale: f32, font: string) -> f32 ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---

	get_session_storage :: proc(key: string) ---
	set_session_storage :: proc(key: string, val: string) ---
	get_time :: proc() -> f64 ---
	change_cursor :: proc(cursor: string) ---
	get_system_color :: proc() -> bool ---

	get_chunk :: proc(offset, size: u32) ---
}

get_text_height :: #force_inline proc(scale: f32, font: string) -> f32 {
	return _get_text_height(scale, font)
}

measure_text :: #force_inline proc(str: string, scale: f32, font: string) -> f32 {
	return _measure_text(str, scale, font)
}

canvas_clear :: #force_inline proc() {
	_canvas_clear()
}
draw_clip :: #force_inline proc(x, y, w, h: f32) {
	_canvas_clip(x * dpr, y * dpr, w * dpr, h * dpr)
}
draw_rect :: #force_inline proc(rect: Rect, color: Vec3, a: f32 = 255) {
    _canvas_rect(rect.pos.x * dpr, rect.pos.y * dpr, rect.size.x * dpr, rect.size.y * dpr, color.x, color.y, color.z, a)
}
draw_rectc :: #force_inline proc(rect: Rect, radius: f32, color: Vec3, a: f32 = 255) {
    _canvas_rectc(rect.pos.x * dpr, rect.pos.y * dpr, rect.size.x * dpr, rect.size.y * dpr, radius * dpr, color.x, color.y, color.z, a)
}
draw_circle :: #force_inline proc(center: Vec2, radius: f32, color: Vec3, a: f32 = 255) {
    _canvas_circle(center.x * dpr, center.y * dpr, radius * dpr, color.x, color.y, color.z, a)
}
draw_text :: #force_inline proc(str: string, pos: Vec2, scale: f32, font: string, color: Vec3, a: f32 = 255) {
    _canvas_text(str, pos.x, pos.y, color.x, color.y, color.z, a, scale, font)
}
draw_line :: #force_inline proc(start, end: Vec2, strokeWidth: f32, color: Vec3, a: f32 = 255) {
    _canvas_line(start.x * dpr, start.y * dpr, end.x * dpr, end.y * dpr, color.x, color.y, color.z, a, strokeWidth * dpr * dpr)
}
draw_arc :: #force_inline proc(center: Vec2, radius, angleStart, angleEnd: f32, strokeWidth: f32, color: Vec3, a: f32) {
    _canvas_arc(center.x * dpr, center.y * dpr, radius * dpr, angleStart, angleEnd, color.x, color.y, color.z, a, strokeWidth * dpr)
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

@export
set_dpr :: proc "contextless" (v: f32) {
	dpr = v
}
