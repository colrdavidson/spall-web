package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:runtime"
import "core:strings"
import "core:mem"
import "vendor:wasm/js"

global_arena := Arena{}
temp_arena := Arena{}
scratch_arena := Arena{}

global_allocator: mem.Allocator
scratch_allocator: mem.Allocator
temp_allocator: mem.Allocator

wasmContext := runtime.default_context()

t           : f32
frame_count : int

bg_color      := Vec3{}
bg_color2     := Vec3{}
text_color    := Vec3{}
text_color2   := Vec3{}
text_color3   := Vec3{}
button_color  := Vec3{}
button_color2 := Vec3{}
line_color    := Vec3{}
outline_color := Vec3{}
toolbar_color := Vec3{}

default_font   := `-apple-system,BlinkMacSystemFont,segoe ui,Helvetica,Arial,sans-serif,apple color emoji,segoe ui emoji,segoe ui symbol`
monospace_font := `monospace`
icon_font      := `FontAwesome`

EventID :: struct {
	pid: i64,
	tid: i64,
	eid: i64,
}

selected_event := EventID{-1, -1, -1}

dpr: f32

_p_font_size : f32 = 1
_h1_font_size : f32 = 1.25
_h2_font_size : f32 = 1.0625

p_font_size: f32
h1_font_size: f32
h2_font_size: f32

last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
zoom_velocity: f32 = 0
cam := Camera{Vec2{0, 0}, Vec2{0, 0}, 1}
division: int = 0

is_mouse_down := false
clicked       := false
is_hovering   := false

hash := 0

p: Parser

first_frame := true
loading_config := true
finished_loading := false
update_fonts := true
colormode := ColorMode.Dark

ColorMode :: enum {
	Dark,
	Light,
	Auto
}

em             : f32 = 0
h1_height      : f32 = 0
h2_height      : f32 = 0
ch_width       : f32 = 0
thread_gap     : f32 = 8

trace_config : string

processes: [dynamic]Process
process_map: map[u64]int
color_choices: [dynamic]Vec3
event_count: i64
total_max_time: u64
total_min_time: u64
total_max_depth: int

@export
set_color_mode :: proc "contextless" (auto: bool, is_dark: bool) {
	if is_dark {
		bg_color      = Vec3{15,   15,  15}
		bg_color2     = Vec3{0,     0,   0}
		text_color    = Vec3{255, 255, 255}
		text_color2   = Vec3{180, 180, 180}
		text_color3   = Vec3{0,     0,   0}
		button_color  = Vec3{40,   40,  40}
		button_color2 = Vec3{20,   20,  20}
		line_color    = Vec3{100, 100, 100}
		outline_color = Vec3{80,   80,  80}
		toolbar_color = Vec3{120, 120, 120}
	} else {
		bg_color      = Vec3{254, 252, 248}
		bg_color2     = Vec3{255, 255, 255}
		text_color    = Vec3{0,     0,   0}
		text_color2   = Vec3{80,   80,  80}
		text_color3   = Vec3{0, 0, 0}
		button_color  = Vec3{141, 119, 104}
		button_color2 = Vec3{191, 169, 154}
		line_color    = Vec3{150, 150, 150}
		outline_color = Vec3{219, 211, 205}
		toolbar_color = Vec3{219, 211, 205}
	}

	if auto {
		colormode = ColorMode.Auto
	} else {
		colormode = is_dark ? ColorMode.Dark : ColorMode.Light
	}
}

get_max_y_pan :: proc(processes: []Process, rect_height: f32) -> f32 {
	cur_y : f32 = 0

	for proc_v, _ in processes {
		h1_size := h1_height + (h1_height / 2)
		cur_y += h1_size
		for tm, _ in proc_v.threads {
			h2_size := h2_height + (h2_height / 2)
			cur_y += h2_size + ((f32(tm.max_depth) * rect_height) + thread_gap)
		}
	}

	return cur_y
}

generate_lod_rects :: proc(processes: ^[dynamic]Process, rect_height: f32) {
	//start_bench("generate LOD", context.temp_allocator)

	for proc_v, p_idx in processes {
		for tm, t_idx in &proc_v.threads {
			event_rects := make([dynamic]EventRect, 0, context.temp_allocator)

			for event, e_idx in tm.events {
				x := f32(event.timestamp - total_min_time)
				y := (rect_height * f32(event.depth - 1))
				w := f32(event.duration)
				h := rect_height

				append(&event_rects, 
					EventRect{
						r = rect(x, y, w, h),
						name = event.name,
						idx = e_idx,
						depth = event.depth,
					}
				)
			}

			tm.rects = event_rects[:]
		}
	}

	//stop_bench("generate LOD")
}

CHUNK_SIZE :: 10 * 1024 * 1024
main :: proc() {
	ONE_GB_PAGES :: 1 * 1024 * 1024 * 1024 / js.PAGE_SIZE
	ONE_MB_PAGES :: 1 * 1024 * 1024 / js.PAGE_SIZE
	temp_data, _    := js.page_alloc(ONE_MB_PAGES * 11)
	scratch_data, _ := js.page_alloc(ONE_MB_PAGES * 2)

    arena_init(&temp_arena, temp_data)
    arena_init(&scratch_arena, scratch_data)

	// This must be init last, because it grows infinitely. 
	// We don't want it accidentally growing into anything useful.
    growing_arena_init(&global_arena)

	// I'm doing olympic-level memory juggling BS in the ingest system because 
	// arenas are *special*, and memory is *precious*. Beware free_all()'ing 
	// the wrong one at the wrong time, here thar be dragons. Once you're in
	// normal render/frame space, I free_all temp once per frame, and I shouldn't
	// need to touch scratch
    temp_allocator = arena_allocator(&temp_arena)
    scratch_allocator = arena_allocator(&scratch_arena)
    global_allocator = growing_arena_allocator(&global_arena)

	wasmContext.allocator = global_allocator
	wasmContext.temp_allocator = temp_allocator

    context = wasmContext

	manual_load(default_config)
}

random_seed: u64

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
	defer frame_count += 1

	// This is nasty code that allows me to do load-time things once the wasm context is init
	if first_frame {
		random_seed = u64(get_time())
		fmt.printf("Seed is 0x%X\n", random_seed)
		rand.set_global_seed(random_seed)

		first_frame = false
	}

	// render loading screen
	if loading_config {
		pad_size : f32 = 3
		chunk_size : f32 = 10

		load_box := rect(0, 0, 100, 100)
		load_box = rect((width / 2) - (load_box.size.x / 2) - pad_size, (height / 2) - (load_box.size.y / 2) - pad_size, load_box.size.x + pad_size, load_box.size.y + pad_size)

		draw_rectc(load_box, 3, Vec3{50, 50, 50})

		chunk_count := int(rescale(f32(p.offset), 0, f32(p.total_size), 0, 100))

		chunk := rect(0, 0, chunk_size, chunk_size)
		start_x := load_box.pos.x + pad_size
		start_y := load_box.pos.y + pad_size
		for i := chunk_count; i >= 0; i -= 1 {
			cur_x := f32(i %% int(chunk_size))
			cur_y := f32(i /  int(chunk_size))
			draw_rect(rect(start_x + (cur_x * chunk_size), start_y + (cur_y * chunk_size), chunk_size - pad_size, chunk_size - pad_size), Vec3{0, 255, 0})
		}
		
		return true
	}

	defer {
		free_all(context.temp_allocator)
		if clicked {
			clicked = false
		}

		is_hovering = false
	}

    t += dt

	if (width / dpr) < 400 {
		p_font_size = _p_font_size * dpr
		h1_font_size = _h1_font_size * dpr
		h2_font_size = _h2_font_size * dpr
	} else {
		p_font_size = _p_font_size
		h1_font_size = _h1_font_size
		h2_font_size = _h2_font_size
	}

	if update_fonts {
		update_font_cache()
		update_fonts = false
	}

	header_pad : f32 = 10
	line_gap : f32 = (em / 1.5)
	top_line_gap : f32 = line_gap

	rect_height := em + (0.75 * em)
	toolbar_height : f32 = 4 * em

	pane_y : f32 = 0
	next_line := proc(y: ^f32, h: f32) -> f32 {
		res := y^
		y^ += h + (h / 1.5)
		return res
	}

	for i := 0; i < 4; i += 1 {
		next_line(&pane_y, em)
	}

	x_pad_size : f32 = 3 * em
	x_subpad : f32 = em
	y_pad_size : f32 = em

	info_pane_height : f32 = pane_y + y_pad_size + line_gap
	info_pane_y := height - info_pane_height

	start_x := x_pad_size
	end_x := width - x_pad_size
	display_width := end_x - start_x
	start_y := toolbar_height + y_pad_size
	end_y   := info_pane_y
	display_height := end_y - start_y


	if finished_loading {
		cam = Camera{Vec2{0, 0}, Vec2{0, 0}, 1}

		fmt.printf("min %d μs, max %d μs, range %d μs\n", total_min_time, total_max_time, total_max_time - total_min_time)
		start_time : f32 = 0
		end_time   : f32 = f32(total_max_time - total_min_time)
		cam.scale = rescale(cam.scale, start_time, end_time, 0, display_width)
		division  = int(display_width / 6)

		finished_loading = false
	}

	trace_display_rect := rect(0, toolbar_height, width, info_pane_y)

	// compute scale + scroll
	MIN_SCALE :: 0.00001
	MAX_SCALE :: 100000
	if pt_in_rect(mouse_pos, trace_display_rect) {
		cam.scale *= 1 + (0.1 * zoom_velocity * dt)
		cam.scale = min(max(cam.scale, MIN_SCALE), MAX_SCALE)
	}
	zoom_velocity = 0

	// compute pan
	pan_delta := Vec2{}
	if is_mouse_down {
		if pt_in_rect(clicked_pos, trace_display_rect) {
			pan_delta = mouse_pos - last_mouse_pos
			cam.vel.y = -pan_delta.y / dt
			cam.vel.x = pan_delta.x / dt
		}
		last_mouse_pos = mouse_pos
	}

	generate_lod_rects(&processes, rect_height)

	cam.pan = cam.pan + (cam.vel * dt)
	cam.vel *= f32(_pow(0.005, f64(dt)))

	max_y_pan := get_max_y_pan(processes[:], rect_height) - display_height

	edge_sproing : f64 = 0.0001
	if cam.pan.y < 0 {
		cam.pan.y = cam.pan.y * f32(_pow(edge_sproing, f64(dt)))
		cam.vel.y *= f32(_pow(0.0001, f64(dt)))
	}
	if cam.pan.y > max_y_pan {
		cam.pan.y = max_y_pan + (cam.pan.y - max_y_pan) * f32(_pow(edge_sproing, f64(dt)))
		cam.vel.y *= f32(_pow(0.0001, f64(dt)))
	}

	graph_start_y := start_y
	header_height := top_line_gap + em
	max_x := width - x_pad_size

	top_pad := graph_start_y + header_height + header_pad 
	cur_y := top_pad - cam.pan.y

    canvas_clear()

	// Render background
    draw_rect(rect(0, toolbar_height, width, height), bg_color2)

/*
	cam.scale = 1
	cam.pan.x = f32(total_min_time)
*/

	//start_x := ((10 * cam.scale) + cam.pan.x)

	display_range_start := (0 - cam.pan.x) / cam.scale
	display_range_end := (display_width - cam.pan.x) / cam.scale

	division = 5 

	draw_tick_start := round_down(int(display_range_start), division)
	draw_tick_end := round_up(int(display_range_end), division)
	tick_range := draw_tick_end - draw_tick_start

	ticks := int(tick_range / division) + 1
	if ticks > 6 {
		division = tick_range / 3
		draw_tick_start = round_down(int(display_range_start), division)
		draw_tick_end = round_down(int(display_range_end), division)
		tick_range = draw_tick_end - draw_tick_start
	} else if ticks < 3 {
		division = tick_range / 6
		draw_tick_start = round_down(int(display_range_start), division)
		draw_tick_end = round_down(int(display_range_end), division)
		tick_range = draw_tick_end - draw_tick_start
	}
	ticks = int(tick_range / division) + 1

	//fmt.printf("displayed range: %f μs -> %f μs, ticks: %d, division: %d μs\n", display_range_start, display_range_end, ticks, division)

	// draw lines for time markings
	for i := 0; i < ticks; i += 1 {
		x_off := display_range_start + f32(i * division)
		x_off = (x_off * cam.scale) + cam.pan.x
		draw_line(Vec2{x_off, graph_start_y + header_height}, Vec2{x_off, info_pane_y}, 0.5, line_color)
	}


	// Render flamegraphs
	clicked_on_rect := false
	proc_loop: for proc_v, p_idx in processes {
		h1_size : f32 = 0
		if len(processes) > 1 {
			row_text := fmt.tprintf("PID: %d", proc_v.process_id)
			draw_text(row_text, Vec2{start_x + 5, cur_y}, h1_font_size, default_font, text_color)

			h1_size = h1_height + (h1_height / 2)
			cur_y += h1_size
		}

		thread_loop: for tm, t_idx in proc_v.threads {
			last_cur_y := cur_y
			h2_size := h2_height + (h2_height / 2)
			cur_y += h2_size

			thread_advance := ((f32(tm.max_depth) * rect_height) + thread_gap)

			if cur_y > info_pane_y {
				break proc_loop
			}
			if cur_y + thread_advance < 0 {
				cur_y += thread_advance
				continue
			}

			row_text := fmt.tprintf("TID: %d", tm.thread_id)
			draw_text(row_text, Vec2{start_x + 5, last_cur_y}, h2_font_size, default_font, text_color)

			for er, idx in tm.rects {
				dr := er.r
				dr.pos.x  = start_x + (dr.pos.x * cam.scale) + cam.pan.x
				dr.pos.y  = (dr.pos.y + cur_y)
				dr.size.x = (dr.size.x * cam.scale)

				if dr.size.x < 0.1 || !rect_in_rect(dr, trace_display_rect) {
					continue
				}

				rect_color := color_choices[er.depth - 1]
				if pt_in_rect(mouse_pos, dr) {
					set_cursor("pointer")
					if clicked {
						selected_event = {i64(p_idx), i64(t_idx), i64(er.idx)}
						clicked_on_rect = true
					}
				}
				if int(selected_event.pid) == p_idx && 
				   int(selected_event.tid) == t_idx && 
				   int(selected_event.eid) == er.idx {
					rect_color.x += 30
					rect_color.y += 30
					rect_color.z += 30
				}

				draw_rect(dr, rect_color)

				text_pad : f32 = 10
				max_chars := max(0, min(len(er.name), int(math.floor((dr.size.x - (text_pad * 2)) / ch_width))))
				name_str := er.name[:max_chars]

				if len(name_str) > 4 || max_chars == len(er.name) {
					if max_chars != len(er.name) {
						name_str = fmt.tprintf("%s...", er.name[:max_chars-3])
					}

					ev_width := measure_text(name_str, p_font_size, monospace_font)
					draw_text(name_str, Vec2{(dr.pos.x) + (dr.size.x / 2) - (ev_width / 2), dr.pos.y + (rect_height / 2) - (em / 2)}, p_font_size, monospace_font, text_color3)
				}
			}
			cur_y += thread_advance
		}
	}

	if clicked && !clicked_on_rect {
		selected_event = {-1, -1, -1}
	}


	// Chop sides of screen
    draw_rect(rect(0, toolbar_height, width, y_pad_size + header_height), bg_color2) // top
    draw_rect(rect(max_x + 1, toolbar_height, width, height), bg_color2) // right
    draw_rect(rect(0, toolbar_height, x_pad_size - 1, height), bg_color2) // left
    draw_rect(rect(0, info_pane_y, width, height), bg_color2) // bottom

/*
	for i := total_min_time; i < total_max_time; i += step_size {
		off_x := rescale(f32(i), f32(total_min_time), f32(total_max_time), range_start, range_end)

		time_str: string
		cur_time := i / 1000
		time_str = fmt.tprintf("%d ms", i)

		text_width := measure_text(time_str, p_font_size, default_font)
		draw_text(time_str, Vec2{start_x + off_x - (text_width / 2), graph_start_y}, p_font_size, default_font, text_color)
	}
*/

	// Render info pane
	draw_line(Vec2{0, info_pane_y}, Vec2{width, info_pane_y}, 1, line_color)
    draw_rect(rect(0, info_pane_y, width, height), bg_color) // bottom

	if selected_event.pid != -1 && selected_event.tid != -1 && selected_event.eid != -1 {
		p_idx := int(selected_event.pid)
		t_idx := int(selected_event.tid)
		e_idx := int(selected_event.eid)

		y := info_pane_y + y_pad_size

		time_fmt :: proc(time: u64) -> string {
			if time < 1000 {
				return fmt.tprintf("%d μs", time)
			} else {
				return fmt.tprintf("%.1f ms", f32(time) / 1000)
			}
		}

		event := processes[p_idx].threads[t_idx].events[e_idx]
		draw_text(fmt.tprintf("Event: \"%s\"", event.name), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
		draw_text(fmt.tprintf("start time: %s", time_fmt(event.timestamp - total_min_time)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
		draw_text(fmt.tprintf("start timestamp: %d", event.timestamp), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)

		draw_text(fmt.tprintf("duration: %s", time_fmt(event.duration)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
	}

	// Render toolbar background
    draw_rect(rect(0, 0, width, toolbar_height), toolbar_color)

	// draw toolbar
	edge_pad : f32 = 1 * em
	button_height : f32 = 2.5 * em
	button_width  : f32 = 2.5 * em
	button_pad    : f32 = 0.5 * em

	color_text : string
	switch colormode {
	case .Auto:
		color_text = "\uf042"
	case .Dark:
		color_text = "\uf10c" 
	case .Light:
		color_text = "\uf111" 
	}

	if button(rect(width - edge_pad - button_width, (toolbar_height / 2) - (button_height / 2), button_width, button_height), color_text, icon_font) {
		new_colormode: ColorMode

		// rotate between auto, dark, and light
		switch colormode {
		case .Auto:
			new_colormode = .Dark
		case .Dark:
			new_colormode = .Light
		case .Light:
			new_colormode = .Auto
		}

		switch new_colormode {
		case .Auto:
			is_dark := get_system_color()
			set_color_mode(true, is_dark)
			set_session_storage("colormode", "auto")
		case .Dark:
			set_color_mode(false, true)
			set_session_storage("colormode", "dark")
		case .Light:
			set_color_mode(false, false)
			set_session_storage("colormode", "light")
		}
		colormode = new_colormode
	}

	if !is_hovering {
		reset_cursor()
	}

	prev_line := proc(y: ^f32, h: f32) -> f32 {
		res := y^
		y^ -= h + (h / 1.5)
		return res
	}

	// Render debug info
	y := height - em - y_pad_size

	hash_str := fmt.tprintf("Build: 0x%X", abs(hash))
	hash_width := measure_text(hash_str, p_font_size, monospace_font)
	draw_text(hash_str, Vec2{width - hash_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

	seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
	seed_width := measure_text(seed_str, p_font_size, monospace_font)
	draw_text(seed_str, Vec2{width - seed_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

    return true
}

pt_in_rect :: proc(pt: Vec2, box: Rect) -> bool {
	x1 := box.pos.x
	y1 := box.pos.y
	x2 := box.pos.x + box.size.x
	y2 := box.pos.y + box.size.y

	return x1 <= pt.x && pt.x <= x2 && y1 <= pt.y && pt.y <= y2
}

rect_in_rect :: proc(a, b: Rect) -> bool {
	a_left := a.pos.x
	a_right := a.pos.x + a.size.x

	a_top := a.pos.y
	a_bottom := a.pos.y + a.size.y

	b_left := b.pos.x
	b_right := b.pos.x + b.size.x

	b_top := b.pos.y
	b_bottom := b.pos.y + b.size.y

	return !(b_left > a_right || a_left > b_right || a_top > b_bottom || b_top > a_bottom)
}

button :: proc(in_rect: Rect, text: string, font: string) -> bool {
	draw_rectc(in_rect, 3, button_color)
	text_width := measure_text(text, p_font_size, font)
	draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (em / 2)}, p_font_size, font, text_color3)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor("pointer")
		if clicked {
			return true
		}
	}
	return false
}
