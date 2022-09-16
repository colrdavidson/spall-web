package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:runtime"
import "core:strings"
import "core:mem"
import "core:hash"
import "vendor:wasm/js"
import "core:intrinsics"
import "core:slice"
import "core:container/queue"

global_arena := Arena{}
temp_arena := Arena{}
scratch_arena := Arena{}

global_allocator: mem.Allocator
scratch_allocator: mem.Allocator
temp_allocator: mem.Allocator
current_alloc_offset := 0

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

dpr: f64

_p_font_size : f64 = 1
_h1_font_size : f64 = 1.25
_h2_font_size : f64 = 1.0625

p_font_size: f64
h1_font_size: f64
h2_font_size: f64

last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
scroll_val_y: f64 = 0

cam := Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}
division: f64 = 0

is_mouse_down := false
was_mouse_down := false
clicked       := false
is_hovering   := false

selected_rect := Rect{}
did_select := false

build_hash := 0

first_frame := true
started_loading := false
finished_loading := false
update_fonts := true
start_profiling := false
colormode := ColorMode.Dark

ColorMode :: enum {
	Dark,
	Light,
	Auto
}

em             : f64 = 0
h1_height      : f64 = 0
h2_height      : f64 = 0
ch_width       : f64 = 0
thread_gap     : f64 = 8

trace_config : string

processes: [dynamic]Process
color_choices: [dynamic]Vec3
event_count: i64
total_max_time: f64
total_min_time: f64
total_max_depth: u16

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

get_max_y_pan :: proc(processes: []Process, rect_height: f64) -> f64 {
	cur_y : f64 = 0

	for proc_v, _ in processes {
		if len(processes) > 1 {
			h1_size := h1_height + (h1_height / 2)
			cur_y += h1_size
		}

		for tm, _ in proc_v.threads {
			h2_size := h2_height + (h2_height / 2)
			cur_y += h2_size + ((f64(tm.max_depth) * rect_height) + thread_gap)
		}
	}

	return cur_y
}

to_world_x :: proc(cam: Camera, x: f64) -> f64 {
	return (x - cam.pan.x) / cam.current_scale
}
to_world_y :: proc(cam: Camera, y: f64) -> f64 {
	return y + cam.pan.y
}
to_world_pos :: proc(cam: Camera, pos: Vec2) -> Vec2 {
	return Vec2{to_world_x(cam, pos.x), to_world_y(cam, pos.y)}
}

CHUNK_SIZE :: 12 * 1024 * 1024
main :: proc() {
	ONE_GB_PAGES :: 1 * 1024 * 1024 * 1024 / js.PAGE_SIZE
	ONE_MB_PAGES :: 1 * 1024 * 1024 / js.PAGE_SIZE
	temp_data, _    := js.page_alloc(ONE_MB_PAGES * 15)
	scratch_data, _ := js.page_alloc(ONE_MB_PAGES * 20)

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

get_current_window :: proc(cam: Camera, display_width: f64) -> (f64, f64) {
	display_range_start := to_world_x(cam, 0)
	display_range_end   := to_world_x(cam, display_width)
	return display_range_start, display_range_end
}

@export
frame :: proc "contextless" (width, height: f64, dt: f64) -> bool {
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
	if started_loading {
		pad_size : f64 = 3
		chunk_size : f64 = 10

		load_box := rect(0, 0, 100, 100)
		load_box = rect((width / 2) - (load_box.size.x / 2) - pad_size, (height / 2) - (load_box.size.y / 2) - pad_size, load_box.size.x + pad_size, load_box.size.y + pad_size)

		draw_rectc(load_box, 3, Vec3{50, 50, 50})

		p: Parser
		if is_json {
			p = jp.p
		} else {
			p = bp
		}

		chunk_count := int(rescale(f64(p.offset), 0, f64(p.total_size), 0, 100))

		chunk := rect(0, 0, chunk_size, chunk_size)
		start_x := load_box.pos.x + pad_size
		start_y := load_box.pos.y + pad_size
		for i := chunk_count; i >= 0; i -= 1 {
			cur_x := f64(i %% int(chunk_size))
			cur_y := f64(i /  int(chunk_size))
			draw_rect(rect(start_x + (cur_x * chunk_size), start_y + (cur_y * chunk_size), chunk_size - pad_size, chunk_size - pad_size), Vec3{0, 255, 0})
		}

		return true
	}

	defer {
		free_all(context.temp_allocator)
		clicked = false
		is_hovering = false
		was_mouse_down = false
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

	top_line_gap := (em / 1.5)
	rect_height := em + (0.75 * em)
	toolbar_height := 4 * em

	pane_y : f64 = 0
	next_line :: proc(y: ^f64, h: f64) -> f64 {
		res := y^
		y^ += h + (h / 1.5)
		return res
	}

	for i := 0; i < 10; i += 1 {
		next_line(&pane_y, em)
	}

	x_pad_size := 3 * em
	x_subpad := em

	info_pane_height := pane_y + top_line_gap
	info_pane_y := height - info_pane_height
	
	if abs(mouse_pos.y - info_pane_y) <= 5.0 {
		// set_cursor("ns-resize")
	}

	start_x := x_pad_size
	end_x := width - x_pad_size
	display_width := end_x - start_x
	start_y := toolbar_height
	end_y   := info_pane_y
	display_height := end_y - start_y

	if finished_loading {
		cam = Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}

		if event_count == 0 { total_min_time = 0; total_max_time = 1000 }
		fmt.printf("min %f μs, max %f μs, range %f μs\n", total_min_time, total_max_time, total_max_time - total_min_time)
		start_time : f64 = 0
		end_time   := total_max_time - total_min_time
		cam.current_scale = rescale(cam.current_scale, start_time, end_time, 0, display_width)
		cam.target_scale = cam.current_scale

		arena := cast(^Arena)context.allocator.data
		current_alloc_offset = arena.offset

		finished_loading = false
	}

	canvas_clear()

	// Render background
	draw_rect(rect(0, toolbar_height, width, height), bg_color2)

	graph_header_text_height := (top_line_gap * 2) + em
	graph_header_line_gap := em
	graph_header_height := graph_header_text_height + graph_header_line_gap
	max_x := width - x_pad_size

	disp_rect := rect(start_x, start_y, display_width, display_height)
	//draw_rect_outline(rect(disp_rect.pos.x, disp_rect.pos.y, disp_rect.size.x, disp_rect.size.y - 1), 1, Vec3{255, 0, 0})

	graph_rect := disp_rect
	graph_rect.pos.y += graph_header_height
	graph_rect.size.y -= graph_header_height
	//draw_rect_outline(rect(graph_rect.pos.x, graph_rect.pos.y, graph_rect.size.x, graph_rect.size.y - 1), 1, Vec3{0, 0, 255})

	old_scale := cam.target_scale

	max_scale := 10000000.0
	min_scale := 0.5 * display_width / (total_max_time - total_min_time)
	/* if pt_in_rect(mouse_pos, disp_rect) */ {
		cam.target_scale *= _pow(1.0025, -scroll_val_y)
		cam.target_scale  = min(max(cam.target_scale, min_scale), max_scale)
	}
	scroll_val_y = 0

	cam.current_scale += (cam.target_scale - cam.current_scale) * (1 - _pow(_pow(0.1, 12), (dt)))
	cam.current_scale = min(max(cam.current_scale, min_scale), max_scale)

	last_start_time, last_end_time := get_current_window(cam, display_width)

	max_height := get_max_y_pan(processes[:], rect_height)
	max_y_pan := max(+20 * em + max_height - graph_rect.size.y, 0)
	min_y_pan := min(-20 * em, max_y_pan)
	max_x_pan := max(+20 * em, 0)
	min_x_pan := min(-20 * em + display_width + -(total_max_time - total_min_time) * cam.target_scale, max_x_pan)

	// compute pan, scale + scroll
	pan_delta := mouse_pos - last_mouse_pos
	if is_mouse_down && !shift_down {
		if pt_in_rect(clicked_pos, disp_rect) {

			if cam.target_pan_x < min_x_pan {
				pan_delta.x *= _pow(2, (cam.target_pan_x - min_x_pan) / 32)
			}
			if cam.target_pan_x > max_x_pan {
				pan_delta.x *= _pow(2, (max_x_pan - cam.target_pan_x) / 32)
			}
			if cam.pan.y < min_y_pan {
				pan_delta.y *= _pow(2, (cam.pan.y - min_y_pan) / 32)
			}
			if cam.pan.y > max_y_pan {
				pan_delta.y *= _pow(2, (max_y_pan - cam.pan.y) / 32)
			}

			cam.vel.y = -pan_delta.y / dt
			cam.vel.x = pan_delta.x / dt
		}
		last_mouse_pos = mouse_pos
	}


	cam_mouse_x := mouse_pos.x - start_x

	if cam.target_scale != old_scale {
		cam.target_pan_x = ((cam.target_pan_x - cam_mouse_x) * (cam.target_scale / old_scale)) + cam_mouse_x
		if cam.target_pan_x < min_x_pan {
			cam.target_pan_x = min_x_pan
		}
		if cam.target_pan_x > max_x_pan {
			cam.target_pan_x = max_x_pan
		}
	}

	cam.target_pan_x = cam.target_pan_x + (cam.vel.x * dt)
	cam.pan.y = cam.pan.y + (cam.vel.y * dt)
	cam.vel *= _pow(0.0001, dt)

	edge_sproing : f64 = 0.0001
	if cam.pan.y < min_y_pan && !is_mouse_down {
		cam.pan.y = min_y_pan + (cam.pan.y - min_y_pan) * _pow(edge_sproing, dt)
		cam.vel.y *= _pow(0.0001, dt)
	}
	if cam.pan.y > max_y_pan && !is_mouse_down {
		cam.pan.y = max_y_pan + (cam.pan.y - max_y_pan) * _pow(edge_sproing, dt)
		cam.vel.y *= _pow(0.0001, dt)
	}

	if cam.target_pan_x < min_x_pan && !is_mouse_down {
		cam.target_pan_x = min_x_pan + (cam.target_pan_x - min_x_pan) * _pow(edge_sproing, dt)
		cam.vel.x *= _pow(0.0001, dt)
	}
	if cam.target_pan_x > max_x_pan && !is_mouse_down {
		cam.target_pan_x = max_x_pan + (cam.target_pan_x - max_x_pan) * _pow(edge_sproing, dt)
		cam.vel.x *= _pow(0.0001, dt)
	}

	cam.pan.x = cam.target_pan_x + (cam.pan.x - cam.target_pan_x) * _pow(_pow(0.1, 12), dt)

	start_time, end_time := get_current_window(cam, display_width)

	// Draw time subdivision lines
	mus_range := f64(end_time - start_time)
	v1 := math.log10(mus_range)
	v2 := math.floor(v1)
	rem := v1 - v2

	division = _pow(10, v2)
	if rem < 0.3 {
		division -= (division * 0.8)
	} else if rem < 0.6 {
		division -= (division / 2)
	}

	display_range_start := -cam.pan.x / cam.current_scale
	display_range_end := (display_width - cam.pan.x) / cam.current_scale

	draw_tick_start := f_round_down(display_range_start, division)
	draw_tick_end := f_round_down(display_range_end, division)
	tick_range := draw_tick_end - draw_tick_start

	ticks := int(tick_range / division) + 3

	line_x_start := -4
	line_x_end   := ticks * 2
	for i := line_x_start; i < line_x_end; i += 1 {
		tick_time := draw_tick_start + (f64(i) * (division / 2))
		x_off := (tick_time * cam.current_scale) + cam.pan.x

		color := (i % 2) == 1 ? line_color : text_color

		line_start := disp_rect.pos.y + graph_header_height - top_line_gap
		draw_line(Vec2{start_x + x_off, line_start}, Vec2{start_x + x_off, graph_rect.pos.y + graph_rect.size.y}, 0.5, color)
	}

	name_color_idx :: proc(name: string) -> u32 {
		return u32(uintptr(raw_data(name))) % u32(len(color_choices))
	}

	// Render flamegraphs
	clicked_on_rect := false
	cur_y := graph_rect.pos.y - cam.pan.y
	proc_loop: for proc_v, p_idx in processes {
		h1_size : f64 = 0
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

			thread_advance := ((f64(len(tm.depths)) * rect_height) + thread_gap)

			if cur_y > info_pane_y {
				break proc_loop
			}
			if cur_y + thread_advance < 0 {
				cur_y += thread_advance
				continue
			}

			row_text := fmt.tprintf("TID: %d", tm.thread_id)
			draw_text(row_text, Vec2{start_x + 5, last_cur_y}, h2_font_size, default_font, text_color)

			cur_depth_off := 0
			for depth_arr, d_idx in tm.depths {
				y := rect_height * f64(d_idx)
				h := rect_height

				start_idx := find_idx(depth_arr[:], start_time)
				end_idx := find_idx(depth_arr[:], end_time)
				if start_idx == -1 {
					start_idx = 0
				}
				if end_idx == -1 {
					end_idx = len(depth_arr) - 1
				}

				scan_arr := depth_arr[start_idx:end_idx+1]
				chunker_x := (scan_arr[0].timestamp - total_min_time) * cam.current_scale
				chunker_w := 0.0
				color_weights := make([]f64, len(color_choices), context.temp_allocator)
				{
					idx := name_color_idx(scan_arr[0].name)
					color_weights[idx] += scan_arr[0].duration
				}

				flush_chunker :: proc(chunker_w : ^f64, chunker_color : Vec3, chunker_x, cur_y, y, h : f64, disp_rect : Rect, d_idx : int) {
					r := Rect{Vec2{chunker_x, y}, Vec2{chunker_w^, h}}
					r_x := chunker_x + cam.pan.x + disp_rect.pos.x
					r_y := r.pos.y + cur_y
					dr := Rect{Vec2{r_x, r_y}, Vec2{r.size.x, r.size.y}}
					draw_rect(dr, chunker_color)

					chunker_w^ = 0
				}

				for ev, de_id in scan_arr {
					x := ev.timestamp - total_min_time
					w := ev.duration * cam.current_scale

					xm := x * cam.target_scale

					idx := name_color_idx(ev.name)
					color_weights[idx] += max(ev.duration, MIN_WIDTH / cam.current_scale)

					MIN_WIDTH :: 2.0
					if w < MIN_WIDTH {
						if de_id - 1 >= 0 {
							ev_left := scan_arr[de_id - 1]
							xl := (ev_left.timestamp - total_min_time) * cam.target_scale
							wl := ev_left.duration * cam.target_scale
							if xl + max(wl, MIN_WIDTH) > xm {
								chunker_w = max(x * cam.current_scale + MIN_WIDTH - chunker_x, chunker_w)
								continue
							}
						}
						w = MIN_WIDTH
					}

					if chunker_w > 0 {
						chunker_color := Vec3{}
						weights_sum := 0.0
						for weight, idx in &color_weights {
							chunker_color += color_choices[idx] * weight
							weights_sum += weight
							weight = 0
						}
						if weights_sum <= 0 {
							fmt.printf("weights sum was <= 0\n")
							trap()
						}
						chunker_color /= weights_sum
						weights_sum = 0
						flush_chunker(&chunker_w, chunker_color, chunker_x, cur_y, y, h, disp_rect, d_idx)
					}

					chunker_x = x * cam.current_scale

					// Carefully extract the [start, end] interval of the rect so that we can clip the left
					// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
					// problems drawing a rectangle which starts at a massively huge negative number on
					// the left.
					r_x   := x * cam.current_scale
					end_x := r_x + w

					r_x   += cam.pan.x + disp_rect.pos.x
					end_x += cam.pan.x + disp_rect.pos.x

					r_x    = max(r_x, 0)

					r_y := y + cur_y
					dr := Rect{Vec2{r_x, r_y}, Vec2{end_x - r_x, h}}

					if !rect_in_rect(dr, disp_rect) {
						continue
					}

					e_idx := cur_depth_off + start_idx + de_id
					rect_color := color_choices[name_color_idx(ev.name)]
					if int(selected_event.pid) == p_idx &&
					   int(selected_event.tid) == t_idx &&
					   int(selected_event.eid) == e_idx {
						rect_color.x += 30
						rect_color.y += 30
						rect_color.z += 30
					}

					draw_rect(dr, rect_color)

					if pt_in_rect(mouse_pos, disp_rect) && pt_in_rect(mouse_pos, dr) {
						set_cursor("pointer")
						if clicked {
							selected_event = {i64(p_idx), i64(t_idx), i64(e_idx)}
							clicked_on_rect = true
						}
					}

					underhang := start_x - dr.pos.x
					disp_w := min(dr.size.x - underhang, dr.size.x)

					text_pad := (em / 2)
					text_width := int(math.floor((disp_w - (text_pad * 2)) / ch_width))
					max_chars := max(0, min(len(ev.name), text_width))
					name_str := ev.name[:max_chars]

					if len(name_str) > 4 || max_chars == len(ev.name) {
						if max_chars != len(ev.name) {
							name_str = fmt.tprintf("%s…", ev.name[:max_chars-1])
						}


						str_width := measure_text(name_str, p_font_size, monospace_font)
						str_x := max(dr.pos.x, start_x) + text_pad

						draw_text(name_str, Vec2{str_x, dr.pos.y + (rect_height / 2) - (em / 2)}, p_font_size, monospace_font, text_color3)
					}
				}
				if chunker_w > 0 {
					chunker_color := Vec3{}
					weights_sum := 0.0
					for weight, idx in &color_weights {
						chunker_color += color_choices[idx] * weight
						weights_sum += weight
						weight = 0
					}
					if weights_sum <= 0 {
						fmt.printf("weights sum was <= 0\n")
						trap()
					}
					chunker_color /= weights_sum
					weights_sum = 0
					flush_chunker(&chunker_w, chunker_color, chunker_x, cur_y, y, h, disp_rect, d_idx)
				}
				cur_depth_off += len(depth_arr)
			}
			cur_y += thread_advance
		}
	}

	if clicked && !clicked_on_rect {
		selected_event = {-1, -1, -1}
	}

	if is_mouse_down && shift_down {
		// try to fake a reduced frame of latency by extrapolating the position by the delta
		mouse_pos_extrapolated := mouse_pos + 1 * Vec2{pan_delta.x, pan_delta.y} / dt * min(dt, 0.016)
		delta := mouse_pos_extrapolated - clicked_pos
		selected_rect = rect(clicked_pos.x, clicked_pos.y, delta.x, delta.y)
		draw_rect_outline(selected_rect, 1, Vec3{0, 0, 255})
		draw_rect(selected_rect, Vec3{0, 0, 255}, 100)
		did_select = true
	}

	// Chop sides of screen
	draw_rect(rect(0, disp_rect.pos.y, width, graph_header_text_height), bg_color) // top
	draw_rect(rect(0, disp_rect.pos.y + graph_header_text_height, graph_rect.pos.x, height), bg_color2) // left
	draw_rect(rect(graph_rect.pos.x + graph_rect.size.x, disp_rect.pos.y + graph_header_text_height, width, height), bg_color2) // right
	draw_line(Vec2{0, disp_rect.pos.y + graph_header_text_height}, Vec2{width, disp_rect.pos.y + graph_header_text_height}, 0.5, line_color)


	// Draw timestamps on subdivision lines
	ONE_SECOND :: 1000 * 1000
	ONE_MILLI :: 1000
	for i := 0; i < ticks; i += 1 {
		tick_time := draw_tick_start + (f64(i) * division)
		x_off := (tick_time * cam.current_scale) + cam.pan.x

		time_str: string
		if abs(tick_range) > ONE_SECOND {
			cur_time := tick_time / ONE_SECOND
			time_str = fmt.tprintf("%.3f s", cur_time)
		} else if abs(tick_range) > ONE_MILLI {
			cur_time := tick_time / ONE_MILLI
			time_str = fmt.tprintf("%.3f ms", cur_time)
		} else {
			time_str = fmt.tprintf("%.2f μs", tick_time)
		}

		text_width := measure_text(time_str, p_font_size, default_font)
		draw_text(time_str, Vec2{start_x + x_off - (text_width / 2), disp_rect.pos.y + (graph_header_text_height / 2) - (em / 2)}, p_font_size, default_font, text_color)
	}

	// Render info pane
	draw_line(Vec2{0, info_pane_y}, Vec2{width, info_pane_y}, 1, line_color)
	draw_rect(rect(0, info_pane_y, width, height), bg_color) // bottom

	if did_select {
		flopped_rect := Rect{}
		flopped_rect.pos.x = min(selected_rect.pos.x, selected_rect.pos.x + selected_rect.size.x)
		x2 := max(selected_rect.pos.x, selected_rect.pos.x + selected_rect.size.x)
		flopped_rect.size.x = x2 - flopped_rect.pos.x

		flopped_rect.pos.y = min(selected_rect.pos.y, selected_rect.pos.y + selected_rect.size.y)
		y2 := max(selected_rect.pos.y, selected_rect.pos.y + selected_rect.size.y)
		flopped_rect.size.y = y2 - flopped_rect.pos.y

		selected_start_time := to_world_x(cam, flopped_rect.pos.x - disp_rect.pos.x)
		selected_end_time   := to_world_x(cam, flopped_rect.pos.x - disp_rect.pos.x + flopped_rect.size.x)

		width_text := fmt.tprintf("%s", time_fmt(selected_end_time - selected_start_time))
		width_text_width := measure_text(width_text, p_font_size, monospace_font)
		if flopped_rect.size.x > width_text_width {
			draw_text(width_text, Vec2{flopped_rect.pos.x + (flopped_rect.size.x / 2) - (width_text_width / 2), flopped_rect.pos.y + flopped_rect.size.y - (em * 1.5)}, p_font_size, monospace_font, text_color)
		}

		// push it into screen-space
		flopped_rect.pos.x -= disp_rect.pos.x

		Stats :: struct {
			total_time: f64,
			count: u32,
			min_time: f32,
			max_time: f32,
			histogram: [22]u32,
		}

		stats := make(map[string]Stats, 0, context.temp_allocator)

		total_tracked_time := 0.0

		// Eww... This needs to be a function somwhere
		cur_y := graph_rect.pos.y - cam.pan.y
		proc_loop2: for proc_v, p_idx in processes {
			h1_size : f64 = 0
			if len(processes) > 1 {
				h1_size = h1_height + (h1_height / 2)
				cur_y += h1_size
			}

			for tm, t_idx in proc_v.threads {
				h2_size := h2_height + (h2_height / 2)
				cur_y += h2_size
				if cur_y > info_pane_y {
					break proc_loop2
				}

				thread_advance := ((f64(len(tm.depths)) * rect_height) + thread_gap)
				if cur_y + thread_advance < 0 {
					cur_y += thread_advance
					continue
				}

				for depth_arr, d_idx in tm.depths {
					y := rect_height * f64(d_idx)
					h := rect_height

					start_idx := find_idx(depth_arr[:], selected_start_time)
					end_idx := find_idx(depth_arr[:], selected_end_time)
					if start_idx == -1 {
						start_idx = 0
					}
					if end_idx == -1 {
						end_idx = len(depth_arr) - 1
					}
					scan_arr := depth_arr[start_idx:end_idx+1]

					scan_loop: for ev in scan_arr {
						x := ev.timestamp - total_min_time
						w := ev.duration * cam.current_scale

						r := Rect{Vec2{x, y}, Vec2{w, h}}
						r_x := (r.pos.x * cam.current_scale) + cam.pan.x + disp_rect.pos.x
						r_y := cur_y + r.pos.y
						dr := Rect{Vec2{r_x, r_y}, Vec2{r.size.x, r.size.y}}

						if !rect_in_rect(flopped_rect, dr) {
							continue scan_loop
						}

						s, ok := &stats[ev.name]
						if !ok {
							stats[ev.name] = Stats{min_time = 1e308}
							s = &stats[ev.name]
						}
						s.count += 1
						s.total_time += ev.duration
						s.min_time = min(s.min_time, f32(ev.duration))
						s.max_time = max(s.max_time, f32(ev.duration))
						total_tracked_time += ev.duration
					}
				}
				cur_y += thread_advance
			}
		}

		y := info_pane_y + top_line_gap

		sort_map_entries_by_time :: proc(m: ^$M/map[$K]$V, loc := #caller_location) {
			Entry :: struct {
				hash:  uintptr,
				next:  int,
				key:   K,
				value: V,
			}

			map_sort :: proc(a: Entry, b: Entry) -> bool {
				return a.value.total_time > b.value.total_time
			}

			header := runtime.__get_map_header(m)
			entries := (^[dynamic]Entry)(&header.m.entries)
			slice.sort_by(entries[:], map_sort)
			runtime.__dynamic_map_reset_entries(header, loc)
		}

		sort_map_entries_by_time(&stats)

		column_gap := 1.5 * em
	
		total_header_text    := fmt.tprintf("%-17s", "      total")
		min_header_text      := fmt.tprintf("%-10s", "   min.")
		avg_header_text      := fmt.tprintf("%-10s", "   avg.")
		_99p_header_text     := fmt.tprintf("%-10s", "   99p.")
		max_header_text      := fmt.tprintf("%-10s", "   max.")
		name_header_text     := fmt.tprintf("%-10s", "   name")

		cursor := x_subpad

		text_outf :: proc(cursor: ^f64, y: f64, str: string, color := text_color) {
			width := measure_text(str, p_font_size, monospace_font)
			draw_text(str, Vec2{cursor^, y}, p_font_size, monospace_font, color)
			cursor^ += width
		}
		vs_outf :: proc(cursor: ^f64, column_gap, info_pane_y, info_pane_height: f64) {
			cursor^ += column_gap / 2
			draw_line(Vec2{cursor^, info_pane_y}, Vec2{cursor^, info_pane_y + info_pane_height}, 0.5, text_color2)
			cursor^ += column_gap / 2
		}

		text_outf(&cursor, y, total_header_text)
		vs_outf(&cursor, column_gap, info_pane_y, info_pane_height)

		text_outf(&cursor, y, min_header_text)
		vs_outf(&cursor, column_gap, info_pane_y, info_pane_height)

		text_outf(&cursor, y, avg_header_text)
		vs_outf(&cursor, column_gap, info_pane_y, info_pane_height)

		text_outf(&cursor, y, _99p_header_text)
		vs_outf(&cursor, column_gap, info_pane_y, info_pane_height)

		text_outf(&cursor, y, max_header_text)
		vs_outf(&cursor, column_gap, info_pane_y, info_pane_height)

		text_outf(&cursor, y, name_header_text)
		next_line(&y, em)

		i := 0
		for name, stat in stats {
			if i > 8 {
				break
			}

			cursor = x_subpad

			perc := (stat.total_time / total_tracked_time) * 100

			total_text := fmt.tprintf("%10s %5.1f%%", time_fmt(stat.total_time, true), perc)

			min := stat.min_time
			min_text := fmt.tprintf("%10s", time_fmt(f64(min), true))

			avg := stat.total_time / f64(stat.count)
			avg_text := fmt.tprintf("%10s", time_fmt(avg, true))

			num_standard_deviations := 2.326348 // ninety-ninth percentile is 2.326348 standard deviations greater than the mean
			_99p := math.lerp(stat.min_time, stat.max_time, f32((2 + num_standard_deviations) / 4))
			_99p_text := fmt.tprintf("%10s", time_fmt(f64(_99p), true))

			max := stat.max_time
			max_text := fmt.tprintf("%10s", time_fmt(f64(max), true))

			text_outf(&cursor, y, total_text, text_color2); cursor += column_gap
			text_outf(&cursor, y, min_text, text_color2);   cursor += column_gap
			text_outf(&cursor, y, avg_text, text_color2);   cursor += column_gap
			text_outf(&cursor, y, _99p_text, text_color2);  cursor += column_gap
			text_outf(&cursor, y, max_text, text_color2);   cursor += column_gap

			y_before   := y - em / 4
			y_after    := y_before
			next_line(&y_after, em) // @Speed
			name_width := measure_text(name, p_font_size, monospace_font)

			dr := rect(cursor, y_before, (display_width - cursor - column_gap) * stat.total_time / total_tracked_time, y_after - y_before)

			cursor += column_gap / 2

			draw_rect(dr,         color_choices[name_color_idx(name)])

			draw_text(name,       Vec2{cursor, y}, p_font_size, monospace_font, text_color);

			next_line(&y, em)
			i += 1
		}
	} else if selected_event.pid != -1 && selected_event.tid != -1 && selected_event.eid != -1 {
		p_idx := int(selected_event.pid)
		t_idx := int(selected_event.tid)
		e_idx := int(selected_event.eid)

		y := info_pane_y + top_line_gap


		event := processes[p_idx].threads[t_idx].events[e_idx]
		draw_text(fmt.tprintf("Event: \"%s\"", event.name), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
		draw_text(fmt.tprintf("start time: %s", time_fmt(event.timestamp - total_min_time)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
		draw_text(fmt.tprintf("start timestamp: %s", time_fmt(event.timestamp)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)

		draw_text(fmt.tprintf("duration: %s", time_fmt(event.duration)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
	}

	// Render toolbar background
	draw_rect(rect(0, 0, width, toolbar_height), toolbar_color)

	// draw toolbar
	edge_pad := 1 * em
	button_height := 2.5 * em
	button_width  := 2.5 * em
	button_pad    := 0.5 * em

	// colormode button nonsense
	color_text : string
	switch colormode {
	case .Auto:
		color_text = "\uf042"
	case .Dark:
		color_text = "\uf10c"
	case .Light:
		color_text = "\uf111"
	}

	if button(rect(edge_pad, (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf066", icon_font) {
		// I'm sorry. this is a dumb hack
		finished_loading = true		
	}
	if button(rect(edge_pad + (button_width) + (button_pad), (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf15b", icon_font) {
		open_file_dialog()
	}

	if button(rect(edge_pad + (button_width * 2) + (button_pad * 2), (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf021", icon_font) {
		pump_socket()
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

	prev_line := proc(y: ^f64, h: f64) -> f64 {
		res := y^
		y^ -= h + (h / 1.5)
		return res
	}

	// Render debug info
	y := height - em - top_line_gap

	fps_str := fmt.tprintf("FPS: %.0f", 1/dt)
	fps_width := measure_text(fps_str, p_font_size, monospace_font)
	draw_text(fps_str, Vec2{width - fps_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

	hash_str := fmt.tprintf("Build: 0x%X", abs(build_hash))
	hash_width := measure_text(hash_str, p_font_size, monospace_font)
	draw_text(hash_str, Vec2{width - hash_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

	seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
	seed_width := measure_text(seed_str, p_font_size, monospace_font)
	draw_text(seed_str, Vec2{width - seed_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

	return true
}

button :: proc(in_rect: Rect, text: string, font: string) -> bool {
	draw_rectc(in_rect, 3, button_color)
	text_width := measure_text(text, p_font_size, font)
	text_height := get_text_height(p_font_size, font)
	draw_text(text, Vec2{in_rect.pos.x + in_rect.size.x/2 - text_width/2, in_rect.pos.y + (in_rect.size.y / 2) - (text_height / 2)}, p_font_size, font, text_color3)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor("pointer")
		if clicked {
			return true
		}
	}
	return false
}

/* make this use ems. Eww
draw_graph :: proc(header: string, history: ^queue.Queue(u32), pos: Vec2) {
	line_width : f64 = 1
	graph_edge_pad : f64 = 15
	graph_size: f64 = 150

	max_val : u32 = 0
	min_val : u32 = 100
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)
		max_val = max(max_val, entry)
		min_val = min(min_val, entry)
	}
	max_range := max_val - min_val

	text_width := measure_text(header, 1, default_font)
	center_offset := (graph_size / 2) - (text_width / 2)
	draw_text(header, Vec2{pos.x + center_offset, pos.y}, 1, default_font, text_color)

	graph_top := pos.y + em + line_gap
	draw_rect(rect(pos.x, graph_top, graph_size, graph_size), 0, bg_color2)
	draw_rect_outline(rect(pos.x, graph_top, graph_size, graph_size), 2, outline_color)

	draw_line(Vec2{pos.x - 5, graph_top + graph_size - graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_size - graph_edge_pad}, 1, graph_color)
	draw_line(Vec2{pos.x - 5, graph_top + graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_edge_pad}, 1, graph_color)

	if queue.len(history^) > 1 {
		high_str := fmt.tprintf("%d", max_val)
		high_width := measure_text(high_str, 1, default_font) + line_gap
		draw_text(high_str, Vec2{(pos.x - 5) - high_width, graph_top + graph_edge_pad - (text_height / 2) + 1}, 1, default_font, text_color)

		low_str := fmt.tprintf("%d", min_val)
		low_width := measure_text(low_str, 1, default_font) + line_gap
		draw_text(low_str, Vec2{(pos.x - 5) - low_width, graph_top + graph_size - graph_edge_pad - (text_height / 2) + 2}, 1, default_font, text_color)
	}

	graph_y_bounds := graph_size - (graph_edge_pad * 2)
	graph_x_bounds := graph_size - graph_edge_pad

	last_x : f32 = 0
	last_y : f32 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)

		point_x_offset : f32 = 0
		if queue.len(history^) != 0 {
			point_x_offset = f32(i) * (graph_x_bounds / f32(queue.len(history^)))
		}

		point_y_offset : f32 = 0
		if max_range != 0 {
			point_y_offset = f32(entry - min_val) * (graph_y_bounds / f32(max_range))
		}

		point_x := pos.x + point_x_offset + (graph_edge_pad / 2)
		point_y := graph_top + graph_size - point_y_offset - graph_edge_pad

		if queue.len(history^) > 1  && i > 0 {
			draw_line(Vec2{last_x, last_y}, Vec2{point_x, point_y}, line_width, graph_color)
		}

		last_x = point_x
		last_y = point_y
	}
}
*/
