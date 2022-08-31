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

t           : f64
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

scale: f64 = 1

last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
pan            := Vec2{}
zoom_velocity: f64 = 0

is_mouse_down := false
clicked       := false
is_hovering   := false

hash := 0

p: Parser

first_frame := true
loading_config := true
colormode := ColorMode.Dark

ColorMode :: enum {
	Dark,
	Light,
	Auto
}

y_pad_size     : f32 = 20
x_pad_size     : f32 = 40
toolbar_height : f32 = 40
text_height    : f32 = 0
line_gap       : f32 = 0

trace_config : string

events: [dynamic]Event
color_choices: [dynamic]Vec3
processes: [dynamic]Process
process_map: map[u64]int
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

CHUNK_SIZE :: 10 * 1024 * 1024
main :: proc() {
	PAGE_SIZE :: 64
	ONE_GB :: 1000000 / PAGE_SIZE
	ONE_MB :: 1000 / PAGE_SIZE
	temp_data, _    := js.page_alloc(ONE_MB * 11)
	scratch_data, _ := js.page_alloc(ONE_MB * 2)
	global_data, _ := js.page_alloc((ONE_GB * 2) + (ONE_MB * 100))
    arena_init(&temp_arena, temp_data)
    arena_init(&scratch_arena, scratch_data)
    arena_init(&global_arena, global_data)

    global_allocator = arena_allocator(&global_arena)

	// I'm doing olympic-level memory juggling BS in the ingest system because 
	// arenas are *special*, and memory is *precious*. Beware free_all()'ing 
	// the wrong one at the wrong time, here thar be dragons. Once you're in
	// normal render/frame space, I free_all temp once per frame, and I shouldn't
	// need to touch scratch
    temp_allocator = arena_allocator(&temp_arena)
    scratch_allocator = arena_allocator(&scratch_arena)

	wasmContext.allocator = global_allocator
	wasmContext.temp_allocator = temp_allocator

    context = wasmContext

	manual_load(default_config)
}

random_seed: u64

@export
frame :: proc "contextless" (width, height: f32, dt: f64) -> bool {
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

	header_pad : f32 = 10
	top_line_gap : f32 = 7
	thread_gap : f32 = 8

	normal_text_height := get_text_height(1, default_font)
	ch_width := measure_text("a", 1, monospace_font)
	rect_height := normal_text_height + 5

	info_pane_height : f32 = 100
	info_pane_y := height - info_pane_height

	time_range := total_max_time - total_min_time
	start_time := f64(0)
	end_time   := f64(time_range) / scale

	trace_display_rect := rect(0, toolbar_height, width, info_pane_y)

	// compute scale + scroll
	MIN_SCALE :: 0.01
	MAX_SCALE :: 100000
	if pt_in_rect(mouse_pos, trace_display_rect) {
		scale *= 1 + (0.1 * zoom_velocity * dt)
		scale = min(max(scale, MIN_SCALE), MAX_SCALE)
	}
	zoom_velocity = 0

	// compute pan
	pan_delta := Vec2{}
	if is_mouse_down {
		if pt_in_rect(clicked_pos, trace_display_rect) {
			pan_delta = mouse_pos - last_mouse_pos
		}
		last_mouse_pos = mouse_pos
	}
	pan.x += pan_delta.x
	pan.y -= pan_delta.y

	start_x := x_pad_size
	start_y := toolbar_height + y_pad_size

	graph_start_y := start_y
	header_height := top_line_gap + normal_text_height
	max_x := width - x_pad_size
	display_width := width - (x_pad_size * 2)

	cur_y := graph_start_y + header_height + header_pad - pan.y

    canvas_clear()

	// Render background
    draw_rect(rect(0, toolbar_height, width, height), bg_color2)

	// draw lines for time markings
	slice_count := 10
	max_time := rescale(f64(slice_count), 0, f64(slice_count), start_time, end_time)
	for i := 0; i <= slice_count; i += 1 {
		off_x := f32(i) * (f32(display_width) / f32(slice_count))
		draw_line(Vec2{start_x + off_x, graph_start_y + header_height}, Vec2{start_x + off_x, info_pane_y}, 0.5, line_color)
	}

	// Render flamegraphs
	clicked_on_rect := false
	proc_loop: for proc_v, p_idx in processes {
		if len(processes) > 1 {
			row_text := fmt.tprintf("PID: %d", proc_v.process_id)
			header_text_height := get_text_height(1.25, default_font)
			draw_text(row_text, Vec2{start_x + 5, cur_y}, 1.25, default_font, text_color)
			cur_y += header_text_height + (header_text_height / 2)
		}

		thread_loop: for tm, t_idx in proc_v.threads {
			header_text_height := get_text_height(1.0625, default_font)

			last_cur_y := cur_y
			cur_y += header_text_height + (header_text_height / 2)
			if cur_y > info_pane_y {
				break proc_loop
			}

			row_text := fmt.tprintf("TID: %d", tm.thread_id)
			draw_text(row_text, Vec2{start_x + 5, last_cur_y}, 1.0625, default_font, text_color)

			for event, e_idx in tm.events {
				cur_start := event.timestamp - total_min_time
				cur_end   := cur_start + event.duration

				rect_x := rescale(f32(cur_start), f32(start_time), f32(end_time), 0, display_width)
				rect_end := rescale(f32(cur_end), f32(start_time), f32(end_time), 0, display_width)
				rect_width := rect_end - rect_x

				if rect_width < 0.1 {
					continue
				}

				y := cur_y + (rect_height * f32(event.depth - 1))

				entry_rect := rect(start_x + rect_x + pan.x, y, rect_width, rect_height)
				if (entry_rect.pos.y + entry_rect.size.y) < graph_start_y + header_height || 
					entry_rect.pos.x > (display_width + x_pad_size) ||
					entry_rect.pos.x + entry_rect.size.x < x_pad_size {
					continue
				}

				rect_color := color_choices[event.depth - 1]
				if pt_in_rect(mouse_pos, entry_rect) {
					set_cursor("pointer")
					if clicked {
						selected_event = {i64(p_idx), i64(t_idx), i64(e_idx)}
						clicked_on_rect = true
					}
				}
				if int(selected_event.pid) == p_idx && 
				   int(selected_event.tid) == t_idx && 
				   int(selected_event.eid) == e_idx {
					rect_color.x += 30
					rect_color.y += 30
					rect_color.z += 30
				}
				draw_rect(entry_rect, rect_color)

				text_pad : f32 = 10
				max_chars := max(0, min(len(event.name), int(math.floor((rect_width - (text_pad * 2)) / ch_width))))
				name_str := event.name[:max_chars]

				if len(name_str) > 4 || max_chars == len(event.name) {
					if max_chars != len(event.name) {
						name_str = fmt.tprintf("%s...", event.name[:max_chars-3])
					}

					ev_width := measure_text(name_str, 1, monospace_font)
					ev_height := get_text_height(1, monospace_font)
					draw_text(name_str, Vec2{(start_x + rect_x + pan.x) + (rect_width / 2) - (ev_width / 2), y + (rect_height / 2) - (ev_height / 2)}, 1, monospace_font, text_color3)
				}

			}

			cur_y += ((f32(tm.max_depth) * rect_height) + thread_gap)
		}
	}

	if clicked && !clicked_on_rect {
		selected_event = {-1, -1, -1}
	}


	// Chop sides of screen
    draw_rect(rect(0, toolbar_height, width, y_pad_size + header_height), bg_color2) // top
    draw_rect(rect(max_x, toolbar_height, width, height), bg_color2) // right
    draw_rect(rect(0, toolbar_height, x_pad_size, height), bg_color2) // left
    draw_rect(rect(0, info_pane_y, width, height), bg_color2) // bottom

	for i := 0; i <= slice_count; i += 1 {
		off_x := f32(i) * (f32(display_width) / f32(slice_count))

		time_off := rescale(f64(pan.x), 0, f64(display_width), start_time, end_time)
		reranged_i := rescale(f64(i), 0, f64(slice_count), start_time, end_time)  
		cur_time := reranged_i - time_off

		time_str: string
		if max_time < 5000 {
			time_str = fmt.tprintf("%.1f μs", cur_time)
		} else {
			cur_time = cur_time / 1000
			time_str = fmt.tprintf("%.1f ms", cur_time)
		}

		text_width := measure_text(time_str, 1, default_font)
		draw_text(time_str, Vec2{start_x + off_x - (text_width / 2), graph_start_y}, 1, default_font, text_color)
	}

	// Render info pane
	draw_line(Vec2{0, info_pane_y}, Vec2{width, info_pane_y}, 1, line_color)
    draw_rect(rect(0, info_pane_y, width, height), bg_color) // bottom

	info_pane_y += y_pad_size

	if selected_event.pid != -1 && selected_event.tid != -1 && selected_event.eid != -1 {
		p_idx := int(selected_event.pid)
		t_idx := int(selected_event.tid)
		e_idx := int(selected_event.eid)

		y := info_pane_y
		next_line := proc(y: ^f32) -> f32 {
			res := y^
			y^ += text_height + line_gap
			return res
		}

		time_fmt :: proc(time: u64) -> string {
			if time < 1000 {
				return fmt.tprintf("%d μs", time)
			} else {
				return fmt.tprintf("%.1f ms", f32(time) / 1000)
			}
		}

		event := processes[p_idx].threads[t_idx].events[e_idx]
		draw_text(fmt.tprintf("Event: \"%s\"", event.name), Vec2{start_x, next_line(&y)}, 1, default_font, text_color)
		draw_text(fmt.tprintf("start time: %s", time_fmt(event.timestamp - total_min_time)), Vec2{start_x, next_line(&y)}, 1, default_font, text_color)
		draw_text(fmt.tprintf("start timestamp: %d", event.timestamp), Vec2{start_x, next_line(&y)}, 1, default_font, text_color)

		draw_text(fmt.tprintf("duration: %s", time_fmt(event.duration)), Vec2{start_x, next_line(&y)}, 1, default_font, text_color)
	}

	// Render toolbar background
    draw_rect(rect(0, 0, width, toolbar_height), toolbar_color)

	// draw toolbar
	edge_pad : f32 = 10
	button_height : f32 = 30
	button_width  : f32 = 30
	button_pad    : f32 = 8

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

	// Render debug info
	seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
	seed_width := measure_text(seed_str, 1, monospace_font)
	text_height := get_text_height(1, monospace_font)
	draw_text(seed_str, Vec2{width - seed_width - 10, height - text_height - 24}, 1, monospace_font, text_color2)

	hash_str := fmt.tprintf("Build: 0x%X", abs(hash))
	hash_width := measure_text(hash_str, 1, monospace_font)
	draw_text(hash_str, Vec2{width - hash_width - 10, height - text_height - 10}, 1, monospace_font, text_color2)

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
	a_top := a.pos.y
	a_right := a.pos.x + a.size.x
	a_bottom := a.pos.y + a.size.y

	b_left := b.pos.x
	b_top := b.pos.y
	b_right := b.pos.x + b.size.x
	b_bottom := b.pos.y + b.size.y

	return !(b_left > a_right || b_right < a_left || b_top < a_top || b_bottom > a_top)
}

button :: proc(in_rect: Rect, text: string, font: string) -> bool {
	draw_rectc(in_rect, 3, button_color)
	text_width := measure_text(text, 1, font)
	text_height = get_text_height(1, font)
	draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, 1, font, text_color3)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor("pointer")
		if clicked {
			return true
		}
	}
	return false
}
