package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:runtime"
import "core:strings"
import "vendor:wasm/js"

global_arena := Arena{}
temp_arena := Arena{}

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

scale: f32 = 1

last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
pan            := Vec2{}
scroll_velocity: f32 = 0

is_mouse_down := false
clicked       := false
is_hovering   := false

hash := 0

first_frame := true
muted := false
running := false
colormode := ColorMode.Dark

ColorMode :: enum {
	Dark,
	Light,
	Auto
}

pad_size       : f32 = 40
toolbar_height : f32 = 40
text_height    : f32 = 0
line_gap       : f32 = 0

events: [dynamic]Event
threads: []Timeline
total_max_time: u64
total_min_time: u64

@export
set_color_mode :: proc "contextless" (auto: bool, is_dark: bool) {
	if is_dark {
		bg_color      = Vec3{15,   15,  15}
		bg_color2     = Vec3{0,     0,   0}
		text_color    = Vec3{255, 255, 255}
		text_color2   = Vec3{180, 180, 180}
		text_color3   = Vec3{180, 180, 180}
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
		text_color3   = Vec3{250, 250, 250}
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

main :: proc() {
	global_data, _ := js.page_alloc(1000)
	temp_data, _ := js.page_alloc(1000)
    arena_init(&global_arena, global_data)
    arena_init(&temp_arena, temp_data)

    wasmContext.allocator = arena_allocator(&global_arena)
    wasmContext.temp_allocator = arena_allocator(&temp_arena)

    context = wasmContext

	events = make([dynamic]Event)	
	if ok := load_config(trace_config, &events); !ok {
		fmt.printf("Failed to load config!\n")
		trap()
	}
	threads, total_max_time, total_min_time = process_events(events[:])

	// clear memory consumed by json parser
	free_all(context.temp_allocator)

	t = 0
	frame_count = 0
}

random_seed: u64

@export
frame :: proc "contextless" (width, height: f32, dt: f32) -> bool {
    context = wasmContext
	defer free_all(context.temp_allocator)
	defer frame_count += 1

	// This is nasty code that allows me to do load-time things once the wasm context is init
	if first_frame {
		random_seed = u64(get_time())
		fmt.printf("Seed is 0x%X\n", random_seed)

		rand.set_global_seed(random_seed)
		first_frame = false
	}

	defer if clicked {
		clicked = false
	}
	defer scroll_velocity = 0
	defer is_hovering = false

    t += dt

	// compute render scale
	MIN_SCALE :: 0.1
	MAX_SCALE :: 386
	if pt_in_rect(mouse_pos, rect(0, toolbar_height, width, height - toolbar_height)) {
		scale *= 1 + (0.05 * scroll_velocity * dt)
		scale = min(max(scale, MIN_SCALE), MAX_SCALE)
	}

    canvas_clear()

	// Render background
    draw_rect(rect(0, toolbar_height, width, height), 0, bg_color2)

	// Render flamegraph
	start_x := pad_size
	start_y := toolbar_height + pad_size
	end_x := width - pad_size
	end_y := height - pad_size

	graph_start_y := start_y + pad_size

	cur_y := graph_start_y
	max_x := width - pad_size
	display_width := width - (pad_size * 2)

	thread_gap : f32 = 8
	rect_height : f32 = 18

	start_time := f32(total_min_time) / scale
	end_time   := f32(total_max_time) / scale
	for tm, t_idx in threads {
		row_text := fmt.tprintf("TID: %d", tm.thread_id)
		text_height := get_text_height(1.25, default_font)
		draw_text(row_text, Vec2{start_x + 5, cur_y}, 1.25, default_font, text_color)
		cur_y += text_height + (text_height / 2)

		for event, e_idx in tm.events {
			cur_start := event.timestamp
			cur_end   := event.timestamp + event.duration

			rect_x := rescale(f32(cur_start), f32(start_time), f32(end_time), 0, display_width)
			rect_end := rescale(f32(cur_end), f32(start_time), f32(end_time), 0, display_width)
			rect_width := rect_end - rect_x
			color := f32(((event.depth + 1) * 25) %% 255)

			y := cur_y + (rect_height * f32(event.depth - 1))
			draw_rect(rect(start_x + rect_x, y, rect_width, rect_height), 0, Vec3{30, color, 30})

		}

		cur_y += ((f32(tm.max_depth) * rect_height) + thread_gap)
	}

	// Chop sides of screen
    draw_rect(rect(0, toolbar_height, pad_size, height), 0, bg_color2)
    draw_rect(rect(max_x, toolbar_height, width, height), 0, bg_color2)
    draw_rect(rect(0, height - pad_size, width, height), 0, bg_color2)

	//max_displayed_time := total_max_time / end_time
	top_offset : f32 = 7
	slice_count := 5
	for i := 0; i < slice_count; i += 1 {
		off_x := f32(i) * (f32(display_width) / f32(slice_count))
		cur_time :=  f32(i) * (end_time / f32(slice_count))

		time_str := fmt.tprintf("%f ms", cur_time)
		text_width := measure_text(time_str, 1, default_font)
		text_height := get_text_height(1, default_font)
		draw_text(time_str, Vec2{start_x + off_x - (text_width / 2), graph_start_y - top_offset - text_height}, 1, default_font, text_color)
		draw_line(Vec2{start_x + off_x, graph_start_y}, Vec2{start_x + off_x, end_y}, 1, line_color)
	}

	// Render toolbar background
    draw_rect(rect(0, 0, width, toolbar_height), 0, toolbar_color)

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
	draw_text(seed_str, Vec2{width - seed_width - 10, height - text_height - 24}, 1, monospace_font, text_color2)

	hash_str := fmt.tprintf("Build: 0x%X", abs(hash))
	hash_width := measure_text(hash_str, 1, monospace_font)
	draw_text(hash_str, Vec2{width - hash_width - 10, height - text_height - 10}, 1, monospace_font, text_color2)
    return false
}

pt_in_rect :: proc(pt: Vec2, box: Rect) -> bool {
	x1 := box.pos.x
	y1 := box.pos.y
	x2 := box.pos.x + box.size.x
	y2 := box.pos.y + box.size.y

	return x1 <= pt.x && pt.x <= x2 && y1 <= pt.y && pt.y <= y2
}

button :: proc(in_rect: Rect, text: string, font: string) -> bool {
	draw_rect(in_rect, 3, button_color)
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

tab :: proc(in_rect: Rect, text: string, font: string, selected: bool) -> bool {
	text_width := measure_text(text, 1, font)
	text_height = get_text_height(1, font)

	if selected {
		draw_rect(in_rect, 0, button_color)
		draw_rect_outline(in_rect, 1, button_color)
		draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, 1, font, text_color3)
	} else {
		draw_rect(in_rect, 0, button_color2)
		draw_rect_outline(in_rect, 1, button_color2)
		draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, 1, font, text_color)
	}


	if pt_in_rect(mouse_pos, in_rect) && !selected {
		set_cursor("pointer")
		if clicked {
			return true
		}
	}

	return false
}
