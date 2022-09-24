package main

import "core:mem"
import "core:fmt"

update_font_cache :: proc "contextless" () {
	context = wasmContext

	em = get_text_height(p_font_size, monospace_font)
	h1_height = get_text_height(h1_font_size, default_font)
	h2_height = get_text_height(h2_font_size, default_font)
	ch_width = measure_text("a", p_font_size, monospace_font)
}

// eww, this is not a good way to do it
last_frame_count := 0

@export
mouse_move :: proc "contextless" (x, y: f64) {
	context = wasmContext

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}

	mouse_pos = Vec2{x, y}
}

@export
mouse_down :: proc "contextless" (x, y: f64) {
	context = wasmContext

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
mouse_up :: proc "contextless" (x, y: f64) {
	context = wasmContext

	is_mouse_down = false
	was_mouse_down = true

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}
	mouse_pos = Vec2{x, y}
}

@export
scroll :: proc "contextless" (x, y: f64) {
	scroll_val_y += y
}

@export
zoom :: proc "contextless" (x, y: f64) {
	scroll_val_y += y
}

shift_down := false
@export
key_down :: proc "contextless" (key: int) { 
	switch key {
	case 1: // left-shift
		shift_down = true
	}
}

@export
key_up :: proc "contextless" (key: int) { 
	switch key {
	case 1: // left-shift
		shift_down = false
	}
}

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
loaded_session_result :: proc "contextless" (key, val: string) { }

@export
load_build_hash :: proc "contextless" (_hash: int) {
	build_hash = _hash
}

foreign import "js"

foreign js {
    _canvas_clear :: proc() ---
    _canvas_clip :: proc(x, y, w, h: f64) ---
    _canvas_rect :: proc(x, y, w, h: f64, r, g, b, a: f64) ---
    _canvas_rectc :: proc(x, y, w, h, radius: f64, r, g, b, a: f64) ---
    _canvas_circle :: proc(x, y, radius: f64, r, g, b, a: f64) ---
    _canvas_text :: proc(str: string, x, y: f64, r, g, b, a: f64, scale: f64, font: string) ---
    _canvas_line :: proc(x1, y1, x2, y2: f64, r, g, b, a: f64, strokeWidth: f64) ---
    _canvas_arc :: proc(x, y, radius, angleStart, angleEnd: f64, r, g, b, a: f64, strokeWidth: f64) ---
    _measure_text :: proc(str: string, scale: f64, font: string) -> f64 ---
    _get_text_height :: proc(scale: f64, font: string) -> f64 ---
	_pow :: proc(x, power: f64) -> f64 ---

    debugger :: proc() ---
    log_string :: proc(str: string) ---
    log_error :: proc(str: string) ---

	_gl_init_frame :: proc(r, g, b, a: f64) ---
	_gl_push_rects :: proc(ptr: rawptr, byte_size, real_size: int, y, height: f64) ---

	get_session_storage :: proc(key: string) ---
	set_session_storage :: proc(key: string, val: string) ---
	get_time :: proc() -> f64 ---
	change_cursor :: proc(cursor: string) ---
	get_system_color :: proc() -> bool ---

	get_chunk :: proc(offset, size: u32) ---
	open_file_dialog :: proc() ---
}

get_text_height :: #force_inline proc "contextless" (scale: f64, font: string) -> f64 {
	return _get_text_height(scale, font)
}

measure_text :: #force_inline proc "contextless" (str: string, scale: f64, font: string) -> f64 {
	return _measure_text(str, scale, font)
}

gl_init_frame :: #force_inline proc "contextless" (color: Vec3) {
	_gl_init_frame(color.x, color.y, color.z, 255)
}

gl_push_rects :: #force_inline proc "contextless" (rects: []DrawRect, y, height: f64) {
	_gl_push_rects(raw_data(rects), len(rects) * size_of(DrawRect), len(rects), y, height)
}

canvas_clear :: #force_inline proc "contextless" () {
	_canvas_clear()
}
draw_clip :: #force_inline proc "contextless" (x, y, w, h: f64) {
	_canvas_clip(x * dpr, y * dpr, w * dpr, h * dpr)
}
draw_rect :: #force_inline proc "contextless" (rect: Rect, color: Vec3, a: f64 = 255) {
    _canvas_rect(rect.pos.x * dpr, rect.pos.y * dpr, rect.size.x * dpr, rect.size.y * dpr, color.x, color.y, color.z, a)
}
draw_rectc :: #force_inline proc "contextless" (rect: Rect, radius: f64, color: Vec3, a: f64 = 255) {
    _canvas_rectc(rect.pos.x * dpr, rect.pos.y * dpr, rect.size.x * dpr, rect.size.y * dpr, radius * dpr, color.x, color.y, color.z, a)
}
draw_circle :: #force_inline proc "contextless" (center: Vec2, radius: f64, color: Vec3, a: f64 = 255) {
    _canvas_circle(center.x * dpr, center.y * dpr, radius * dpr, color.x, color.y, color.z, a)
}
draw_text :: #force_inline proc "contextless" (str: string, pos: Vec2, scale: f64, font: string, color: Vec3, a: f64 = 255) {
    _canvas_text(str, pos.x, pos.y, color.x, color.y, color.z, a, scale, font)
}
draw_line :: #force_inline proc "contextless" (start, end: Vec2, strokeWidth: f64, color: Vec3, a: f64 = 255) {
    _canvas_line(start.x * dpr, start.y * dpr, end.x * dpr, end.y * dpr, color.x, color.y, color.z, a, strokeWidth * dpr * dpr)
}
draw_arc :: #force_inline proc "contextless" (center: Vec2, radius, angleStart, angleEnd: f64, strokeWidth: f64, color: Vec3, a: f64) {
    _canvas_arc(center.x * dpr, center.y * dpr, radius * dpr, angleStart, angleEnd, color.x, color.y, color.z, a, strokeWidth * dpr)
}

draw_rect_outline :: proc "contextless" (rect: Rect, width: f64, color: Vec3, a: f64 = 255) {
	x1 := rect.pos.x
	y1 := rect.pos.y
	x2 := rect.pos.x + rect.size.x
	y2 := rect.pos.y + rect.size.y

	draw_line(Vec2{x1, y1}, Vec2{x2, y1}, width, color, a)
	draw_line(Vec2{x1, y1}, Vec2{x1, y2}, width, color, a)
	draw_line(Vec2{x2, y1}, Vec2{x2, y2}, width, color, a)
	draw_line(Vec2{x1, y2}, Vec2{x2, y2}, width, color, a)
}

set_cursor :: proc "contextless" (cursor: string) {
	change_cursor(cursor)
	is_hovering = true
}

reset_cursor :: proc "contextless" () {
	change_cursor("auto")
}

@export
set_dpr :: proc "contextless" (v: f64) {
	dpr = v
	update_fonts = true
}
