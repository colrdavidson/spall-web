package main

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:runtime"
import "core:mem"
import "vendor:wasm/js"
import "core:container/queue"

// allocator state
big_global_arena := Arena{}
small_global_arena := Arena{}
temp_arena := Arena{}
scratch_arena := Arena{}
scratch2_arena := Arena{}

big_global_allocator: mem.Allocator
small_global_allocator: mem.Allocator
scratch_allocator: mem.Allocator
scratch2_allocator: mem.Allocator
temp_allocator: mem.Allocator

current_alloc_offset := 0

wasmContext := runtime.default_context()

// input state
is_mouse_down  := false
was_mouse_down := false
clicked        := false
mouse_up_now   := false
is_hovering    := false
shift_down     := false

// tooltip-state
rect_tooltip_rect := EventID{-1, -1, -1, -1}
rect_tooltip_pos := Vec2{}
rendered_rect_tooltip := false


last_mouse_pos := Vec2{}
mouse_pos      := Vec2{}
clicked_pos    := Vec2{}
scroll_val_y: f64 = 0

cam := Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}
info_pane_scroll: f64 = 0
info_pane_scroll_vel: f64 = 0


// selection state
selected_event := EventID{-1, -1, -1, -1}

pressed_event := EventID{-1, -1, -1, -1}
released_event := EventID{-1, -1, -1, -1}

did_multiselect := false
clicked_on_rect := false

did_pan := false

stats: StatMap
stats_state := StatState.NoStats
stat_sort_type := SortState.SelfTime
stat_sort_descending := true
resort_stats := false
selected_ranges: [dynamic]Range
cur_stat_offset := StatOffset{}
total_tracked_time := 0.0


// drawing state
default_font   := `'Montserrat',-apple-system,BlinkMacSystemFont,segoe ui,Helvetica,Arial,sans-serif,apple color emoji,segoe ui emoji,segoe ui symbol`
monospace_font := `'Fira Code', monospace`
icon_font      := `FontAwesome`
colormode      := ColorMode.Dark

dpr := 1.0
rect_height: f64
disp_rect: Rect
graph_rect: Rect
padded_graph_rect: Rect
gl_rects: [dynamic]DrawRect

_p_font_size : f64 = 14
_h1_font_size : f64 = 18
_h2_font_size : f64 = 16

p_font_size: f64
h1_font_size: f64
h2_font_size: f64

em             : f64 = 0
p_height       : f64 = 0
h1_height      : f64 = 0
h2_height      : f64 = 0
ch_width       : f64 = 0
thread_gap     : f64 = 8
graph_size: f64 = 150

build_hash : i32 = 0
enable_debug := false
fps_history: queue.Queue(f64)

t               : f64
multiselect_t   : f64
greyanim_t      : f32
greymotion      : f32
anim_playing    : bool
frame_count     : int
last_frame_count: int
rect_count      : int
bucket_count    : int
was_sleeping    : bool
random_seed     : u64
first_frame := true


// loading / trace state
loading_config := true
post_loading := false
event_count: i64

bp: Parser
last_read: i64

string_block: [dynamic]u8
processes: [dynamic]Process
process_map: ValHash

global_instants: [dynamic]Instant
total_max_time: f64
total_min_time: f64

file_name_store: [1024]u8
file_name: string
CHUNK_SIZE :: 10 * 1024 * 1024


// Most of the action happens in frame(), this is just to set up for the JS/WASM platform layer
main :: proc() {
	ONE_GB_PAGES :: 1 * 1024 * 1024 * 1024 / js.PAGE_SIZE
	ONE_MB_PAGES :: 1 * 1024 * 1024 / js.PAGE_SIZE
	temp_data, _         := js.page_alloc(ONE_MB_PAGES * 15)
	scratch_data, _      := js.page_alloc(ONE_MB_PAGES * 20)
	scratch2_data, _     := js.page_alloc(ONE_MB_PAGES * 50)
	small_global_data, _ := js.page_alloc(ONE_MB_PAGES * 1)

	arena_init(&temp_arena,         temp_data)
	arena_init(&scratch_arena,      scratch_data)
	arena_init(&scratch2_arena,     scratch2_data)
	arena_init(&small_global_arena, small_global_data)

	// This must be init last, because it grows infinitely.
	// We don't want it accidentally growing into anything useful.
	growing_arena_init(&big_global_arena)

	// I'm doing olympic-level memory juggling BS in the ingest system because
	// arenas are *special*, and memory is *precious*. Beware free_all()'ing
	// the wrong one at the wrong time, here thar be dragons. Once you're in
	// normal render/frame space, I free_all temp once per frame, and I shouldn't
	// need to touch scratch
	temp_allocator         = arena_allocator(&temp_arena)
	scratch_allocator      = arena_allocator(&scratch_arena)
	scratch2_allocator     = arena_allocator(&scratch2_arena)
	small_global_allocator = arena_allocator(&small_global_arena)

	big_global_allocator = growing_arena_allocator(&big_global_arena)

	wasmContext.allocator      = big_global_allocator
	wasmContext.temp_allocator = temp_allocator

	context = wasmContext

	// fibhashing the time to get better seed distribution
	random_seed = u64(get_time()) * 11400714819323198485
	rand.set_global_seed(random_seed)
}

@export
frame :: proc "contextless" (width, height: f64, _dt: f64) -> bool {
	context = wasmContext
	defer frame_count += 1

	render_one_more := false

	rect_tooltip_rect = EventID{-1, -1, -1, -1}
	rect_tooltip_pos = Vec2{}
	rendered_rect_tooltip = false

	if first_frame {
		manual_load(default_config, default_config_name)
		first_frame = false
		return true
	}

	// render loading screen
	if loading_config {
		pad_size : f64 = 4
		chunk_size : f64 = 10

		load_box := rect(0, 0, 100, 100)
		load_box = rect(
			(width / 2) - (load_box.size.x / 2) - pad_size, 
			(height / 2) - (load_box.size.y / 2) - pad_size, 
			load_box.size.x + pad_size, 
			load_box.size.y + pad_size,
		)

		draw_rectc(load_box, 3, FVec4{30, 30, 30, 255})
		chunk_count := int(rescale(f64(bp.offset), 0, f64(bp.total_size), 0, 100))

		chunk := rect(0, 0, chunk_size, chunk_size)
		start_x := load_box.pos.x + pad_size
		start_y := load_box.pos.y + pad_size
		for i := chunk_count; i >= 0; i -= 1 {
			cur_x := f64(i %% int(chunk_size))
			cur_y := f64(i /  int(chunk_size))
			draw_rect(rect(
				start_x + (cur_x * chunk_size), 
				start_y + (cur_y * chunk_size), 
				chunk_size - pad_size, 
				chunk_size - pad_size,
			), loading_block_color)
		}

		return true
	}

	defer {
		free_all(context.temp_allocator)
		clicked = false
		is_hovering = false
		was_mouse_down = false
		mouse_up_now = false
		released_event = {-1, -1, -1, -1}
	}

	dt := _dt
	if was_sleeping {
		dt = 0.001
		was_sleeping = false
	}
	t += dt

	// update animation timers
	greyanim_t = f32((t - multiselect_t) * 5)
	greymotion = ease_in_out(greyanim_t)


	// Set up all the display state we need to render the screen
	update_font_cache(width)

	rect_height = em + (0.75 * em)
	top_line_gap := (em / 1.5)
	toolbar_height := 3 * em

	pane_y : f64 = 0
	next_line :: proc(y: ^f64, h: f64) -> f64 {
		res := y^
		y^ += h + (h / 1.5)
		return res
	}
	prev_line := proc(y: ^f64, h: f64) -> f64 {
		res := y^
		y^ -= h + (h / 3)
		return res
	}

	info_line_count := 7
	for i := 0; i < info_line_count; i += 1 {
		next_line(&pane_y, em)
	}

	x_pad_size := 3 * em
	x_subpad := em

	info_pane_height := pane_y + top_line_gap
	info_pane_y := height - info_pane_height
	
/*
	if abs(mouse_pos.y - info_pane_y) <= 5.0 {
		set_cursor("ns-resize")
	}
*/

	mini_graph_width := 15 * em
	mini_graph_pad := (em)
	mini_graph_padded_width := mini_graph_width + (mini_graph_pad * 2)
	mini_start_x := width - mini_graph_padded_width

	time_bar_y := toolbar_height
	time_bar_height := (top_line_gap * 2) + em

	wide_graph_y := time_bar_y + time_bar_height
	wide_graph_height := (em * 2)

	start_x := x_pad_size
	end_x := width - x_pad_size
	display_width := width - (start_x + mini_graph_padded_width)
	start_y := toolbar_height + time_bar_height + wide_graph_height
	end_y   := info_pane_y
	display_height := end_y - start_y

	if post_loading {
		reset_camera(display_width)
		arena := cast(^Arena)context.allocator.data
		current_alloc_offset = arena.offset
		post_loading = false
	}

	graph_header_text_height := (top_line_gap * 2) + em
	graph_header_line_gap := em
	graph_header_height := graph_header_text_height + graph_header_line_gap
	max_x := width - x_pad_size

	disp_rect = rect(start_x, start_y, display_width, display_height)
	graph_rect = disp_rect
	graph_rect.pos.y += graph_header_text_height
	graph_rect.size.y -= graph_header_text_height
	padded_graph_rect = graph_rect
	padded_graph_rect.pos.y += graph_header_line_gap
	padded_graph_rect.size.y -= graph_header_line_gap
	stat_pane := rect(0, info_pane_y, width, height - info_pane_y)

	mini_graph_rect := rect(mini_start_x, graph_rect.pos.y, mini_graph_padded_width, display_height - graph_header_text_height)


	// process key/mouse inputs

	if clicked {
		did_pan = false
		pressed_event = {-1, -1, -1, -1} // so no stale events are tracked
	}

	start_time, end_time: f64
	pan_delta: Vec2
	{
		old_scale := cam.target_scale

		max_scale := 10000000.0
		min_scale := 0.5 * display_width / (total_max_time - total_min_time)
		if pt_in_rect(mouse_pos, graph_rect) {
			cam.target_scale *= _pow(1.0025, -scroll_val_y)
			cam.target_scale  = min(max(cam.target_scale, min_scale), max_scale)
		} else if pt_in_rect(mouse_pos, stat_pane) {
			info_pane_scroll_vel -= scroll_val_y * 10
		} else if pt_in_rect(mouse_pos, mini_graph_rect) {
			cam.vel.y += scroll_val_y * 10
		}
		scroll_val_y = 0

		info_pane_scroll += (info_pane_scroll_vel * dt)
		info_pane_scroll_vel *= _pow(0.000001, dt)
		info_pane_scroll = min(info_pane_scroll, 0)

		cam.current_scale += (cam.target_scale - cam.current_scale) * (1 - _pow(_pow(0.1, 12), (dt)))
		cam.current_scale = min(max(cam.current_scale, min_scale), max_scale)

		last_start_time, last_end_time := get_current_window(cam, display_width)

		get_max_y_pan :: proc(processes: []Process) -> f64 {
			cur_y : f64 = 0

			for proc_v, _ in processes {
				if len(processes) > 1 {
					h1_size := h1_height + (h1_height / 2)
					cur_y += h1_size
				}

				for tm, _ in proc_v.threads {
					h2_size := h2_height + (h2_height / 2)
					cur_y += h2_size + ((f64(len(tm.depths)) * rect_height) + thread_gap)
				}
			}

			return cur_y
		}
		max_height := get_max_y_pan(processes[:])
		max_y_pan := max(+20 * em + max_height - graph_rect.size.y, 0)
		min_y_pan := min(-20 * em, max_y_pan)
		max_x_pan := max(+20 * em, 0)
		min_x_pan := min(-20 * em + display_width + -(total_max_time - total_min_time) * cam.target_scale, max_x_pan)

		// compute pan, scale + scroll


		if is_mouse_down || mouse_up_now {
			MIN_PAN :: 5
			pan_dist := distance(mouse_pos, clicked_pos)
			if pan_dist > MIN_PAN {
				did_pan = true
			}
		}

		if did_pan {
			pan_delta = mouse_pos - last_mouse_pos
		}

		if is_mouse_down && !shift_down {
			if pt_in_rect(clicked_pos, padded_graph_rect) {

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
		start_time, end_time = get_current_window(cam, display_width)
	}

	// Init GL / Text canvases
	canvas_clear()
	gl_init_frame(bg_color2)
	gl_rects = make([dynamic]DrawRect, 0, int(width / 2), temp_allocator)

	// Draw time subdivision lines
	division: f64
	draw_tick_start: f64
	ticks: int
	{
		// mus_range := end_time - start_time <- simplifies to the following
		mus_range := display_width / cam.current_scale
		v1 := math.log10(mus_range)
		v2 := math.floor(v1)
		rem := v1 - v2

		division = _pow(10, v2)                            // multiples of 10
		if rem < 0.3      { division -= (division * 0.8) } // multiples of 2
		else if rem < 0.6 { division -= (division / 2)   } // multiples of 5

		display_range_start := -cam.pan.x / cam.current_scale
		display_range_end := (display_width - cam.pan.x) / cam.current_scale

		draw_tick_start = f_round_down(display_range_start, division)
		draw_tick_end := f_round_down(display_range_end, division)
		tick_range := draw_tick_end - draw_tick_start

		ticks = int(tick_range / division) + 3

		subdivisions := 5
		line_x_start := -4
		line_x_end   := ticks * subdivisions

		line_start := disp_rect.pos.y + graph_header_height - top_line_gap
		line_height := graph_rect.size.y
		for i := line_x_start; i < line_x_end; i += 1 {
			tick_time := draw_tick_start + (f64(i) * (division / f64(subdivisions)))
			x_off := (tick_time * cam.current_scale) + cam.pan.x

			color := (i % subdivisions) != 0 ? subdivision_color : division_color

			draw_rect := DrawRect{f32(start_x + x_off), f32(1.5), {u8(color.x), u8(color.y), u8(color.z), u8(color.w)}}
			append(&gl_rects, draw_rect)
		}

		gl_push_rects(gl_rects[:], line_start, line_height)
		resize(&gl_rects, 0)
	}


	// Render flamegraphs
	{
		clicked_on_rect = false
		rect_count = 0
		bucket_count = 0
		cur_y := padded_graph_rect.pos.y - cam.pan.y
		proc_loop: for proc_v, p_idx in &processes {
			h1_size : f64 = 0
			if len(processes) > 1 {
				if cur_y > disp_rect.pos.y {
					row_text: string
					if proc_v.name.len > 0 {
						row_text = fmt.tprintf("%s (PID %d)", in_getstr(proc_v.name), proc_v.process_id)
					} else {
						row_text = fmt.tprintf("PID: %d", proc_v.process_id)
					}
					draw_text(row_text, Vec2{start_x + 5, cur_y}, h1_font_size, default_font, text_color)
				}

				h1_size = h1_height + (h1_height / 2)
				cur_y += h1_size
			}

			thread_loop: for tm, t_idx in &proc_v.threads {
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

				if last_cur_y > disp_rect.pos.y {
					row_text: string
					if tm.name.len > 0 {
						row_text = fmt.tprintf("%s (TID %d)", in_getstr(tm.name), tm.thread_id)
					} else {
						row_text = fmt.tprintf("TID: %d", tm.thread_id)
					}
					draw_text(row_text, Vec2{start_x + 5, last_cur_y}, h2_font_size, default_font, text_color)
				}

				cur_depth_off := 0
				for depth, d_idx in &tm.depths {
					render_tree(p_idx, t_idx, d_idx, cur_y, start_time, end_time)
					gl_push_rects(gl_rects[:], (cur_y + (rect_height * f64(d_idx))), rect_height)

					resize(&gl_rects, 0)
				}
				cur_y += thread_advance
			}
		}
	}


	// Chop screen sides, and draw solid overlays to cover text/rect canvas overlay gaps
	draw_rect(rect(0, disp_rect.pos.y, width - mini_graph_padded_width, graph_header_text_height), bg_color) // top
	draw_rect(rect(0, toolbar_height, start_x, height), bg_color) // left

	draw_line(Vec2{start_x, disp_rect.pos.y + graph_header_text_height}, Vec2{width - mini_graph_padded_width, disp_rect.pos.y + graph_header_text_height}, 1, line_color)

	append(&gl_rects, DrawRect{f32(mini_start_x), f32(mini_graph_width + (mini_graph_pad * 2)), {u8(bg_color.x), u8(bg_color.y), u8(bg_color.z), 255}})
	gl_push_rects(gl_rects[:], disp_rect.pos.y + graph_header_text_height, height)
	resize(&gl_rects, 0)


	// Draw top wide-graph
	highlight_start_x, highlight_end_x: f64
	{
		wide_scale_x := rescale(1.0, 0, total_max_time - total_min_time, 0, display_width)
		layer_count := 1
		for proc_v, _ in processes {
			layer_count += len(proc_v.threads)
		}

		append(&gl_rects, DrawRect{f32(start_x), f32(display_width), {u8(wide_bg_color.x), u8(wide_bg_color.y), u8(wide_bg_color.z), u8(wide_bg_color.w)}})
		gl_push_rects(gl_rects[:], wide_graph_y, wide_graph_height)
		resize(&gl_rects, 0)

		for proc_v, p_idx in &processes {
			for tm, t_idx in &proc_v.threads {
				if len(tm.depths) == 0 {
					continue
				}

				render_widetree(p_idx, t_idx, start_x, wide_scale_x, layer_count)
				gl_push_rects(gl_rects[:], wide_graph_y, wide_graph_height)
				resize(&gl_rects, 0)
			}
		}

		highlight_start_x = rescale(start_time, 0, total_max_time - total_min_time, 0, display_width)
		highlight_end_x = rescale(end_time, 0, total_max_time - total_min_time, 0, display_width)

		highlight_width := highlight_end_x - highlight_start_x
		min_highlight := 5.0
		if highlight_width < min_highlight {
			high_center := (highlight_start_x + highlight_end_x) / 2
			highlight_start_x = high_center - (min_highlight / 2)
			highlight_end_x = high_center + (min_highlight / 2)
		}

		highlight_box_l := rect(start_x, wide_graph_y, highlight_start_x, wide_graph_height)
		draw_rect(highlight_box_l, FVec4{0, 0, 0, 150})

		highlight_box_r := rect(start_x + highlight_end_x, wide_graph_y, display_width - highlight_end_x, wide_graph_height)
		draw_rect(highlight_box_r, FVec4{0, 0, 0, 150})

		draw_rect(rect(0, wide_graph_y, start_x, wide_graph_height), FVec4{0, 0, 0, 255})
		draw_rect(rect(width - mini_graph_padded_width, wide_graph_y, mini_graph_padded_width, wide_graph_height), FVec4{0, 0, 0, 255})
	}

	// Draw mini-graph
	{
		mini_rect_height := (em / 2)
		mini_thread_gap := 8.0
		x_scale := rescale(1.0, 0, total_max_time - total_min_time, 0, mini_graph_width)
		y_scale := mini_rect_height / rect_height

		tree_y : f64 = padded_graph_rect.pos.y - (cam.pan.y * y_scale)
		for proc_v, p_idx in &processes {
			for tm, t_idx in &proc_v.threads {
				for depth, d_idx in &tm.depths {
					render_minitree(p_idx, t_idx, d_idx, mini_start_x + mini_graph_pad, x_scale)
					gl_push_rects(gl_rects[:], (tree_y + (mini_rect_height * f64(d_idx))), mini_rect_height)
					resize(&gl_rects, 0)
				}

				tree_y += ((f64(len(tm.depths)) * mini_rect_height) + mini_thread_gap)
			}
		}

		preview_height := display_height * y_scale

		draw_rect(rect(mini_start_x, disp_rect.pos.y, mini_graph_padded_width, preview_height), highlight_color)
		draw_rect(rect(mini_start_x, disp_rect.pos.y + preview_height, mini_graph_padded_width, display_height - preview_height), shadow_color)
	}


	// Draw timestamps on subdivision lines
	for i := 0; i < ticks; i += 1 {
		tick_time := draw_tick_start + (f64(i) * division)
		x_off := (tick_time * cam.current_scale) + cam.pan.x

		time_str := time_fmt(tick_time)
		text_width := measure_text(time_str, p_font_size, default_font)
		draw_text(time_str, Vec2{start_x + x_off - (text_width / 2), disp_rect.pos.y + (graph_header_text_height / 2) - (em / 3)}, p_font_size, default_font, text_color)
	}

	// Remove top-left and top-right chunk
	draw_rect(rect(0, toolbar_height + time_bar_height + wide_graph_height, start_x, graph_header_text_height), bg_color) // top-left

	draw_rect(rect(width - mini_graph_padded_width, toolbar_height + time_bar_height + wide_graph_height, width, graph_header_text_height), bg_color) // top-right

	draw_rect(rect(0, toolbar_height, width, time_bar_height + 1), bg_color)

	// draw sidelines
	draw_line(Vec2{start_x, toolbar_height + time_bar_height}, Vec2{start_x, info_pane_y}, 1, line_color)
	draw_line(Vec2{mini_start_x, toolbar_height + time_bar_height}, Vec2{mini_start_x, info_pane_y}, 1, line_color)

	// draw global timebar
	{
		if event_count == 0 { total_min_time = 0; total_max_time = 1000 }
		start_time : f64 = 0
		end_time   := total_max_time - total_min_time
		default_scale := rescale(1.0, start_time, end_time, 0, display_width)

		mus_range := display_width / default_scale
		v1 := math.log10(mus_range)
		v2 := math.floor(v1)
		rem := v1 - v2

		subdivisions := 10
		division := _pow(10, v2); // multiples of 10
		if rem < 0.3      { division -= (division * 0.8); } // multiples of 2
		else if rem < 0.6 { division -= (division / 2); } // multiples of 5

		display_range_start := -width / default_scale
		display_range_end := width / default_scale

		draw_tick_start = f_round_down(display_range_start, division)
		draw_tick_end := f_round_down(display_range_end, division)
		tick_range := draw_tick_end - draw_tick_start

		division /= f64(subdivisions)
		ticks := (int(tick_range / division) + 1)

		for i := 0; i < ticks; i += 1 {
			tick_time := draw_tick_start + (f64(i) * division)
			x_off := (tick_time * default_scale)

			line_start_y: f64
			if (i % subdivisions) == 0 {
				time_str := time_fmt(tick_time)
				text_width := measure_text(time_str, p_font_size, default_font)

				draw_text(time_str, 
					Vec2{
						start_x + x_off - (text_width / 2),
						toolbar_height + (time_bar_height / 2) - (em / 2),
					}, p_font_size, default_font, text_color)
				line_start_y = toolbar_height + (time_bar_height / 2) - (em / 2) + p_height
			} else {
				line_start_y = toolbar_height + (time_bar_height / 2) - (em / 2) + p_height + (p_height / 6)
			}

			draw_line(
				Vec2{start_x + x_off, line_start_y}, 
				Vec2{start_x + x_off, toolbar_height + time_bar_height - 2}, 2, division_color)
		}

		draw_line(Vec2{start_x + highlight_start_x, toolbar_height + (time_bar_height / 2) - (em / 2) + p_height}, Vec2{start_x + highlight_start_x, toolbar_height + time_bar_height + wide_graph_height}, 2, xbar_color)
		draw_line(Vec2{start_x + highlight_end_x, toolbar_height + (time_bar_height / 2) - (em / 2) + p_height}, Vec2{start_x + highlight_end_x, toolbar_height + time_bar_height + wide_graph_height}, 2, xbar_color)
		draw_line(Vec2{0, toolbar_height + time_bar_height + wide_graph_height}, Vec2{width, toolbar_height + time_bar_height + wide_graph_height}, 1, line_color)
	}


	// Render info pane
	draw_line(Vec2{0, info_pane_y}, Vec2{width, info_pane_y}, 1, line_color)
	draw_rect(rect(0, info_pane_y, width, height), bg_color) // bottom

	// Handle inputs
	{
		// Handle single-select
		if mouse_up_now && !did_pan && pt_in_rect(clicked_pos, graph_rect) && pressed_event == released_event && !shift_down {
			selected_event = released_event
			clicked_on_rect = true
			did_multiselect = false
			render_one_more = true
		}

		// Handle de-select
		if mouse_up_now && !did_pan && pt_in_rect(clicked_pos, graph_rect) && !clicked_on_rect && !shift_down {
			selected_event = {-1, -1, -1, -1}
			resize(&selected_ranges, 0)

			multiselect_t = 0
			did_multiselect = false
			stats_state = .NoStats
			render_one_more = true
		}

		// user wants to multi-select
		if is_mouse_down && shift_down {
			if !did_multiselect {
				multiselect_t = t
				anim_playing = true
			}

			// set multiselect flags
			stats_state = .Started
			did_multiselect = true
			total_tracked_time = 0.0
			cur_stat_offset = StatOffset{}
			selected_event = {-1, -1, -1, -1}
			info_pane_scroll = 0
			info_pane_scroll_vel = 0


			// try to fake a reduced frame of latency by extrapolating the position by the delta
			mouse_pos_extrapolated := mouse_pos + 1 * Vec2{pan_delta.x, pan_delta.y} / dt * min(dt, 0.016)

			// cap multi-select box at graph edges
			delta := mouse_pos_extrapolated - clicked_pos
			c_x := min(clicked_pos.x, graph_rect.pos.x + graph_rect.size.x)
			c_x = max(c_x, graph_rect.pos.x)

			c_y := min(clicked_pos.y, graph_rect.pos.y + graph_rect.size.y)
			c_y = max(c_y, graph_rect.pos.y)

			m_x := min(c_x + delta.x, graph_rect.pos.x + graph_rect.size.x)
			m_x = max(m_x, graph_rect.pos.x)
			m_y := min(c_y + delta.y, graph_rect.pos.y + graph_rect.size.y)
			m_y = max(m_y, graph_rect.pos.y)

			d_x := m_x - c_x
			d_y := m_y - c_y

			// draw multiselect box
			selected_rect := rect(c_x, c_y, d_x, d_y)
			multiselect_color := toolbar_color
			draw_rect_inline(selected_rect, 1, multiselect_color)
			multiselect_color.w = 20
			draw_rect(selected_rect, multiselect_color)

			// transform multiselect rect to screen position
			flopped_rect := Rect{}
			flopped_rect.pos.x = min(selected_rect.pos.x, selected_rect.pos.x + selected_rect.size.x)
			x2 := max(selected_rect.pos.x, selected_rect.pos.x + selected_rect.size.x)
			flopped_rect.size.x = x2 - flopped_rect.pos.x

			flopped_rect.pos.y = min(selected_rect.pos.y, selected_rect.pos.y + selected_rect.size.y)
			y2 := max(selected_rect.pos.y, selected_rect.pos.y + selected_rect.size.y)
			flopped_rect.size.y = y2 - flopped_rect.pos.y

			selected_start_time := to_world_x(cam, flopped_rect.pos.x - disp_rect.pos.x)
			selected_end_time   := to_world_x(cam, flopped_rect.pos.x - disp_rect.pos.x + flopped_rect.size.x)

			// draw multiselect timerange
			width_text := measure_fmt(selected_end_time - selected_start_time)
			width_text_width := measure_text(width_text, p_font_size, monospace_font) + em

			text_bg_rect := flopped_rect
			text_bg_rect.pos.x = text_bg_rect.pos.x + (text_bg_rect.size.x / 2) - (width_text_width / 2)
			text_bg_rect.pos.y = text_bg_rect.pos.y - (p_height * 2)
			text_bg_rect.size.x = width_text_width
			text_bg_rect.size.y = (p_height * 2)

			if flopped_rect.size.x > text_bg_rect.size.x {
				multiselect_color.w = 180
				draw_rect(text_bg_rect, multiselect_color)
				draw_text(
					width_text, 
					Vec2{
						text_bg_rect.pos.x + (em / 2), 
						text_bg_rect.pos.y + (p_height / 2),
					}, 
					p_font_size,
					monospace_font,
					FVec4{255, 255, 255, 255},
				)
			}

			// push it into screen-space
			flopped_rect.pos.x -= disp_rect.pos.x

			resize(&selected_ranges, 0)
			sm_clear(&stats)

			// build out ranges
			cur_y := padded_graph_rect.pos.y - cam.pan.y
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

					for depth, d_idx in tm.depths {
						y := rect_height * f64(d_idx)
						h := rect_height

						dy := cur_y + y
						dy2 := cur_y + y + h
						if dy > (flopped_rect.pos.y + flopped_rect.size.y) || dy2 < flopped_rect.pos.y {
							continue
						}

						start_idx := find_idx(depth.events, selected_start_time)
						end_idx := find_idx(depth.events, selected_end_time)
						if start_idx == -1 {
							start_idx = 0
						}
						if end_idx == -1 {
							end_idx = len(depth.events) - 1
						}
						scan_arr := depth.events[start_idx:end_idx+1]

						real_start := -1
						fwd_scan_loop: for i := 0; i < len(scan_arr); i += 1 {
							ev := scan_arr[i]
							x := ev.timestamp - total_min_time

							duration := bound_duration(ev, tm.max_time)
							w := duration * cam.current_scale

							r := Rect{Vec2{x, y}, Vec2{w, h}}
							r_x := (r.pos.x * cam.current_scale) + cam.pan.x
							r_y := cur_y + r.pos.y
							dr := Rect{Vec2{r_x, r_y}, Vec2{r.size.x, r.size.y}}

							if !rect_in_rect(flopped_rect, dr) {
								continue fwd_scan_loop
							}

							real_start = start_idx + i
							break fwd_scan_loop
						}

						real_end := -1
						rev_scan_loop: for i := len(scan_arr) - 1; i >= 0; i -= 1 {
							ev := scan_arr[i]
							x := ev.timestamp - total_min_time

							duration := bound_duration(ev, tm.max_time)
							w := duration * cam.current_scale

							r := Rect{Vec2{x, y}, Vec2{w, h}}
							r_x := (r.pos.x * cam.current_scale) + cam.pan.x
							r_y := cur_y + r.pos.y
							dr := Rect{Vec2{r_x, r_y}, Vec2{r.size.x, r.size.y}}

							if !rect_in_rect(flopped_rect, dr) {
								continue rev_scan_loop
							}

							real_end = start_idx + i + 1
							break rev_scan_loop
						}

						if real_start != -1 && real_end != -1 {
							append(&selected_ranges, Range{p_idx, t_idx, d_idx, real_start, real_end})
						}
					}
					cur_y += thread_advance
				}
			}
		}

		INITIAL_ITER :: 40_000
		FULL_ITER    :: 1_000_000
		just_started := cur_stat_offset.range_idx == 0 && cur_stat_offset.event_idx == 0
		if stats_state == .Started && did_multiselect {
			event_count := 0
			iter_max := just_started ? INITIAL_ITER : FULL_ITER

			broke_early := false
			range_loop: for range, r_idx in selected_ranges {
				start_idx := range.start
				if cur_stat_offset.range_idx > r_idx {
					continue
				} else if cur_stat_offset.range_idx == r_idx {
					start_idx = max(start_idx, cur_stat_offset.event_idx)
				}

				thread := processes[range.pid].threads[range.tid]
				events := thread.depths[range.did].events[start_idx:range.end]

				for ev, e_idx in events {
					if event_count > iter_max {
						cur_stat_offset = StatOffset{r_idx, start_idx + e_idx}
						broke_early = true
						break range_loop
					}

					duration := bound_duration(ev, thread.max_time)

					s, ok := sm_get(&stats, ev.name)
					if !ok {
						s = sm_insert(&stats, ev.name, Stats{min_time = 1e308})
					}
					s.count += 1
					s.total_time += duration
					s.self_time += ev.self_time
					s.min_time = min(s.min_time, duration)
					s.max_time = max(s.max_time, duration)
					total_tracked_time += duration

					event_count += 1
				}
			}

			if !broke_early {
				for i := 0; i < len(stats.entries); i += 1 {
					entry := &stats.entries[i]
					entry.val.avg_time = entry.val.total_time / f64(entry.val.count)
				}

				self_sort :: proc(a, b: StatEntry) -> bool {
					return a.val.self_time > b.val.self_time
				}
				sm_sort(&stats, self_sort)
				stats_state = .Finished
			}
		}

		// If the user selected a single rectangle
		if selected_event.pid != -1 && selected_event.tid != -1 && selected_event.did != -1 && selected_event.eid != -1 {
			p_idx := int(selected_event.pid)
			t_idx := int(selected_event.tid)
			d_idx := int(selected_event.did)
			e_idx := int(selected_event.eid)

			y := info_pane_y + top_line_gap

			thread := processes[p_idx].threads[t_idx]
			event := thread.depths[d_idx].events[e_idx]
			draw_text(fmt.tprintf("%s", in_getstr(event.name)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
			if event.args.len > 0 {
				draw_text(fmt.tprintf(" user data: %s", in_getstr(event.args)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
			}
			draw_text(fmt.tprintf("start time:%s", time_fmt(event.timestamp - total_min_time)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
			draw_text(fmt.tprintf("  duration:%s", time_fmt(bound_duration(event, thread.max_time))), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)
			draw_text(fmt.tprintf(" self time:%s", time_fmt(event.self_time)), Vec2{x_subpad, next_line(&y, em)}, p_font_size, monospace_font, text_color)

		// If we've got stats cooking already
		} else if stats_state == .Started {
			y := info_pane_y + top_line_gap
			center_x := width / 2
			
			total_count := 0
			cur_count := 0
			for range, r_idx in selected_ranges {
				thread := processes[range.pid].threads[range.tid]
				events := thread.depths[range.did].events

				total_count += len(events)
				if cur_stat_offset.range_idx > r_idx {
					cur_count += len(events)
				} else if cur_stat_offset.range_idx == r_idx {
					cur_count += cur_stat_offset.event_idx - range.start
				}
			}


			loading_str := fmt.tprint("Stats loading...")
			progress_str := fmt.tprintf("%d of %d", cur_count, total_count)
			hint_str := fmt.tprint("Release multi-select to get the rest of the stats")

			strs := []string{ loading_str, progress_str }
			if just_started && total_count >= INITIAL_ITER {
				strs = []string{ loading_str, progress_str, hint_str }
			}

			max_height := 0.0
			for str in strs {
				next_line(&max_height, em)
			}

			cur_y := y + ((height - y) / 2) - (max_height / 2)
			for str in strs {
				str_width := measure_text(str, p_font_size, default_font)
				draw_text(str, Vec2{center_x - (str_width / 2), next_line(&cur_y, em)}, p_font_size, default_font, text_color)
			}

		// If stats are ready to display
		} else if stats_state == .Finished && did_multiselect {
			y := info_pane_y + top_line_gap

			header_start := y
			header_height := 2 * em

			column_gap := 1.5 * em

			cursor := x_subpad

			text_outf :: proc(cursor: ^f64, y: f64, str: string, color := text_color) {
				width := measure_text(str, p_font_size, monospace_font)
				draw_text(str, Vec2{cursor^, y}, p_font_size, monospace_font, color)
				cursor^ += width
			}
			vs_outf :: proc(cursor: ^f64, column_gap, info_pane_y, info_pane_height: f64) {
				cursor^ += column_gap / 2
				draw_line(Vec2{cursor^, info_pane_y}, Vec2{cursor^, info_pane_y + info_pane_height}, 1, text_color2)
				cursor^ += column_gap / 2
			}

			full_time := total_max_time - total_min_time

			y += header_height + (em / 4)

			displayed_lines := info_line_count - 1
			if displayed_lines < len(stats.entries) {
				max_lines := len(stats.entries)

				// goofy hack to get line height
				tmp := y
				next_line(&tmp, em)
				line_height := tmp - y

				max_scroll := (f64(max_lines - displayed_lines) * line_height) + (em / 4)
				info_pane_scroll = max(info_pane_scroll, -max_scroll)
				y += info_pane_scroll
			}

			stat_idx := 0
			last_pos := 0.0
			stat_loop: for i := 0; i < len(stats.entries); i += 1 {
				entry := stats.entries[i]
				name := entry.key
				stat := entry.val

				stat_idx += 1
				if y < (info_pane_y + (em / 2)) {
					next_line(&y, em)
					continue stat_loop
				}

				if y > height {
					break stat_loop
				}
				last_pos = y

				cursor = x_subpad

				total_perc := (stat.total_time / total_tracked_time) * 100

				total_text := fmt.tprintf("%10s", stat_fmt(stat.total_time))
				total_perc_text := fmt.tprintf("%.1f%%", total_perc)

				self_text := fmt.tprintf("%10s", stat_fmt(stat.self_time))
				min_text := fmt.tprintf("%10s", stat_fmt(stat.min_time))
				avg_text := fmt.tprintf("%10s", stat_fmt(stat.avg_time))
				max_text := fmt.tprintf("%10s", stat_fmt(stat.max_time))

				text_outf(&cursor, y, self_text, text_color2);   cursor += column_gap
				{
					full_perc_width := measure_text(total_perc_text, p_font_size, monospace_font)
					perc_width := (ch_width * 6) - full_perc_width

					text_outf(&cursor, y, total_text, text_color2); cursor += ch_width
					cursor += perc_width
					draw_text(total_perc_text, Vec2{cursor, y}, p_font_size, monospace_font, text_color2); cursor += column_gap + full_perc_width
				}


				text_outf(&cursor, y, min_text, text_color2);   cursor += column_gap
				text_outf(&cursor, y, avg_text, text_color2);   cursor += column_gap
				text_outf(&cursor, y, max_text, text_color2);   cursor += column_gap

				y_before   := y - (em / 2)
				y_after    := y_before
				next_line(&y_after, em)


				dr := rect(cursor, y_before, (display_width - cursor - column_gap) * stat.total_time / full_time, y_after - y_before)
				cursor += column_gap / 2

				//name_width := measure_text(name, p_font_size, monospace_font)
				name_str := in_getstr(name)
				tmp_color := color_choices[name_color_idx(name_str)]
				draw_rect(dr, FVec4{tmp_color.x, tmp_color.y, tmp_color.z, 255})
				draw_text(name_str, Vec2{cursor, y_before + (em / 3)}, p_font_size, monospace_font, text_color)

				next_line(&y, em)
			}

			y = header_start
			cursor = 0

			draw_rect(rect(0, info_pane_y, width, 2 * em), subbar_color)
			draw_line(Vec2{0, info_pane_y + (2 * em)}, Vec2{width, info_pane_y + (2 * em)}, 1, line_color)

			column_header :: proc(cursor: ^f64, column_gap, text_y, rect_y, pane_h: f64, text: string, sort_type: SortState) {
				start_x := cursor^
				cursor^ += (column_gap / 2)

				width := measure_text(text, p_font_size, monospace_font)
				draw_text(text, Vec2{cursor^, text_y}, p_font_size, monospace_font, text_color)
				cursor^ += width + (column_gap / 2)
				end_x := cursor^

				if stat_sort_type == sort_type {
					arrow_icon := stat_sort_descending ? "\uf0dd" : "\uf0de"
					arrow_height := get_text_height(p_font_size, icon_font)
					arrow_width := measure_text(arrow_icon, p_font_size, icon_font)
					draw_text(arrow_icon, Vec2{end_x - arrow_width - (column_gap / 2), rect_y + (em) - (arrow_height / 2)}, p_font_size, icon_font, text_color)
				}

				draw_line(Vec2{cursor^, rect_y}, Vec2{cursor^, rect_y + pane_h}, 1, subbar_split_color)

				click_rect := rect(start_x, rect_y, end_x - start_x, 2 * em)
				if pt_in_rect(mouse_pos, click_rect) {
					set_cursor("pointer")
				}

				if clicked && pt_in_rect(clicked_pos, click_rect) {
					if stat_sort_type == sort_type {
						stat_sort_descending = !stat_sort_descending
					} else {
						stat_sort_type = sort_type
						stat_sort_descending = true
					}
					resort_stats = true
				}
			}

			self_header_text   := fmt.tprintf("%-10s", "   self")
			column_header(&cursor, column_gap, y, info_pane_y, info_pane_height, self_header_text, .SelfTime)

			total_header_text  := fmt.tprintf("%-17s", "      total")
			column_header(&cursor, column_gap, y, info_pane_y, info_pane_height, total_header_text, .TotalTime)

			min_header_text    := fmt.tprintf("%-10s", "   min.")
			column_header(&cursor, column_gap, y, info_pane_y, info_pane_height, min_header_text, .MinTime)

			avg_header_text    := fmt.tprintf("%-10s", "   avg.")
			column_header(&cursor, column_gap, y, info_pane_y, info_pane_height, avg_header_text, .AvgTime)

			max_header_text    := fmt.tprintf("%-10s", "   max.")
			column_header(&cursor, column_gap, y, info_pane_y, info_pane_height, max_header_text, .MaxTime)

			name_header_text   := fmt.tprintf("%-10s", "   name")
			text_outf(&cursor, y, name_header_text, text_color)
		} else {
			y := height - em - top_line_gap

			draw_text("Shift-click and drag to get stats for multiple rectangles", Vec2{x_subpad, prev_line(&y, em)}, p_font_size, default_font, text_color)
			draw_text("Click on a rectangle to inspect", Vec2{x_subpad, prev_line(&y, em)}, p_font_size, default_font, text_color)
		}
	}

	if resort_stats {
		less: proc(a, b: StatEntry) -> bool
		switch stat_sort_type {
		case .SelfTime:
			less = proc(a, b: StatEntry) -> bool {
				if stat_sort_descending {
					return a.val.self_time > b.val.self_time
				} else {
					return a.val.self_time < b.val.self_time
				}
			}
		case .TotalTime:
			less = proc(a, b: StatEntry) -> bool {
				if stat_sort_descending {
					return a.val.total_time > b.val.total_time
				} else {
					return a.val.total_time < b.val.total_time
				}
			}
		case .MinTime:
			less = proc(a, b: StatEntry) -> bool {
				if stat_sort_descending {
					return a.val.min_time > b.val.min_time
				} else {
					return a.val.min_time < b.val.min_time
				}
			}
		case .AvgTime:
			less = proc(a, b: StatEntry) -> bool {
				if stat_sort_descending {
					return a.val.avg_time > b.val.avg_time
				} else {
					return a.val.avg_time < b.val.avg_time
				}
			}
		case .MaxTime:
			less = proc(a, b: StatEntry) -> bool {
				if stat_sort_descending {
					return a.val.max_time > b.val.max_time
				} else {
					return a.val.max_time < b.val.max_time
				}
			}
		}
		sm_sort(&stats, less)
		resort_stats = false
	}

	// Render toolbar background
	draw_rect(rect(0, 0, width, toolbar_height), toolbar_color)

	// draw toolbar
	{
		edge_pad := 1 * em
		button_height := 2 * em
		button_width  := 2 * em
		button_pad    := 0.5 * em

		cursor_x := edge_pad

		// Draw Logo
		logo_text := "spall"
		logo_width := measure_text(logo_text, h1_font_size, default_font)
		draw_text(logo_text, Vec2{cursor_x, (toolbar_height / 2) - (h1_height / 2)}, h1_font_size, default_font, toolbar_text_color)
		cursor_x += logo_width + edge_pad

		// Open File
		if button(rect(cursor_x, (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf07c", "open file", icon_font, 0, width) {
			open_file_dialog()
		}
		cursor_x += button_width + button_pad

		// Reset Camera
		if button(rect(cursor_x, (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf066", "reset camera", icon_font, 0, width) {
			reset_camera(display_width)
		}
		cursor_x += button_width + button_pad

		// Process All Events
		if button(rect(cursor_x, (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf1fe", "get stats for the whole file", icon_font, 0, width) {
			stats_state = .Started
			did_multiselect = true
			total_tracked_time = 0.0
			cur_stat_offset = StatOffset{}
			selected_event = {-1, -1, -1, -1}
			info_pane_scroll = 0
			info_pane_scroll_vel = 0

			big_global_arena.offset = current_alloc_offset
			resize(&selected_ranges, 0)
			sm_clear(&stats)

			for proc_v, p_idx in processes {
				for tm, t_idx in proc_v.threads {
					for depth, d_idx in tm.depths {
						append(&selected_ranges, Range{p_idx, t_idx, d_idx, 0, len(depth.events)})
					}
				}
			}
		}
		cursor_x += button_width + button_pad

		file_name_width := measure_text(file_name, h1_font_size, default_font)
		name_x := max((display_width / 2) - (file_name_width / 2), cursor_x)
		draw_text(file_name, Vec2{name_x, (toolbar_height / 2) - (h1_height / 2)}, h1_font_size, default_font, toolbar_text_color)

		// colormode button nonsense
		color_text : string
		tool_text : string
		switch colormode {
		case .Auto:
			tool_text = "switch to dark colors"
			color_text = "\uf042"
		case .Dark:
			tool_text = "switch to light colors"
			color_text = "\uf10c"
		case .Light:
			tool_text = "switch to auto colors"
			color_text = "\uf111"
		}

		if button(rect(width - edge_pad - button_width, (toolbar_height / 2) - (button_height / 2), button_width, button_height), color_text, tool_text, icon_font, 0, width) {
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
		if button(rect(width - edge_pad - ((button_width * 2) + (button_pad)), (toolbar_height / 2) - (button_height / 2), button_width, button_height), "\uf188", "toggle debug mode", icon_font, 0, width) {
			enable_debug = !enable_debug
		}
	}

	// reset the cursor if we're not over a selectable thing
	if !is_hovering {
		reset_cursor()
	}

	// Render debug info
	if enable_debug {
		y := height - em - top_line_gap


		if queue.len(fps_history) > 100 { queue.pop_front(&fps_history) }
		queue.push_back(&fps_history, 1 / _dt)
		draw_graph("FPS", &fps_history, Vec2{width - mini_graph_padded_width - 160, disp_rect.pos.y + graph_header_height})

		hash_str := fmt.tprintf("Build: 0x%X", abs(build_hash))
		hash_width := measure_text(hash_str, p_font_size, monospace_font)
		draw_text(hash_str, Vec2{width - hash_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

		seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
		seed_width := measure_text(seed_str, p_font_size, monospace_font)
		draw_text(seed_str, Vec2{width - seed_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

		rects_str := fmt.tprintf("Rect Count: %d", rect_count)
		rects_txt_width := measure_text(rects_str, p_font_size, monospace_font)
		draw_text(rects_str, Vec2{width - rects_txt_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

		buckets_str := fmt.tprintf("Bucket Count: %d", bucket_count)
		buckets_txt_width := measure_text(buckets_str, p_font_size, monospace_font)
		draw_text(buckets_str, Vec2{width - buckets_txt_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)

		events_str := fmt.tprintf("Event Count: %d", rect_count - bucket_count)
		events_txt_width := measure_text(events_str, p_font_size, monospace_font)
		draw_text(events_str, Vec2{width - events_txt_width - x_subpad, prev_line(&y, em)}, p_font_size, monospace_font, text_color2)
	}

	// if there's a rectangle tooltip to render, now's the time.
	if rendered_rect_tooltip {
		tip_pos := mouse_pos
		tip_pos += Vec2{1, 2} * em / dpr

		ids := rect_tooltip_rect
		thread := processes[ids.pid].threads[ids.tid]
		depth := thread.depths[ids.did]
		ev := depth.events[ids.eid]

		duration := bound_duration(ev, thread.max_time)

		rect_tooltip_name := in_getstr(ev.name)
		if ev.duration == -1 {
			rect_tooltip_name = fmt.tprintf("%s (Did Not Finish)", in_getstr(ev.name))
		}

		rect_tooltip_stats: string
		if ev.self_time != 0 && ev.self_time != duration {
			rect_tooltip_stats = fmt.tprintf("%s (self %s)", tooltip_fmt(duration), tooltip_fmt(ev.self_time))
		} else {
			rect_tooltip_stats = fmt.tprintf("%s", tooltip_fmt(duration))
		}

		text_height := get_text_height(p_font_size, default_font)
		name_width := measure_text(rect_tooltip_name, p_font_size, default_font)
		stats_width := measure_text(rect_tooltip_stats, p_font_size, default_font)

		args := in_getstr(ev.args)
		args_width := measure_text(args, p_font_size, default_font)

		rect_width := max(name_width + em + stats_width + em, args_width + em)
		rect_height := text_height + (1.25 * em)
		if len(args) > 0 {
			next_line(&rect_height, em)
		}

		tooltip_rect := rect(tip_pos.x, tip_pos.y - (em / 2), rect_width, rect_height)


		min_x := graph_rect.pos.x
		max_x := graph_rect.pos.x + graph_rect.size.x
		if tooltip_rect.pos.x + tooltip_rect.size.x > max_x {
			tooltip_rect.pos.x = max_x - tooltip_rect.size.x
		}
		if tooltip_rect.pos.x < min_x {
			tooltip_rect.pos.x = min_x
		}

		draw_rect(tooltip_rect, bg_color)
		draw_rect_outline(tooltip_rect, 1, line_color)
		tooltip_start_x := tooltip_rect.pos.x + (em / 2)
		tooltip_start_y := tooltip_rect.pos.y + (em / 2)

		cursor_x := tooltip_start_x
		cursor_y := tooltip_start_y

		draw_text(rect_tooltip_stats, Vec2{cursor_x, cursor_y}, p_font_size, default_font, rect_tooltip_stats_color)
		cursor_x += (em * 0.35) + stats_width
		draw_text(rect_tooltip_name, Vec2{cursor_x, cursor_y}, p_font_size, default_font, text_color)

		if len(args) > 0 {
			next_line(&cursor_y, em)
			draw_text(args, Vec2{tooltip_start_x, cursor_y}, p_font_size, default_font, text_color)
		}
	}

	// save me my battery, plz
	PAN_X_EPSILON :: 0.01
	PAN_Y_EPSILON :: 1.0
	SCALE_EPSILON :: 0.01
	SCROLL_EPSILON :: 0.01
	if !render_one_more &&
	   math.abs(cam.pan.x - cam.target_pan_x) < PAN_X_EPSILON && 
	   math.abs(cam.vel.y - 0) < PAN_Y_EPSILON && 
	   math.abs((cam.current_scale - cam.target_scale) / cam.target_scale) < SCALE_EPSILON &&
	   math.abs(info_pane_scroll_vel) < SCROLL_EPSILON &&
	   stats_state != .Started && !anim_playing {
		cam.pan.x = cam.target_pan_x
		cam.vel.y = 0
		cam.current_scale = cam.target_scale
		info_pane_scroll_vel = 0
		was_sleeping = true
		return false
	}

	was_sleeping = false
	return true
}

