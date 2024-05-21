package main

import "base:intrinsics"

import "core:mem"
import "core:fmt"

trap :: proc "contextless" () -> ! {
	intrinsics.trap()
}

update_font_cache :: proc() {
	em = _p_font_size
	p_font_size = _p_font_size
	h1_font_size = _h1_font_size
	h2_font_size = _h2_font_size

	p_height  = p_font_size
	h1_height = h1_font_size
	h2_height = h2_font_size
	ch_width  = measure_text("a", .PSize, .MonoFont)
}

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

	cur_time := t
	click_window := (cur_time - clicked_t) * 1000
	double_click_window_ms := 400.0

	if click_window < double_click_window_ms {
		double_clicked = true
	} else {
		double_clicked = false
	}

	clicked_t = cur_time
}

@export
mouse_up :: proc "contextless" (x, y: f64) {
	context = wasmContext

	is_mouse_down = false
	was_mouse_down = true
	mouse_up_now  = true

	if frame_count != last_frame_count {
		last_mouse_pos = mouse_pos
		last_frame_count = frame_count
	}
	mouse_pos = Vec2{x, y}
}

@export
scroll :: proc "contextless" (x, y: f64) { scroll_val_y += y }

@export
zoom :: proc "contextless" (x, y: f64) { scroll_val_y += y }

@export
key_down :: proc "contextless" (key: i32) { 
	switch key {
	case 1: // left-shift
		shift_down = true
	}
}

@export
key_up :: proc "contextless" (key: i32) { 
	switch key {
	case 1: // left-shift
		shift_down = false
	}
}

// release all control state if the user tabs away

intentional_blur := false
@export
blur :: proc "contextless" () {
	intentional_blur = true

	shift_down = false
	is_mouse_down = false
	was_mouse_down = false
	clicked = false
	clicked_pos = Vec2{}
}

@export
focus :: proc "contextless" () {
	if intentional_blur {
		shift_down = false
		is_mouse_down = false
		was_mouse_down = false
		clicked = false
		clicked_pos = Vec2{}
	}

	intentional_blur = false
}

@export
temp_allocate :: proc(n: i32) -> rawptr {
    context = wasmContext
    ptr, err := mem.alloc(int(n), mem.DEFAULT_ALIGNMENT, context.temp_allocator)
    if err != nil {
	    push_fatal(SpallError.OutOfMemory)
    }
    return ptr
}

// This is gross..
@export
loaded_session_result :: proc "contextless" (key, val: string) { }

@export
load_build_hash :: proc "contextless" (_hash: i32) { build_hash = _hash }

foreign import "js"

@(default_calling_convention="contextless")
foreign js {
    _canvas_clear  :: proc() ---
    _canvas_clip   :: proc(x, y, w, h: f64) ---
    _canvas_rect   :: proc(x, y, w, h: f64, r, g, b, a: f32) ---
    _canvas_rectc  :: proc(x, y, w, h, radius: f64, r, g, b, a: f32) ---
    _canvas_circle :: proc(x, y, radius: f64, r, g, b, a: f32) ---
    _canvas_text   :: proc(str: string, x, y: f64, r, g, b, a: f32, scale: f64, font: string) ---
    _canvas_line   :: proc(x1, y1, x2, y2: f64, r, g, b, a: f32, strokeWidth: f64) ---
    _canvas_arc    :: proc(x, y, radius, angleStart, angleEnd: f64, r, g, b, a: f32, strokeWidth: f64) ---

    _measure_text  :: proc(str: string, scale: f64, font: string) -> f64 ---
    _get_text_height :: proc(scale: f64, font: string) -> f64 ---

	_pow :: proc(x, power: f64) -> f64 ---

	_push_fatal :: proc(code: i32) ---

	_gl_init_frame :: proc(r, g, b, a: f32) ---
	_gl_push_rects :: proc(ptr: rawptr, byte_size, real_size: i32, y, height: f64) ---

	get_session_storage :: proc(key: string) ---
	set_session_storage :: proc(key: string, val: string) ---
	get_time :: proc() -> f64 ---
	change_cursor :: proc(cursor: string) ---
	get_system_color :: proc() -> bool ---

	get_chunk :: proc(offset, size: f64) ---
	open_file_dialog :: proc() ---
}

// a bunch of silly platform wrappers, so I can jam in dpr scaling
get_text_height :: #force_inline proc "contextless" (scale: FontSize, font: FontType) -> f64 {
	font_scale, font_type := get_font(scale, font)
	return _get_text_height(font_scale, font_type)
}

get_font :: proc "contextless" (scale: FontSize, type: FontType) -> (f64, string) {
	size : f64 = 0
	#partial switch scale {
	case .PSize:  size = p_font_size
	case .H1Size: size = h1_font_size
	case .H2Size: size = h2_font_size
	}

	font_str := ""
	#partial switch type {
	case .DefaultFont: font_str = `'Montserrat',-apple-system,BlinkMacSystemFont,segoe ui,Helvetica,Arial,sans-serif,apple color emoji,segoe ui emoji,segoe ui symbol`
	case .MonoFont:    font_str = `'Fira Code', monospace`
	case .IconFont:    font_str = `FontAwesome`
	}

	return size, font_str
}

measure_text :: #force_inline proc "contextless" (str: string, scale: FontSize, font: FontType) -> f64 {
	if len(str) == 0 {
		return 0
	}

	font_scale, font_type := get_font(scale, font)
	return _measure_text(str, font_scale, font_type)
}

gl_init_frame :: #force_inline proc "contextless" (color: BVec4) {
	_gl_init_frame(f32(color[0]), f32(color[1]), f32(color[2]), f32(color[3]))
}

gl_push_rects :: #force_inline proc "contextless" (rects: []DrawRect, y, height: f64) {
	_gl_push_rects(raw_data(rects), i32(len(rects) * size_of(DrawRect)), i32(len(rects)), y, height)
}

canvas_clear :: #force_inline proc "contextless" () {
	_canvas_clear()
}
draw_rect :: #force_inline proc "contextless" (rect: Rect, color: BVec4) {
    _canvas_rect(rect.x * dpr, rect.y * dpr, rect.w * dpr, rect.h * dpr, f32(color.x), f32(color.y), f32(color.z), f32(color.w))
}
draw_text :: #force_inline proc "contextless" (str: string, pos: Vec2, scale: FontSize, font: FontType, color: BVec4) {
	font_scale, font_type := get_font(scale, font)
    _canvas_text(str, pos.x, pos.y, f32(color.x), f32(color.y), f32(color.z), f32(color.w), font_scale, font_type)
}
draw_line :: #force_inline proc "contextless" (start, end: Vec2, strokeWidth: f64, color: BVec4) {
    _canvas_line(start.x * dpr, start.y * dpr, end.x * dpr, end.y * dpr, f32(color.x), f32(color.y), f32(color.z), f32(color.w), strokeWidth * dpr)
}

draw_rect_outline :: proc "contextless" (rect: Rect, width: f64, color: BVec4) {
	x1 := rect.x
	y1 := rect.y
	x2 := rect.x + rect.w
	y2 := rect.y + rect.h

	draw_line(Vec2{x1, y1}, Vec2{x2, y1}, width, color)
	draw_line(Vec2{x1, y1}, Vec2{x1, y2}, width, color)
	draw_line(Vec2{x2, y1}, Vec2{x2, y2}, width, color)
	draw_line(Vec2{x1, y2}, Vec2{x2, y2}, width, color)
}

draw_rect_inline :: proc "contextless" (rect: Rect, width: f64, color: BVec4) {
	x1 := rect.x + width
	y1 := rect.y + width
	x2 := rect.x + rect.w - width
	y2 := rect.y + rect.h - width

	draw_line(Vec2{x1, y1}, Vec2{x2, y1}, width, color)
	draw_line(Vec2{x1, y1}, Vec2{x1, y2}, width, color)
	draw_line(Vec2{x2, y1}, Vec2{x2, y2}, width, color)
	draw_line(Vec2{x1, y2}, Vec2{x2, y2}, width, color)
}

set_cursor :: proc "contextless" (cursor: string) {
	change_cursor(cursor)
	is_hovering = true
}
reset_cursor :: proc "contextless" () { change_cursor("auto") }

@export
set_dpr :: proc "contextless" (_dpr: f64) {
	dpr = _dpr 
}

push_fatal :: proc "contextless" (code: SpallError) -> ! {
	_push_fatal(i32(code))
	trap()
}
