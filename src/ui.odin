package main

import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:runtime"
import "core:slice"
import "core:strings"
import "core:os"

to_world_x :: proc(cam: Camera, x: f64) -> f64 {
	return (x - cam.pan.x) / cam.current_scale
}
to_world_y :: proc(cam: Camera, y: f64) -> f64 {
	return y + cam.pan.y
}
to_world_pos :: proc(cam: Camera, pos: Vec2) -> Vec2 {
	return Vec2{to_world_x(cam, pos.x), to_world_y(cam, pos.y)}
}

get_current_window :: proc(trace: ^Trace, cam: Camera, ui_state: ^UIState) -> (i64, i64) {
	display_range_start := i64(to_world_x(cam, 0))
	display_range_end   := i64(to_world_x(cam, ui_state.full_flamegraph_rect.w))
	return display_range_start, display_range_end
}

next_line :: proc(y: ^f64, h: f64) -> f64 {
	res := y^
	y^ += h + (h / 1.5)
	return res
}
prev_line :: proc(y: ^f64, h: f64) -> f64 {
	res := y^
	y^ -= h + (h / 3)
	return res
}

reset_flamegraph_camera :: proc(trace: ^Trace, ui_state: ^UIState) {
	cam = Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}
	if trace.event_count == 0 { trace.total_min_time = 0; trace.total_max_time = 100000000000000; trace.stamp_scale = 1; }

	start_time: f64 = 0
	end_time  := f64(trace.total_max_time - trace.total_min_time)

	side_pad  := 2 * em

	cam.current_scale = rescale(cam.current_scale, start_time, end_time, 0, ui_state.full_flamegraph_rect.w - (side_pad * 2))
	cam.target_scale = cam.current_scale

	cam.pan.x += side_pad
	cam.target_pan_x = cam.pan.x
}

tooltip :: proc(pos: Vec2, min_x, max_x: f64, text: string) {
	text_width := measure_text(text, .PSize, .DefaultFont)
	text_height := get_text_height(.PSize, .DefaultFont)

	tooltip_rect := Rect{pos.x, pos.y - (em / 2), text_width + em, text_height + (1.25 * em)}
	if tooltip_rect.x + tooltip_rect.w > max_x {
		tooltip_rect.x = max_x - tooltip_rect.w
	}
	if tooltip_rect.x < min_x {
		tooltip_rect.x = min_x
	}

	draw_rect(tooltip_rect, bg_color)
	draw_rect_outline(tooltip_rect, 1, line_color)
	draw_text(text, Vec2{tooltip_rect.x + (em / 2), tooltip_rect.y + (em / 2)}, .PSize, .DefaultFont, text_color)
}

button :: proc(in_rect: Rect, label_text, tooltip_text: string, font: FontType, min_x, max_x: f64) -> bool {
	draw_rect(in_rect, toolbar_button_color)
	label_width := measure_text(label_text, .PSize, font)
	label_height := get_text_height(.PSize, font)
	draw_text(label_text, 
	Vec2{
		in_rect.x + (in_rect.w / 2) - (label_width / 2), 
		in_rect.y + (in_rect.h / 2) - (label_height / 2),
	}, .PSize, font, toolbar_text_color)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor("pointer")
		if clicked {
			return true
		} else {
			tip_pos := Vec2{in_rect.x, in_rect.y + in_rect.h + em}
			tooltip(tip_pos, min_x, max_x, tooltip_text)
		}
	}
	return false
}

draw_histogram :: proc(trace: ^Trace, header: string, stat: ^Stats, pos: Vec2, graph_size: f64) {
	line_width : f64 = 1
	graph_edge_pad : f64 = 2 * em
	line_gap := (em / 1.5)

	history := stat.hist
	temp_history := make([]f64, len(history), context.temp_allocator)

	max_val : f64 = 0
	min_val : f64 = max(f64)
	for entry, i in history {
		val := math.log2_f64(entry + 1)
		temp_history[i] = val

		max_val = max(max_val, val)
		min_val = min(min_val, val)
	}
	max_range := max_val - min_val

	graph_top := pos.y + em + line_gap
	graph_bottom := graph_top + graph_size

	graph_y_bounds := graph_size - (graph_edge_pad * 2)
	graph_x_bounds := graph_size - graph_edge_pad

	text_x_overhead := 6 * em
	graph_overdraw_rect := Rect{pos.x - text_x_overhead, pos.y - line_gap, graph_size + text_x_overhead + (em / 2), ((em + line_gap) * 2) + graph_size + (em / 2) + line_gap}

	// reset mouse if we're in the graph
	if pt_in_rect(mouse_pos, graph_overdraw_rect) {
		rect_tooltip_rect = EventID{-1, -1, -1, -1}
		rect_tooltip_pos = Vec2{}
		rendered_rect_tooltip = false
		reset_cursor()
	}

	draw_rect(graph_overdraw_rect, bg_color)
	draw_rect(Rect{pos.x, graph_top, graph_size, graph_size}, bg_color2)
	draw_rect_outline(Rect{pos.x, graph_top, graph_size, graph_size}, 2, outline_color)

	header_str := trunc_string(header, (em / 2), graph_size)

	text_render_width := measure_text(header_str, .PSize, .DefaultFont)
	center_offset := (graph_size / 2) - (text_render_width / 2)
	draw_text(header_str, Vec2{pos.x + center_offset, pos.y}, .PSize, .MonoFont, text_color)

	high_height := graph_top + graph_edge_pad - (em / 2)
	low_height := graph_bottom - graph_edge_pad - (em / 2)

	near_width := pos.x + (graph_edge_pad / 2)
	far_width  := pos.x + graph_size - (graph_edge_pad / 2)

	if len(temp_history) > 1 {
		buf: [384]byte
		b := strings.builder_from_bytes(buf[:])

		y_tac_count := 5
		for i := 0; i < y_tac_count; i += 1 {
			cur_perc := f64(i) / f64(y_tac_count - 1)
			cur_y_val := math.pow(2, math.lerp(min_val, max_val, cur_perc))
			cur_y_height := math.lerp(low_height, high_height, cur_perc)

			strings.builder_reset(&b)
			my_write_float(&b, cur_y_val, 0)
			cur_y_str := strings.to_string(b)
			cur_y_width := measure_text(cur_y_str, .PSize, .DefaultFont) + line_gap
			draw_text(cur_y_str, Vec2{(pos.x - 5) - cur_y_width, cur_y_height}, .PSize, .DefaultFont, text_color)

			draw_line(Vec2{pos.x - 5, cur_y_height + (em / 2)}, Vec2{pos.x + 5, cur_y_height + (em / 2)}, 1, graph_color)
		}

		x_tac_count := 4
		for i := 0; i < x_tac_count; i += 1 {
			cur_perc := f64(i) / f64(x_tac_count - 1)
			cur_x_val := math.lerp(f64(stat.min_time), f64(stat.max_time), cur_perc)
			cur_x_pos := math.lerp(near_width, far_width, cur_perc)

			cur_x_str := stat_fmt(disp_time(trace, cur_x_val))
			cur_x_width := measure_text(cur_x_str, .PSize, .DefaultFont)
			draw_text(cur_x_str, Vec2{cur_x_pos - (cur_x_width / 2), graph_bottom + 5}, .PSize, .DefaultFont, text_color)

			draw_line(Vec2{cur_x_pos, graph_bottom - 5}, Vec2{cur_x_pos, graph_bottom + 5}, 1, graph_color)
		}
	}


	last_x : f64 = 0
	last_y : f64 = 0
	for entry, i in temp_history {
		point_x_offset : f64 = 0
		if len(temp_history) != 0 {
			point_x_offset = f64(i) * (graph_x_bounds / f64(len(temp_history)))
		}

		point_y_offset : f64 = 0
		if max_range != 0 {
			point_y_offset = f64(entry - min_val) * (graph_y_bounds / f64(max_range))
		}

		point_x := pos.x + point_x_offset + (graph_edge_pad / 2)
		point_y := graph_top + graph_size - point_y_offset - graph_edge_pad

		if len(temp_history) > 1  && i > 0 {
			draw_line(Vec2{last_x, last_y}, Vec2{point_x, point_y}, line_width, graph_color)
		}

		last_x = point_x
		last_y = point_y
	}

	if len(temp_history) > 1 {
		avg_offset := rescale(stat.avg_time, f64(stat.min_time), f64(stat.max_time), near_width, far_width)
		draw_line(Vec2{avg_offset, graph_top + graph_edge_pad}, Vec2{avg_offset, graph_bottom - graph_edge_pad}, 1, BVec4{255, 0, 0, 255})
	}
}

draw_graph :: proc(header: string, history: ^queue.Queue(f64), pos: Vec2) {
	line_width : f64 = 1
	graph_edge_pad : f64 = 2 * em
	line_gap := (em / 1.5)
	graph_size: f64 = 150

	max_val : f64 = 0
	min_val : f64 = 1e5000
	sum_val : f64 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)
		max_val = max(max_val, entry)
		min_val = min(min_val, entry)
		sum_val += entry
	}
	max_range := max_val - min_val
	avg_val := sum_val / 100

	text_width := measure_text(header, .PSize, .DefaultFont)
	center_offset := (graph_size / 2) - (text_width / 2)
	draw_text(header, Vec2{pos.x + center_offset, pos.y}, .PSize, .DefaultFont, text_color)

	graph_top := pos.y + em + line_gap
	draw_rect(Rect{pos.x, graph_top, graph_size, graph_size}, bg_color2)
	draw_rect_outline(Rect{pos.x, graph_top, graph_size, graph_size}, 2, outline_color)

	draw_line(Vec2{pos.x - 5, graph_top + graph_size - graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_size - graph_edge_pad}, 1, graph_color)
	draw_line(Vec2{pos.x - 5, graph_top + graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_edge_pad}, 1, graph_color)

	if queue.len(history^) > 1 {
		buf: [384]byte
		b := strings.builder_from_bytes(buf[:])

		high_height := graph_top + graph_edge_pad - (em / 2)
		low_height := graph_top + graph_size - graph_edge_pad - (em / 2)
		avg_height := rescale(f64(avg_val), f64(min_val), f64(max_val), low_height, high_height)

		strings.builder_reset(&b)
		my_write_float(&b, max_val, 3)
		high_str := strings.to_string(b)
		high_width := measure_text(high_str, .PSize, .DefaultFont) + line_gap
		draw_text(high_str, Vec2{(pos.x - 5) - high_width, high_height}, .PSize, .DefaultFont, text_color)

		if queue.len(history^) > 90 {
			draw_line(Vec2{pos.x - 5, avg_height + (em / 2)}, Vec2{pos.x + 5, avg_height + (em / 2)}, 1, graph_color)

			strings.builder_reset(&b)
			my_write_float(&b, avg_val, 3)
			avg_str := strings.to_string(b)

			avg_width := measure_text(avg_str, .PSize, .DefaultFont) + line_gap
			draw_text(avg_str, Vec2{(pos.x - 5) - avg_width, avg_height}, .PSize, .DefaultFont, text_color)
		}

		strings.builder_reset(&b)
		my_write_float(&b, min_val, 3)
		low_str := strings.to_string(b)

		low_width := measure_text(low_str, .PSize, .DefaultFont) + line_gap
		draw_text(low_str, Vec2{(pos.x - 5) - low_width, low_height}, .PSize, .DefaultFont, text_color)
	}

	graph_y_bounds := graph_size - (graph_edge_pad * 2)
	graph_x_bounds := graph_size - graph_edge_pad

	last_x : f64 = 0
	last_y : f64 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)

		point_x_offset : f64 = 0
		if queue.len(history^) != 0 {
			point_x_offset = f64(i) * (graph_x_bounds / f64(queue.len(history^)))
		}

		point_y_offset : f64 = 0
		if max_range != 0 {
			point_y_offset = f64(entry - min_val) * (graph_y_bounds / f64(max_range))
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

draw_header :: proc(trace: ^Trace, ui_state: ^UIState) {
	header_rect := ui_state.header_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect

	// Render toolbar background
	draw_rect(header_rect, toolbar_color)

	// draw toolbar
	{
		edge_pad := 1 * em
		button_height := 2 * em
		button_width  := 2 * em
		button_pad    := 0.5 * em

		cursor_x := edge_pad

		// Draw Logo
		logo_text := "spall"
		logo_width := measure_text(logo_text, .H1Size, .DefaultFont)
		draw_text(logo_text, Vec2{cursor_x, (header_rect.h / 2) - (h1_height / 2)}, .H1Size, .DefaultFont, toolbar_text_color)
		cursor_x += logo_width + edge_pad

		// Open File
		if button(Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf07c", "open file", .IconFont, 0, ui_state.width) {
			open_file_dialog()
		}
		cursor_x += button_width + button_pad

		// Reset Camera
		if button(Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf066", "reset camera", .IconFont, 0, ui_state.width) {
			reset_flamegraph_camera(trace, ui_state)
		}
		cursor_x += button_width + button_pad

		// Process All Events
		if button(Rect{cursor_x, (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf1fe", "get stats for the whole file", .IconFont, 0, ui_state.width) {
			trace.stats_start_time = 0
			trace.stats_end_time = f64(trace.total_max_time - trace.total_min_time)
			ui_state.multiselecting = true
			build_selected_ranges(trace, ui_state)
		}
		cursor_x += button_width + button_pad

		file_name_width := measure_text(trace.file_name, .H1Size, .DefaultFont)
		name_x := max((full_flamegraph_rect.w / 2) - (file_name_width / 2), cursor_x)
		draw_text(trace.file_name, Vec2{name_x, (header_rect.h / 2) - (h1_height / 2)}, .H1Size, .DefaultFont, toolbar_text_color)

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

		if button(Rect{
			ui_state.width - edge_pad - button_width, 
			(header_rect.h / 2) - (button_height / 2), 
			button_width,
			button_height,
		}, color_text, tool_text, .IconFont, 0, ui_state.width) {
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
		if button(Rect{ui_state.width - edge_pad - ((button_width * 2) + (button_pad)), (header_rect.h / 2) - (button_height / 2), button_width, button_height}, "\uf188", "toggle debug mode", .IconFont, 0, ui_state.width) {
			enable_debug = !enable_debug
		}
	}
}

draw_debug :: proc(ui_state: ^UIState) {
	minimap_rect := ui_state.minimap_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	flamegraph_header_height := ui_state.flamegraph_header_height

	text_y := ui_state.height - em - ui_state.top_line_gap
	graph_pos := Vec2{ui_state.width - minimap_rect.w - 150, full_flamegraph_rect.y + flamegraph_header_height}
	x_subpad := em

	y := text_y
	draw_graph("FPS", &fps_history, graph_pos)

	hash_str := fmt.tprintf("Build: 0x%X", abs(build_hash))
	hash_width := measure_text(hash_str, .PSize, .MonoFont)
	draw_text(hash_str, Vec2{ui_state.width - hash_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	seed_str := fmt.tprintf("Seed: 0x%X", random_seed)
	seed_width := measure_text(seed_str, .PSize, .MonoFont)
	draw_text(seed_str, Vec2{ui_state.width - seed_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	rects_str := fmt.tprintf("Rect Count: %d", rect_count)
	rects_txt_width := measure_text(rects_str, .PSize, .MonoFont)
	draw_text(rects_str, Vec2{ui_state.width - rects_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	buckets_str := fmt.tprintf("Bucket Count: %d", bucket_count)
	buckets_txt_width := measure_text(buckets_str, .PSize, .MonoFont)
	draw_text(buckets_str, Vec2{ui_state.width - buckets_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)

	events_str := fmt.tprintf("Event Count: %d", rect_count - bucket_count)
	events_txt_width := measure_text(events_str, .PSize, .MonoFont)
	draw_text(events_str, Vec2{ui_state.width - events_txt_width - x_subpad, prev_line(&y, em)}, .PSize, .MonoFont, text_color2)
}

draw_rect_tooltip :: proc(trace: ^Trace, ui_state: ^UIState) {
	full_flamegraph_rect := ui_state.full_flamegraph_rect

	tip_pos := mouse_pos
	tip_pos += Vec2{1, 2} * em / dpr

	ids := rect_tooltip_rect
	thread := trace.processes[ids.pid].threads[ids.tid]
	depth := thread.depths[ids.did]
	ev := depth.events[ids.eid]

	duration := bound_duration(&ev, thread.max_time)

	rect_tooltip_name := in_getstr(&trace.string_block, ev.name)
	if ev.duration == -1 {
		rect_tooltip_name = fmt.tprintf("%s (Did Not Finish)", in_getstr(&trace.string_block, ev.name))
	}

	rect_tooltip_stats: string
	if ev.self_time != 0 && ev.self_time != duration {
		rect_tooltip_stats = fmt.tprintf("%s (self %s)", tooltip_fmt(disp_time(trace, f64(duration))), tooltip_fmt(disp_time(trace, f64(ev.self_time))))
	} else {
		rect_tooltip_stats = tooltip_fmt(disp_time(trace, f64(duration)))
	}

	text_height := get_text_height(.PSize, .DefaultFont)
	name_width := measure_text(rect_tooltip_name, .PSize, .DefaultFont)
	stats_width := measure_text(rect_tooltip_stats, .PSize, .DefaultFont)

	rect_height := text_height + (1.25 * em)
	rect_width := name_width + em + stats_width + em

	args := ""
	args_width : f64 = 0
	if ev.args > 0 {
		args = in_getstr(&trace.string_block, ev.args)
		args_width = measure_text(args, .PSize, .DefaultFont)
		rect_width = max(rect_width, args_width + em)
		next_line(&rect_height, em)
	}

	tooltip_rect := Rect{tip_pos.x, tip_pos.y - (em / 2), rect_width, rect_height}

	min_x := full_flamegraph_rect.x
	max_x := full_flamegraph_rect.x + full_flamegraph_rect.w
	if tooltip_rect.x + tooltip_rect.w > max_x {
		tooltip_rect.x = max_x - tooltip_rect.w
	}
	if tooltip_rect.x < min_x {
		tooltip_rect.x = min_x
	}

	draw_rect(tooltip_rect, bg_color)
	draw_rect_outline(tooltip_rect, 1, line_color)
	tooltip_start_x := tooltip_rect.x + (em / 2)
	tooltip_start_y := tooltip_rect.y + (em / 2)

	cursor_x := tooltip_start_x
	cursor_y := tooltip_start_y

	draw_text(rect_tooltip_stats, Vec2{cursor_x, cursor_y}, .PSize, .DefaultFont, rect_tooltip_stats_color)
	cursor_x += (em * 0.35) + stats_width
	draw_text(rect_tooltip_name, Vec2{cursor_x, cursor_y}, .PSize, .DefaultFont, text_color)

	if len(args) > 0 {
		next_line(&cursor_y, em)
		draw_text(args, Vec2{tooltip_start_x, cursor_y}, .PSize, .DefaultFont, text_color)
	}
}

draw_flamegraphs :: proc(trace: ^Trace, start_time, end_time: i64, ui_state: ^UIState) {
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect
	padded_flamegraph_rect := ui_state.padded_flamegraph_rect

	flamegraph_header_height := ui_state.flamegraph_header_height
	flamegraph_toptext_height := ui_state.flamegraph_toptext_height
	info_pane_rect := ui_state.info_pane_rect

	// graph-relative timebar and subdivisions
	division_ns, draw_tick_start_ns, display_range_start_ns: f64
	ticks: int
	{
		// figure out how many divisions to split the current scale into
		window_range_ns := (full_flamegraph_rect.w / cam.current_scale) * trace.stamp_scale
		v1 := math.log10(window_range_ns)
		v2 := math.floor(v1)
		rem := v1 - v2

		division_ns = math.pow(10, v2)                           // multiples of 10
		if rem < 0.3      { division_ns -= (division_ns * 0.8) } // multiples of 2
		else if rem < 0.6 { division_ns -= (division_ns / 2)   } // multiples of 5

		// find the current range in ns
		display_range_start_ns =  (                     (0 - cam.pan.x) / cam.current_scale) * trace.stamp_scale
		display_range_end_ns   := ((full_flamegraph_rect.w - cam.pan.x) / cam.current_scale) * trace.stamp_scale

		// round down to make sure we get the first line on screen
		draw_tick_start_ns = f_round_down(display_range_start_ns, division_ns)
		draw_tick_end_ns  := f_round_down(display_range_end_ns,   division_ns)

		// determine how many divisions to draw, with fudge-factor
		tick_range_ns := draw_tick_end_ns - draw_tick_start_ns
		ticks = int(tick_range_ns / division_ns) + 3

		subdivisions := 5
		line_x_start := -4
		line_x_end   := ticks * subdivisions

		// actually draw the lines
		line_start := full_flamegraph_rect.y + flamegraph_header_height - ui_state.top_line_gap
		line_height := full_flamegraph_rect.h
		for i := line_x_start; i < line_x_end; i += 1 {
			tick_time_ns := draw_tick_start_ns + (f64(i) * (division_ns / f64(subdivisions)))
			scaled_tick_time := tick_time_ns / trace.stamp_scale
			x_off := (scaled_tick_time * cam.current_scale) + cam.pan.x
			color := (i % subdivisions) != 0 ? subdivision_color : division_color

			append(&gl_rects, DrawRect{f32(ui_state.side_pad + x_off), 1.5, BVec4{u8(color.x), u8(color.y), u8(color.z), u8(color.w)}})
		}

		gl_push_rects(gl_rects[:], line_start, line_height)
		resize(&gl_rects, 0)
	}

	// graph
	cur_y := padded_flamegraph_rect.y - cam.pan.y
	proc_loop: for proc_v, p_idx in &trace.processes {
		h1_size : f64 = 0
		if len(trace.processes) > 1 {
			if cur_y > full_flamegraph_rect.y {
				draw_text(get_proc_name(trace, &proc_v), Vec2{ui_state.side_pad + 5, cur_y}, .H1Size, .DefaultFont, text_color)
			}

			h1_size = h1_height + (h1_height / 2)
			cur_y += h1_size
		}

		thread_loop: for thread, t_idx in &proc_v.threads {
			last_cur_y := cur_y
			h2_size := h2_height + (h2_height / 2)
			cur_y += h2_size

			thread_gap := 8.0
			thread_advance := ((f64(len(thread.depths)) * ui_state.rect_height) + thread_gap)

			if cur_y > info_pane_rect.y {
				break proc_loop
			}
			if cur_y + thread_advance < 0 {
				cur_y += thread_advance
				continue
			}

			if last_cur_y > full_flamegraph_rect.y {
				draw_text(get_thread_name(trace, &thread), Vec2{ui_state.side_pad + 5, last_cur_y}, .H2Size, .DefaultFont, text_color)
			}

			cur_depth_off := 0
			for depth, d_idx in &thread.depths {
				tree := depth.tree

				found_rid := -1
				range_loop: for range, r_idx in trace.selected_ranges {
					if range.pid == i32(p_idx) && range.tid == i32(t_idx) && range.did == i32(d_idx) {
						found_rid = r_idx
						break
					}
				}

				// If we blow this, we're in space
				tree_stack := [128]int{}
				stack_len := 0

				tree_stack[0] = 0; stack_len += 1
				for stack_len > 0 {
					stack_len -= 1

					tree_idx := tree_stack[stack_len]
					cur_node := &tree[tree_idx]

					if cur_node.end_time < start_time || cur_node.start_time > end_time {
						continue
					}

					time_range := f64(cur_node.end_time - cur_node.start_time)
					range_width := time_range * cam.current_scale

					// draw summary faketangle
					min_width := 2.0
					if (range_width / math.sqrt_f64(CHUNK_NARY_WIDTH)) < min_width {

						y := ui_state.rect_height * f64(d_idx)
						h := ui_state.rect_height

						x := f64(cur_node.start_time)
						w := min_width * math.sqrt_f64(CHUNK_NARY_WIDTH)
						xm := x * cam.target_scale

						r_x   := x * cam.current_scale
						end_x := r_x + w

						r_x   += cam.pan.x + full_flamegraph_rect.x
						end_x += cam.pan.x + full_flamegraph_rect.x

						r_x    = max(r_x, 0)

						r_y := cur_y + y
						dr  := Rect{r_x, r_y, end_x - r_x, h}

						rect_color := cur_node.avg_color
						grey := greyscale(cur_node.avg_color)
						if ui_state.multiselecting {
							if found_rid != -1 {
								range := trace.selected_ranges[found_rid]   
								ev_start, ev_end := get_event_range(&depth, tree_idx)

								if !range_in_range(ev_start, ev_end, int(range.start), int(range.end)) {
									rect_color = grey
								}
							} else {
								rect_color = grey
							}
						}

						append(&gl_rects,
							DrawRect{f32(dr.x), f32(dr.w), BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}})

						rect_count += 1
						bucket_count += 1
						continue
					}

					// we're at a bottom node, draw the whole thing
					child_count := get_child_count(&depth, tree_idx)
					if child_count <= 0 {
						event_start_idx, event_end_idx := get_event_range(&depth, tree_idx)
						scan_arr := depth.events[event_start_idx:event_end_idx]
						y := ui_state.rect_height * f64(d_idx)
						h := ui_state.rect_height
						for ev, de_id in &scan_arr {
							x := f64(ev.timestamp - trace.total_min_time)
							duration := f64(bound_duration(&ev, thread.max_time))
							w := max(duration * cam.current_scale, 2.0)
							xm := x * cam.target_scale

							// Carefully extract the [start, end] interval of the rect so that we can clip the left
							// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
							// problems drawing a rectangle which starts at a massively huge negative number on
							// the left.
							r_x   := x * cam.current_scale
							end_x := r_x + w

							r_x   += cam.pan.x + full_flamegraph_rect.x
							end_x += cam.pan.x + full_flamegraph_rect.x

							r_x    = max(r_x, 0)

							r_y := cur_y + y
							dr := Rect{r_x, r_y, end_x - r_x, h}

							if !rect_in_rect(dr, inner_flamegraph_rect) {
								continue
							}

							ev_name := in_getstr(&trace.string_block, ev.name)
							idx := name_color_idx(ev.name)
							e_idx := event_start_idx + de_id

							rect_color := trace.color_choices[idx]
							grey := greyscale(trace.color_choices[idx])
							if ui_state.multiselecting {
								if found_rid != -1 {
									range := trace.selected_ranges[found_rid]   
									if !val_in_range(i32(e_idx), range.start, range.end - 1) { 
										rect_color = grey
									}
								} else {
									rect_color = grey
								}
							}

							if int(selected_event.pid) == p_idx && int(selected_event.tid) == t_idx &&
							int(selected_event.did) == d_idx && int(selected_event.eid) == e_idx {
								rect_color.x += 30
								rect_color.y += 30
								rect_color.z += 30
							}

							append(&gl_rects,
								DrawRect{f32(dr.x), f32(dr.w), BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}})
							rect_count += 1

							underhang := full_flamegraph_rect.x - dr.x
							overhang := (full_flamegraph_rect.x + full_flamegraph_rect.w) - dr.x
							disp_w := min(dr.w - underhang, dr.w, overhang)

							display_name := ev_name
							if ev.duration == -1 {
								display_name = fmt.tprintf("%s (Did Not Finish)", ev_name)
							}

							text_pad := (em / 2)
							text_width := int(math.floor((disp_w - (text_pad * 2)) / ch_width))
							max_chars := max(0, min(len(display_name), text_width))
							name_str := display_name[:max_chars]
							str_x := max(dr.x, full_flamegraph_rect.x) + text_pad

							if len(name_str) > 4 || max_chars == len(display_name) {
								if max_chars != len(display_name) {
									name_str = fmt.tprintf("%s…", name_str[:len(name_str)-1])
								}

								draw_text(name_str, Vec2{str_x, dr.y + (ui_state.rect_height / 2) - (em / 2)}, .PSize, .MonoFont, text_color3)
							}

							if pt_in_rect(mouse_pos, inner_flamegraph_rect) && pt_in_rect(mouse_pos, dr) {
								set_cursor("pointer")
								if !rendered_rect_tooltip && !shift_down {
									rect_tooltip_pos = Vec2{dr.x, dr.y}
									rect_tooltip_rect = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
									rendered_rect_tooltip = true
								}

								if clicked && !shift_down {
									pressed_event = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
								}
								if mouse_up_now && !shift_down {
									released_event = {i64(p_idx), i64(t_idx), i64(d_idx), i64(e_idx)}
								}
							}
						}
						continue
					}

					for i := child_count; i > 0; i -= 1 {
						next_idx := get_left_child(tree_idx) + i - 1
						tree_stack[stack_len] = next_idx; stack_len += 1
					}
				}

				gl_push_rects(gl_rects[:], (cur_y + (ui_state.rect_height * f64(d_idx))), ui_state.rect_height)
				resize(&gl_rects, 0)
			}
			cur_y += thread_advance
		}
	}

	// relative time back-cover
	draw_rect(Rect{ui_state.side_pad, full_flamegraph_rect.y, full_flamegraph_rect.w, flamegraph_toptext_height}, bg_color)

	// draw timestamps for subdivision lines
	time_high_y := full_flamegraph_rect.y + em
	time_tick_y := time_high_y + em

	div_clump_idx, fract_val, period := get_div_clump_idx(division_ns)
	text_side_pad := em
	old_tick_val: f64 = 0
	early_str, _, _ := clump_time(display_range_start_ns, div_clump_idx)
	_, _, early_tick := clump_time(f_round_down(draw_tick_start_ns, division_ns), div_clump_idx)
	old_tick_val = early_tick

	for i := -1; i < ticks; i += 1 {
		tick_time_ns := draw_tick_start_ns + (f64(i) * division_ns)
		scaled_tick_time := tick_time_ns / trace.stamp_scale
		x_off := (scaled_tick_time * cam.current_scale) + cam.pan.x

		start_str, tick_str, new_tick_val := clump_time(tick_time_ns, div_clump_idx)

		draw_top := false
		if new_tick_val != old_tick_val || fract_val > (period / 2) {
			draw_top = true
		}

		old_tick_val = new_tick_val
		top_text_width := measure_text(start_str, .PSize, .DefaultFont)
		tick_text_width := measure_text(tick_str, .PSize, .DefaultFont)

		if draw_top {
			top_x := ui_state.side_pad + x_off - ((top_text_width + text_side_pad) / 2)
			draw_rect(Rect{top_x, full_flamegraph_rect.y, top_text_width + text_side_pad, em + (text_side_pad / 2)}, tabbar_color)
			draw_text(start_str, Vec2{top_x + (text_side_pad / 2), time_high_y - (text_side_pad / 2)}, .PSize, .DefaultFont, text_color)
		}
		draw_text(tick_str, Vec2{ui_state.side_pad + x_off - (tick_text_width / 2), time_tick_y}, .PSize, .DefaultFont, text_color)
	}

	{
		if len(early_str) > 0 {
			top_text_width := measure_text(early_str, .PSize, .DefaultFont)
			draw_rect(Rect{ui_state.side_pad, full_flamegraph_rect.y, top_text_width + text_side_pad, em + (text_side_pad / 2)}, toolbar_color)
			draw_text(early_str, Vec2{ui_state.side_pad + (text_side_pad / 2), time_high_y - (text_side_pad / 2)}, .PSize, .DefaultFont, toolbar_text_color)
			draw_line(Vec2{ui_state.side_pad, full_flamegraph_rect.y}, Vec2{ui_state.side_pad, full_flamegraph_rect.y + flamegraph_toptext_height}, 5, toolbar_color)
		}
	}
}

draw_global_activity :: proc(trace: ^Trace, highlight_start_x, highlight_end_x: f64, ui_state: ^UIState) {
	global_activity_rect := ui_state.global_activity_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	minimap_rect := ui_state.minimap_rect

	trace_duration := trace.total_max_time - trace.total_min_time
	wide_scale_x := rescale(1.0, 0, f64(trace_duration), 0, full_flamegraph_rect.w)
	layer_count := 1
	for proc_v, _ in trace.processes {
		layer_count += len(proc_v.threads)
	}

	append(&gl_rects, DrawRect{f32(global_activity_rect.x), f32(global_activity_rect.w), BVec4{u8(wide_bg_color.x), u8(wide_bg_color.y), u8(wide_bg_color.z), u8(wide_bg_color.w)}})
	gl_push_rects(gl_rects[:], global_activity_rect.y, global_activity_rect.h)
	resize(&gl_rects, 0)

	for proc_v, p_idx in &trace.processes {
		for tm, t_idx in &proc_v.threads {
			if len(tm.depths) == 0 {
				continue
			}

			thread := &trace.processes[p_idx].threads[t_idx]
			depth := &thread.depths[0]
			tree := depth.tree

			// If we blow this, we're in space
			tree_stack := [128]int{}
			stack_len := 0

			alpha := u8(255.0 / f64(layer_count))
			tree_stack[0] = 0; stack_len += 1
			for stack_len > 0 {
				stack_len -= 1

				tree_idx := tree_stack[stack_len]
				cur_node := &tree[tree_idx]
				time_range := f64(cur_node.end_time - cur_node.start_time)
				range_width := time_range * wide_scale_x

				// draw summary faketangle
				min_width := 2.0 
				if (range_width / math.sqrt_f64(CHUNK_NARY_WIDTH)) < min_width {
					x := f64(cur_node.start_time)
					w := min_width * math.sqrt_f64(CHUNK_NARY_WIDTH)
					xm := x * wide_scale_x

					r_x   := x * wide_scale_x
					end_x := r_x + w

					r_x   += ui_state.side_pad
					end_x += ui_state.side_pad

					r_x    = max(r_x, 0)
					r_w   := end_x - r_x

					append(&gl_rects,
						DrawRect{f32(r_x), f32(r_w), BVec4{u8(wide_rect_color.x), u8(wide_rect_color.y), u8(wide_rect_color.z), alpha}})
					continue
				}

				// we're at a bottom node, draw the whole thing
				child_count := get_child_count(depth, tree_idx)
				if child_count <= 0 {
					event_count := get_event_count(depth, tree_idx)
					event_start_idx := get_event_start_idx(depth, tree_idx)
					scan_arr := depth.events[event_start_idx:event_start_idx+event_count]
					for ev, de_id in &scan_arr {
						x := f64(ev.timestamp - trace.total_min_time)
						duration := f64(bound_duration(&ev, thread.max_time))
						w := max(duration * wide_scale_x, 2.0)
						xm := x * wide_scale_x

						// Carefully extract the [start, end] interval of the rect so that we can clip the left
						// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
						// problems drawing a rectangle which starts at a massively huge negative number on
						// the left.
						r_x   := x * wide_scale_x
						end_x := r_x + w

						r_x   += ui_state.side_pad
						end_x += ui_state.side_pad

						r_x    = max(r_x, 0)
						r_w   := end_x - r_x

						append(&gl_rects,
							DrawRect{f32(r_x), f32(r_w), BVec4{u8(wide_rect_color.x), u8(wide_rect_color.y), u8(wide_rect_color.z), alpha}})
					}
					continue
				}

				for i := child_count; i > 0; i -= 1 {
					tree_stack[stack_len] = get_left_child(tree_idx) + i - 1; stack_len += 1
				}
			}

			gl_push_rects(gl_rects[:], global_activity_rect.y, global_activity_rect.h)
			resize(&gl_rects, 0)
		}
	}

	highlight_box_l := Rect{ui_state.side_pad, global_activity_rect.y, highlight_start_x, global_activity_rect.h}
	draw_rect(highlight_box_l, BVec4{0, 0, 0, 150})

	highlight_box_r := Rect{ui_state.side_pad + highlight_end_x, global_activity_rect.y, full_flamegraph_rect.w - highlight_end_x, global_activity_rect.h}
	draw_rect(highlight_box_r, BVec4{0, 0, 0, 150})

	draw_rect(Rect{0, global_activity_rect.y, ui_state.side_pad, global_activity_rect.h}, BVec4{0, 0, 0, 255})
	draw_rect(Rect{ui_state.width - minimap_rect.w, global_activity_rect.y, minimap_rect.w, global_activity_rect.h}, BVec4{0, 0, 0, 255})
}

draw_minimap :: proc(trace: ^Trace, ui_state: ^UIState) {
	minimap_rect              := ui_state.minimap_rect
	full_flamegraph_rect      := ui_state.full_flamegraph_rect
	info_pane_rect            := ui_state.info_pane_rect
	padded_flamegraph_rect    := ui_state.padded_flamegraph_rect
	flamegraph_toptext_height := ui_state.flamegraph_toptext_height
	minimap_pad := em

	// draw back-covers
	append(&gl_rects, DrawRect{f32(minimap_rect.x), f32(minimap_rect.w), bg_color})
	gl_push_rects(gl_rects[:], minimap_rect.y, minimap_rect.h)
	resize(&gl_rects, 0)

	mini_rect_height := (em / 2)
	trace_duration := trace.total_max_time - trace.total_min_time
	x_scale := rescale(1.0, 0, f64(trace_duration), 0, minimap_rect.w)
	y_scale := mini_rect_height / ui_state.rect_height

	tree_y : f64 = padded_flamegraph_rect.y - (cam.pan.y * y_scale)
	proc_loop: for proc_v, p_idx in &trace.processes {
		thread_loop: for thread, t_idx in &proc_v.threads {

			mini_thread_gap := 8.0
			thread_advance := ((f64(len(thread.depths)) * mini_rect_height) + mini_thread_gap)
			if tree_y > info_pane_rect.y {
				break proc_loop
			}
			if tree_y + thread_advance < 0 {
				tree_y += thread_advance
				continue
			}

			for depth, d_idx in &thread.depths {
				found_rid := -1
				range_loop: for range, r_idx in trace.selected_ranges {
					if range.pid == i32(p_idx) && range.tid == i32(t_idx) && range.did == i32(d_idx) {
						found_rid = r_idx
						break
					}
				}

				y := tree_y + (mini_rect_height * f64(d_idx))

				// If we blow this, we're in space
				tree_stack := [128]int{}
				stack_len := 0

				//fmt.printf("Apple: %v\n", rawptr(&depth.tree[0]))
				//fmt.printf("Pear: %v\n", depth.tree[0])

				tree := &depth.tree
				tree_stack[0] = 0; stack_len += 1
				for stack_len > 0 {
					stack_len -= 1

					tree_idx := tree_stack[stack_len]
					cur_node := &tree[tree_idx]
					time_range := f64(cur_node.end_time - cur_node.start_time)
					range_width := time_range * x_scale

					// draw summary faketangle
					min_width := 2.0 
					if (range_width / math.sqrt_f64(CHUNK_NARY_WIDTH)) < min_width {
						x := f64(cur_node.start_time)
						w := min_width * math.sqrt_f64(CHUNK_NARY_WIDTH)
						xm := x * x_scale

						r_x   := x * x_scale
						end_x := r_x + w

						r_x   += minimap_rect.x + minimap_pad
						end_x += minimap_rect.x + minimap_pad

						r_x    = max(r_x, 0)
						r_w   := end_x - r_x

						rect_color := cur_node.avg_color
						grey := greyscale(cur_node.avg_color)
						if ui_state.multiselecting {
							if found_rid != -1 {
								range := trace.selected_ranges[found_rid]   
								ev_start, ev_end := get_event_range(&depth, tree_idx)
								if !range_in_range(ev_start, ev_end, int(range.start), int(range.end)) {
									rect_color = grey
								}
							} else {
								rect_color = grey
							}
						}

						append(&gl_rects, DrawRect{f32(r_x), f32(r_w), BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}})
						continue
					}

					// we're at a bottom node, draw the whole thing
					child_count := get_child_count(&depth, tree_idx)
					if child_count <= 0 {
						event_start_idx, event_end_idx := get_event_range(&depth, tree_idx)
						foo := math.sqrt_f64(5)
						scan_arr := depth.events[event_start_idx:event_end_idx]
						for ev, de_id in &scan_arr {
							x := f64(ev.timestamp - trace.total_min_time)
							duration := f64(bound_duration(&ev, thread.max_time))
							w := max(duration * x_scale, 2.0)
							xm := x * x_scale

							// Carefully extract the [start, end] interval of the rect so that we can clip the left
							// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
							// problems drawing a rectangle which starts at a massively huge negative number on
							// the left.
							r_x   := x * x_scale
							end_x := r_x + w

							r_x   += minimap_rect.x + minimap_pad
							end_x += minimap_rect.x + minimap_pad

							r_x    = max(r_x, 0)
							r_w   := end_x - r_x

							idx := name_color_idx(ev.name)
							e_idx := event_start_idx + de_id

							rect_color := trace.color_choices[idx]
							grey := greyscale(trace.color_choices[idx])
							if ui_state.multiselecting {
								if found_rid != -1 {
									range := trace.selected_ranges[found_rid]   
									if !val_in_range(i32(e_idx), range.start, range.end - 1) { 
										rect_color = grey
									}
								} else {
									rect_color = grey
								}
							}

							append(&gl_rects, DrawRect{f32(r_x), f32(r_w), BVec4{u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}})
						}
						continue
					}

					for i := child_count; i > 0; i -= 1 {
						tree_stack[stack_len] = get_left_child(tree_idx) + i - 1; stack_len += 1
					}
				}

				gl_push_rects(gl_rects[:], y, mini_rect_height)
				resize(&gl_rects, 0)
			}

			tree_y += thread_advance
		}
	}

	preview_height := full_flamegraph_rect.h * y_scale

	// alpha overlays
	draw_rect(Rect{minimap_rect.x, full_flamegraph_rect.y, minimap_rect.w, preview_height}, highlight_color)
	draw_rect(Rect{minimap_rect.x, full_flamegraph_rect.y + preview_height, minimap_rect.w, full_flamegraph_rect.h - preview_height}, shadow_color)

	// top-right cover-chunk
	draw_rect(Rect{minimap_rect.x, full_flamegraph_rect.y, minimap_rect.w + (minimap_pad * 2), flamegraph_toptext_height}, bg_color)
}

draw_topbars :: proc(trace: ^Trace, start_time, end_time: i64, ui_state: ^UIState) {
	header_rect               := ui_state.header_rect
	global_activity_rect      := ui_state.global_activity_rect
	global_timebar_rect       := ui_state.global_timebar_rect
	minimap_rect              := ui_state.minimap_rect
	full_flamegraph_rect      := ui_state.full_flamegraph_rect
	flamegraph_toptext_height := ui_state.flamegraph_toptext_height

	//graph_header_text_height := (top_line_gap * 2) + em

	_start_time := disp_time(trace, f64(start_time))
	_end_time   := disp_time(trace, f64(end_time))
	trace_duration := disp_time(trace, f64(trace.total_max_time - trace.total_min_time))

	// draw back-covers
	draw_rect(Rect{0, header_rect.h, ui_state.width, global_timebar_rect.h}, bg_color) // top
	draw_rect(Rect{0, header_rect.h, ui_state.side_pad, ui_state.height}, bg_color) // left

	draw_line(Vec2{ui_state.side_pad, full_flamegraph_rect.y + flamegraph_toptext_height}, 
	Vec2{ui_state.width - minimap_rect.w, full_flamegraph_rect.y + flamegraph_toptext_height}, 1, line_color)

	highlight_start_x := rescale(_start_time, 0, trace_duration, 0, full_flamegraph_rect.w)
	highlight_end_x   := rescale(_end_time, 0, trace_duration, 0, full_flamegraph_rect.w)
	highlight_width   := highlight_end_x - highlight_start_x
	min_highlight     := 5.0
	if highlight_width < min_highlight {
		high_center := (highlight_start_x + highlight_end_x) / 2
		highlight_start_x = high_center - (min_highlight / 2)
		highlight_end_x = high_center + (min_highlight / 2)
	}
	draw_global_activity(trace, highlight_start_x, highlight_end_x, ui_state)

	// global timebar
	{
		start_time : i64 = 0
		end_time   := trace_duration
		default_scale := rescale(1.0, f64(start_time), f64(end_time), 0, full_flamegraph_rect.w)

		mus_range := full_flamegraph_rect.w / default_scale
		v1 := math.log10(mus_range)
		v2 := math.floor(v1)
		rem := v1 - v2

		subdivisions := 10
		division := math.pow(10, v2); // multiples of 10
		if rem < 0.3      { division -= (division * 0.8); } // multiples of 2
		else if rem < 0.6 { division -= (division / 2); } // multiples of 5

		display_range_start := -ui_state.width / default_scale
		display_range_end := ui_state.width / default_scale

		draw_tick_start := f_round_down(display_range_start, division)
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
				text_width := measure_text(time_str, .PSize, .DefaultFont)

				draw_text(time_str, 
				Vec2{
					ui_state.side_pad + x_off - (text_width / 2),
					header_rect.h + (global_timebar_rect.h / 2) - (em / 2),
				}, .PSize, .DefaultFont, text_color)
				line_start_y = header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height
			} else {
				line_start_y = header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height + (p_height / 6)
			}

			draw_line(
			Vec2{ui_state.side_pad + x_off, line_start_y}, 
			Vec2{ui_state.side_pad + x_off, header_rect.h + global_timebar_rect.h - 2}, 2, division_color)
		}

		draw_line( 
			Vec2{ui_state.side_pad + highlight_start_x, header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height},
			Vec2{ui_state.side_pad + highlight_start_x, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 2, xbar_color)
		draw_line( 
			Vec2{ui_state.side_pad + highlight_end_x, header_rect.h + (global_timebar_rect.h / 2) - (em / 2) + p_height}, 
			Vec2{ui_state.side_pad + highlight_end_x, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 2, xbar_color)
		draw_line( 
			Vec2{0, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 
			Vec2{ui_state.width, header_rect.h + global_timebar_rect.h + global_activity_rect.h}, 1, line_color)
	}
}

INITIAL_ITER :: 500_000
FULL_ITER    :: 2_000_000
draw_stats :: proc(trace: ^Trace, ui_state: ^UIState) {
	full_flamegraph_rect  := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect

	info_pane_rect        := ui_state.info_pane_rect
	tab_rect              := ui_state.tab_rect
	stats_pane_rect       := ui_state.stats_pane_rect
	filter_pane_rect      := ui_state.filter_pane_rect

	// Render info pane back-covers
	draw_line(Vec2{0, info_pane_rect.y}, Vec2{ui_state.width, info_pane_rect.y}, 1, line_color)
	draw_rect(info_pane_rect, bg_color) // bottom


	pane_start_y := tab_rect.y + tab_rect.h
	draw_rect(tab_rect, tabbar_color)
	draw_line(Vec2{0, pane_start_y}, Vec2{ui_state.width, pane_start_y}, 1, line_color)

	// draw pane grip
	handle_text := "\uf00a"
	handle_y := info_pane_rect.y + ((tab_rect.h / 2) - (h2_height / 2))
	handle_width := measure_text(handle_text, .H2Size, .IconFont)

	handle_pad := (em / 2)
	tab_bar_x := (2 * handle_pad) + handle_width
	tab_handle_rect := Rect{0, info_pane_rect.y, tab_bar_x, tab_rect.h}
	draw_rect(tab_handle_rect, grip_color)
	draw_text(handle_text, Vec2{handle_pad, handle_y}, .H2Size, .IconFont, toolbar_text_color)

	if pt_in_rect(mouse_pos, tab_handle_rect) || ui_state.resizing_pane {
		set_cursor("pointer")
	}

	if clicked && pt_in_rect(clicked_pos, tab_handle_rect) {
		ui_state.resizing_pane = true
	}
	if is_mouse_down && ui_state.resizing_pane {
		pos_y := max((ui_state.header_rect.y + ui_state.header_rect.h), mouse_pos.y)
		ui_state.info_pane_height = max(ui_state.height - pos_y, tab_rect.h)
	}
	if mouse_up_now && ui_state.resizing_pane {
		ui_state.resizing_pane = false
	}

	tab_bar_x += handle_pad
	filter_text := ui_state.filters_open ? "\uf150" : "\uf152"
	filter_width := measure_text(filter_text, .H2Size, .IconFont)
	draw_text(filter_text, Vec2{tab_bar_x, handle_y}, .H2Size, .IconFont, toolbar_text_color)
	tab_filter_rect := Rect{tab_bar_x, handle_y, filter_width, h2_height}
	if pt_in_rect(mouse_pos, tab_filter_rect) {
		set_cursor("pointer")
	}
	if clicked && pt_in_rect(clicked_pos, tab_filter_rect) {
		ui_state.filters_open = !ui_state.filters_open
		ui_state.render_one_more = true
	}

	// hotpatch position after the update, so we don't have a frame with stale position state
	if ui_state.filters_open {
		stats_pane_rect.x = filter_pane_rect.x + filter_pane_rect.w
	} else {
		stats_pane_rect.x = info_pane_rect.x
	}

	if ui_state.filters_open {
		draw_rect(ui_state.filter_pane_rect, tabbar_color)
		if pt_in_rect(mouse_pos, ui_state.filter_pane_rect) {
			reset_cursor()
			is_hovering = false
			rendered_rect_tooltip = false
		}

		y_offset := ui_state.filter_pane_rect.y + (em / 2)

		max_lines := len(trace.processes)
		for proc_v, _ in trace.processes {
			max_lines += len(proc_v.threads)
		}

		line_height : f64 = 0
		next_line(&line_height, em)
		displayed_lines := int(filter_pane_rect.h / line_height)

		max_scroll := f64(max_lines - displayed_lines) * line_height
		ui_state.filter_pane_scroll_pos = max(ui_state.filter_pane_scroll_pos, -max_scroll)
		y_offset += ui_state.filter_pane_scroll_pos
		x_offset := (em / 2)

		thread_pad := (em / 2)

		checked_checkbox_text := "\uf14a"
		unchecked_checkbox_text := "\uf096"
		checkbox_width := measure_text(checked_checkbox_text, .PSize, .IconFont)

		checkbox_gap := (em / 2)
		filter_width := measure_text(filter_text, .H2Size, .IconFont)
		for proc_v, _ in &trace.processes {
			checkbox_text := proc_v.in_stats ? checked_checkbox_text : unchecked_checkbox_text

			y := next_line(&y_offset, em)

			if y > filter_pane_rect.y {
				checkbox_rect := Rect{x_offset, y, em, em}

				if pt_in_rect(mouse_pos, checkbox_rect) {
					set_cursor("pointer")
				}
				if clicked && pt_in_rect(clicked_pos, checkbox_rect) {
					proc_v.in_stats = !proc_v.in_stats
					for thread, _ in &proc_v.threads {
						thread.in_stats = proc_v.in_stats
					}
					build_selected_ranges(trace, ui_state)
				}

				draw_text(checkbox_text, Vec2{checkbox_rect.x, checkbox_rect.y}, .PSize, .IconFont, toolbar_text_color)
				draw_text(get_proc_name(trace, &proc_v), Vec2{x_offset + checkbox_width + checkbox_gap, y - (em / 4)}, .PSize, .DefaultFont, toolbar_text_color)
			}


			for thread, _ in &proc_v.threads {
				checkbox_text := thread.in_stats ? checked_checkbox_text : unchecked_checkbox_text

				y := next_line(&y_offset, em)
				if y < filter_pane_rect.y {
					continue
				}
				if y >= ui_state.height {
					break
				}

				checkbox_rect := Rect{x_offset + thread_pad, y, em, em}
				draw_text(checkbox_text, Vec2{checkbox_rect.x, checkbox_rect.y}, .PSize, .IconFont, toolbar_text_color)
				draw_text(get_thread_name(trace, &thread), Vec2{x_offset + thread_pad + checkbox_width + checkbox_gap, y - (em / 4)}, .PSize, .DefaultFont, toolbar_text_color)

				if pt_in_rect(mouse_pos, checkbox_rect) {
					set_cursor("pointer")
				}
				if clicked && pt_in_rect(clicked_pos, checkbox_rect) {
					thread.in_stats = !thread.in_stats
					build_selected_ranges(trace, ui_state)
				}
			}

			if y >= ui_state.height {
				break
			}
		}
	}

	x_subpad := em
	stats_pane_x := x_subpad + stats_pane_rect.x
	pane_gapped_start_y := stats_pane_rect.y + ui_state.top_line_gap

	// If the user selected a single rectangle
	if selected_event.pid != -1 && selected_event.tid != -1 && selected_event.did != -1 && selected_event.eid != -1 {
		y := pane_gapped_start_y

		p_idx := int(selected_event.pid)
		t_idx := int(selected_event.tid)
		d_idx := int(selected_event.did)
		e_idx := int(selected_event.eid)

		thread := trace.processes[p_idx].threads[t_idx]
		event := thread.depths[d_idx].events[e_idx]
		draw_text(in_getstr(&trace.string_block, event.name), Vec2{stats_pane_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)

		if event.args > 0 {
			args_str := in_getstr(&trace.string_block, event.args)
			draw_text(fmt.tprintf(" user data: %s", args_str), Vec2{stats_pane_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
		}
		draw_text(fmt.tprintf("start time: %s", time_fmt(disp_time(trace, f64(event.timestamp - trace.total_min_time)))), Vec2{stats_pane_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
		draw_text(fmt.tprintf("  duration: %s", time_fmt(disp_time(trace, f64(bound_duration(&event, thread.max_time))))), Vec2{stats_pane_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)
		draw_text(fmt.tprintf(" self time: %s", time_fmt(disp_time(trace, f64(event.self_time)))), Vec2{stats_pane_x, next_line(&y, em)}, .PSize, .MonoFont, text_color)

		// If we've got stats cooking already
	} else if stats_state == .Pass1 || stats_state == .Pass2 {
		y := pane_gapped_start_y
		center_x := ui_state.width / 2

		total_count := 0
		cur_count := 0
		for range, r_idx in trace.selected_ranges {
			thread := trace.processes[range.pid].threads[range.tid]
			events := thread.depths[range.did].events

			total_count += len(events)
			if cur_stat_offset.range_idx > i32(r_idx) {
				cur_count += len(events)
			} else if cur_stat_offset.range_idx == i32(r_idx) {
				cur_count += int(cur_stat_offset.event_idx - range.start)
			}
		}

		loading_str := "Stats loading..."
		progress_str := fmt.tprintf("%d of %d", cur_count, total_count)
		hint_str := "Release multi-select to get the rest of the stats"

		strs := []string{ loading_str, progress_str }
		if stats_just_started && total_count >= INITIAL_ITER {
			strs = []string{ loading_str, progress_str, hint_str }
		}

		max_height := 0.0
		for str in strs {
			next_line(&max_height, em)
		}

		cur_y := y + ((ui_state.height - y) / 2) - (max_height / 2)
		for str in strs {
			str_width := measure_text(str, .PSize, .DefaultFont)
			draw_text(str, Vec2{center_x - (str_width / 2), next_line(&cur_y, em)}, .PSize, .DefaultFont, text_color)
		}

		// If stats are ready to display
	} else if stats_state == .Finished && ui_state.multiselecting {
		y := pane_gapped_start_y

		header_start := y
		header_height := 2 * em

		column_gap := 1.5 * em

		stats_pane_start := stats_pane_x - x_subpad
		cursor := stats_pane_x

		text_outf :: proc(cursor: ^f64, y: f64, str: string, color := text_color) {
			width := measure_text(str, .PSize, .MonoFont)
			draw_text(str, Vec2{cursor^, y}, .PSize, .MonoFont, color)
			cursor^ += width
		}

		full_time := f64(trace.total_max_time - trace.total_min_time)

		y += header_height + (em / 2)

		displayed_lines := int(ui_state.stats_pane_rect.h / ui_state.line_height) - 1
		if displayed_lines < len(trace.stats.entries) {
			max_lines := len(trace.stats.entries)

			// goofy hack to get line height
			tmp := y
			next_line(&tmp, em)
			line_height := tmp - y

			max_scroll := (f64(max_lines - displayed_lines) * line_height) + em
			ui_state.stats_pane_scroll_pos = max(ui_state.stats_pane_scroll_pos, -max_scroll)
			y += ui_state.stats_pane_scroll_pos
		}

		stat_idx := 0
		last_pos := 0.0
		stat_loop: for i := 0; i < len(trace.stats.entries); i += 1 {
			entry := trace.stats.entries[i]
			name := entry.key
			stat := entry.val

			stat_idx += 1
			if y < (pane_gapped_start_y + (em / 2)) {
				next_line(&y, em)
				continue stat_loop
			}

			if y > ui_state.height {
				break stat_loop
			}
			last_pos = y

			y_before   := y - (em / 2)
			y_after    := y_before
			next_line(&y_after, em)

			click_rect := Rect{stats_pane_start, y_before, ui_state.width, 2 * em}
			if pt_in_rect(mouse_pos, click_rect) {
				set_cursor("pointer")
			}

			if clicked && pt_in_rect(clicked_pos, click_rect) {
				if selected_func == name {
					selected_func = 0
				} else {
					selected_func = name
				}
			}

			if selected_func == name {
				draw_rect(click_rect, highlight_color)
			}

			cursor = stats_pane_x

			total_perc := (f64(stat.total_time) / f64(total_tracked_time)) * 100

			total_text := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.total_time))))
			total_perc_text := fmt.tprintf("%.1f%%", total_perc)

			self_text  := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.self_time))))
			min_text   := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.min_time))))
			avg_text   := fmt.tprintf("%10s", stat_fmt(disp_time(trace, stat.avg_time)))
			max_text   := fmt.tprintf("%10s", stat_fmt(disp_time(trace, f64(stat.max_time))))
			count_text := fmt.tprintf("%10s", fmt.tprintf("%d", stat.count))

			text_outf(&cursor, y, self_text, text_color2);   cursor += column_gap
			{
				full_perc_width := measure_text(total_perc_text, .PSize, .MonoFont)
				perc_width := (ch_width * 6) - full_perc_width

				text_outf(&cursor, y, total_text, text_color2); cursor += ch_width
				cursor += perc_width
				draw_text(total_perc_text, Vec2{cursor, y}, .PSize, .MonoFont, text_color2); cursor += column_gap + full_perc_width
			}

			text_outf(&cursor, y, min_text, text_color2);   cursor += column_gap
			text_outf(&cursor, y, avg_text, text_color2);   cursor += column_gap
			text_outf(&cursor, y, max_text, text_color2);   cursor += column_gap
			text_outf(&cursor, y, count_text, text_color2);   cursor += column_gap

			dr := Rect{cursor, y_before, (full_flamegraph_rect.w - cursor - column_gap) * f64(stat.total_time) / full_time, y_after - y_before}
			cursor += column_gap / 2

			name_str := in_getstr(&trace.string_block, name)
			name_width := measure_text(name_str, .PSize, .MonoFont)
			tmp_color := trace.color_choices[name_color_idx(name)]
			draw_rect(dr, BVec4{u8(tmp_color.x), u8(tmp_color.y), u8(tmp_color.z), 255})
			draw_text(name_str, Vec2{cursor, y_before + (em / 3)}, .PSize, .MonoFont, text_color)

			next_line(&y, em)
		}

		if selected_func > 0 {
			histogram_height := 18 * em
			line_gap := (em / 1.5)
			edge_gap := (em / 2)
			pos := Vec2{
				(inner_flamegraph_rect.x + inner_flamegraph_rect.w) - histogram_height - edge_gap,
				info_pane_rect.y - histogram_height - ((em + line_gap) * 2) - edge_gap,
			}

			name_str := in_getstr(&trace.string_block, selected_func)
			stat, ok := sm_get(&trace.stats, selected_func)
			if ok {
				draw_histogram(trace, name_str, stat, pos, histogram_height)
			}
		}

		y = header_start
		cursor = stats_pane_x - x_subpad

		table_header_height := 2 * em
		draw_rect(Rect{cursor, pane_start_y, ui_state.width, table_header_height + ui_state.top_line_gap}, subbar_color)
		draw_line(Vec2{cursor, pane_start_y}, Vec2{ui_state.width, pane_start_y}, 1, line_color)

		column_header :: proc(cursor: ^f64, column_gap, text_y, rect_y, pane_h: f64, text: string, sort_type: SortState) {
			start_x := cursor^
			cursor^ += (column_gap / 2)

			width := measure_text(text, .PSize, .MonoFont)
			draw_text(text, Vec2{cursor^, text_y}, .PSize, .MonoFont, text_color)
			cursor^ += width + (column_gap / 2)
			end_x := cursor^

			if stat_sort_type == sort_type {
				arrow_icon := stat_sort_descending ? "\uf0dd" : "\uf0de"
				arrow_height := get_text_height(.PSize, .IconFont)
				arrow_width := measure_text(arrow_icon, .PSize, .IconFont)
				draw_text(arrow_icon, Vec2{end_x - arrow_width - (column_gap / 2), rect_y + (em) - (arrow_height / 2)}, .PSize, .IconFont, text_color)
			}

			draw_line(Vec2{cursor^, rect_y}, Vec2{cursor^, rect_y + pane_h}, 1, subbar_split_color)

			click_rect := Rect{start_x, rect_y, end_x - start_x, 2 * em}
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
		column_header(&cursor, column_gap, y, pane_start_y, info_pane_rect.h, self_header_text, .SelfTime)

		total_header_text  := fmt.tprintf("%-17s", "      total")
		column_header(&cursor, column_gap, y, pane_start_y, info_pane_rect.h, total_header_text, .TotalTime)

		min_header_text    := fmt.tprintf("%-10s", "   min.")
		column_header(&cursor, column_gap, y, pane_start_y, info_pane_rect.h, min_header_text, .MinTime)

		avg_header_text    := fmt.tprintf("%-10s", "   avg.")
		column_header(&cursor, column_gap, y, pane_start_y, info_pane_rect.h, avg_header_text, .AvgTime)

		max_header_text    := fmt.tprintf("%-10s", "   max.")
		column_header(&cursor, column_gap, y, pane_start_y, info_pane_rect.h, max_header_text, .MaxTime)

		max_count_text    := fmt.tprintf("%-10s", "   count")
		column_header(&cursor, column_gap, y, pane_start_y, info_pane_rect.h, max_count_text, .Count)

		name_header_text   := fmt.tprintf("%-10s", "   name")
		text_outf(&cursor, y, name_header_text, text_color)
	} else if info_pane_rect.h > ((ui_state.line_height * 2) + (ui_state.top_line_gap * 2)) {
		y := (info_pane_rect.y + info_pane_rect.h) - (ui_state.top_line_gap * 3)

		draw_text("Shift-click and drag to get stats for multiple rectangles", Vec2{stats_pane_x, prev_line(&y, em)}, .PSize, .DefaultFont, text_color)
		draw_text("Click on a rectangle to inspect", Vec2{stats_pane_x, prev_line(&y, em)}, .PSize, .DefaultFont, text_color)
	}
}

process_multiselect :: proc(trace: ^Trace, pan_delta: Vec2, dt: f64, ui_state: ^UIState) {
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect
	padded_flamegraph_rect := ui_state.padded_flamegraph_rect
	info_pane_rect := ui_state.info_pane_rect

	// Handle single-select
	if mouse_up_now && !did_pan && pt_in_rect(clicked_pos, inner_flamegraph_rect) && pressed_event == released_event && !shift_down {
		selected_event = released_event
		clicked_on_rect = true
		ui_state.multiselecting = false
		ui_state.render_one_more = true
	}

	// Handle de-select
	if mouse_up_now && !did_pan && pt_in_rect(clicked_pos, inner_flamegraph_rect) && !clicked_on_rect && !shift_down {
		selected_event = {-1, -1, -1, -1}
		resize(&trace.selected_ranges, 0)

		multiselect_t = 0
		ui_state.multiselecting = false
		stats_state = .NoStats
		ui_state.render_one_more = true
	}

	// user wants to multi-select
	if is_mouse_down && shift_down {
		ui_state.multiselecting = true

		// cap multi-select box at graph edges
		delta := mouse_pos - clicked_pos
		c_x := min(clicked_pos.x, inner_flamegraph_rect.x + inner_flamegraph_rect.w)
		c_x = max(c_x, inner_flamegraph_rect.x)

		m_x := min(c_x + delta.x, inner_flamegraph_rect.x + inner_flamegraph_rect.w)
		m_x = max(m_x, inner_flamegraph_rect.x)

		d_x := m_x - c_x

		// draw multiselect box
		selected_rect := Rect{c_x, inner_flamegraph_rect.y, d_x, inner_flamegraph_rect.h}
		multiselect_color := toolbar_color
		{
			x1 := selected_rect.x + 1
			y1 := selected_rect.y + 1
			x2 := selected_rect.x + selected_rect.w - 1
			y2 := selected_rect.y + selected_rect.h - 1

			draw_line(Vec2{x1, y1}, Vec2{x1, y2}, 1, multiselect_color)
			draw_line(Vec2{x2, y1}, Vec2{x2, y2}, 1, multiselect_color)
		}

		multiselect_color.w = 20
		draw_rect(selected_rect, multiselect_color)

		// transform multiselect rect to screen position
		flopped_rect := Rect{}
		flopped_rect.x = min(selected_rect.x, selected_rect.x + selected_rect.w)
		x2 := max(selected_rect.x, selected_rect.x + selected_rect.w)
		flopped_rect.w = x2 - flopped_rect.x

		flopped_rect.y = selected_rect.y
		flopped_rect.h = selected_rect.h

		trace.stats_start_time = to_world_x(cam, flopped_rect.x - full_flamegraph_rect.x)
		trace.stats_end_time   = to_world_x(cam, flopped_rect.x - full_flamegraph_rect.x + flopped_rect.w)

		// draw multiselect timerange
		width_text := measure_fmt(disp_time(trace, trace.stats_end_time - trace.stats_start_time))
		width_text_width := measure_text(width_text, .PSize, .MonoFont) + em

		text_bg_rect  := flopped_rect
		text_bg_rect.x = text_bg_rect.x + (text_bg_rect.w / 2) - (width_text_width / 2)
		text_bg_rect.w = width_text_width
		text_bg_rect.y = flopped_rect.y
		text_bg_rect.h = (p_height * 2)

		text_bg_rect.x = max(text_bg_rect.x, inner_flamegraph_rect.x)

		multiselect_color.w = 180
		draw_rect(text_bg_rect, multiselect_color)
		draw_text(width_text, 
			Vec2{
				text_bg_rect.x + (em / 2), 
				text_bg_rect.y + (p_height / 2),
			}, 
			.PSize,
			.MonoFont,
			BVec4{255, 255, 255, 255},
		)

		// push it into screen-space
		flopped_rect.x -= full_flamegraph_rect.x

		build_selected_ranges(trace, ui_state)
	}
}

sort_stats :: proc(trace: ^Trace) {
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
		case .Count:
		less = proc(a, b: StatEntry) -> bool {
			if stat_sort_descending {
				return a.val.count > b.val.count
			} else {
				return a.val.count < b.val.count
			}
		}
	}
	sm_sort(&trace.stats, less)
}

process_inputs :: proc(trace: ^Trace, dt: f64, ui_state: ^UIState) -> (i64, i64, Vec2) {
	filter_pane_rect  := ui_state.filter_pane_rect
	stats_pane_rect   := ui_state.stats_pane_rect
	minimap_rect      := ui_state.minimap_rect
	full_flamegraph_rect := ui_state.full_flamegraph_rect
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect
	padded_flamegraph_rect := ui_state.padded_flamegraph_rect

	trace_duration := trace.total_max_time - trace.total_min_time

	start_time, end_time: i64
	pan_delta: Vec2

	if ui_state.resizing_pane {
		start_time, end_time := get_current_window(trace, cam, ui_state)
		return start_time, end_time, pan_delta
	}

	{
		old_scale := cam.target_scale

		max_scale := 10000000.0
		min_scale := 0.5 * full_flamegraph_rect.w / f64(trace_duration)
		if pt_in_rect(mouse_pos, inner_flamegraph_rect) {
			cam.target_scale *= math.pow(1.0025, -scroll_val_y)
			cam.target_scale  = min(max(cam.target_scale, min_scale), max_scale)
		} else if pt_in_rect(mouse_pos, filter_pane_rect) {
			ui_state.filter_pane_scroll_vel -= scroll_val_y * 10
		} else if pt_in_rect(mouse_pos, stats_pane_rect) {
			ui_state.stats_pane_scroll_vel -= scroll_val_y * 10
		} else if pt_in_rect(mouse_pos, minimap_rect) {
			cam.vel.y += scroll_val_y * 10
		}
		scroll_val_y = 0

		ui_state.stats_pane_scroll_pos += (ui_state.stats_pane_scroll_vel * dt)
		ui_state.stats_pane_scroll_vel *= math.pow(0.000001, dt)
		ui_state.stats_pane_scroll_pos = min(ui_state.stats_pane_scroll_pos, 0)

		ui_state.filter_pane_scroll_pos += (ui_state.filter_pane_scroll_vel * dt)
		ui_state.filter_pane_scroll_vel *= math.pow(0.000001, dt)
		ui_state.filter_pane_scroll_pos = min(ui_state.filter_pane_scroll_pos, 0)

		cam.current_scale += (cam.target_scale - cam.current_scale) * (1 - math.pow(math.pow_f64(0.1, 12), (dt)))
		cam.current_scale = min(max(cam.current_scale, min_scale), max_scale)

		last_start_time, last_end_time := get_current_window(trace, cam, ui_state)

		get_max_y_pan :: proc(processes: []Process, rect_height: f64) -> f64 {
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
		max_height := get_max_y_pan(trace.processes[:], ui_state.rect_height)
		max_y_pan := max(+20 * em + max_height - inner_flamegraph_rect.h, 0)
		min_y_pan := min(-20 * em, max_y_pan)
		max_x_pan := max(+20 * em, 0)
		min_x_pan := min(-20 * em + full_flamegraph_rect.w + -(f64(trace_duration)) * cam.target_scale, max_x_pan)

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
			if pt_in_rect(clicked_pos, padded_flamegraph_rect) {

				if cam.target_pan_x < min_x_pan {
					pan_delta.x *= math.pow_f64(2, (cam.target_pan_x - min_x_pan) / 32)
				}
				if cam.target_pan_x > max_x_pan {
					pan_delta.x *= math.pow(2, (max_x_pan - cam.target_pan_x) / 32)
				}
				if cam.pan.y < min_y_pan {
					pan_delta.y *= math.pow(2, (cam.pan.y - min_y_pan) / 32)
				}
				if cam.pan.y > max_y_pan {
					pan_delta.y *= math.pow(2, (max_y_pan - cam.pan.y) / 32)
				}

				cam.vel.y = -pan_delta.y / dt
				cam.vel.x = pan_delta.x / dt
			}
			last_mouse_pos = mouse_pos
		}

		cam_mouse_x := mouse_pos.x - ui_state.side_pad

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
		cam.vel *= math.pow(0.0001, dt)

		edge_sproing : f64 = 0.0001
		if cam.pan.y < min_y_pan && !is_mouse_down {
			cam.pan.y = min_y_pan + (cam.pan.y - min_y_pan) * math.pow(edge_sproing, dt)
			cam.vel.y *= math.pow(0.0001, dt)
		}
		if cam.pan.y > max_y_pan && !is_mouse_down {
			cam.pan.y = max_y_pan + (cam.pan.y - max_y_pan) * math.pow(edge_sproing, dt)
			cam.vel.y *= math.pow(0.0001, dt)
		}

		if cam.target_pan_x < min_x_pan && !is_mouse_down {
			cam.target_pan_x = min_x_pan + (cam.target_pan_x - min_x_pan) * math.pow(edge_sproing, dt)
			cam.vel.x *= math.pow(0.0001, dt)
		}
		if cam.target_pan_x > max_x_pan && !is_mouse_down {
			cam.target_pan_x = max_x_pan + (cam.target_pan_x - max_x_pan) * math.pow(edge_sproing, dt)
			cam.vel.x *= math.pow(0.0001, dt)
		}

		cam.pan.x = cam.target_pan_x + (cam.pan.x - cam.target_pan_x) * math.pow(math.pow_f64(0.1, 12.0), dt)
		start_time, end_time = get_current_window(trace, cam, ui_state)
	}

	return start_time, end_time, pan_delta
}

build_selected_ranges :: proc(trace: ^Trace, ui_state: ^UIState) {
	init_stat_state(trace, ui_state)

	// build out ranges
	for proc_v, p_idx in trace.processes {
		for thread, t_idx in proc_v.threads {
			if !thread.in_stats {
				continue
			}

			for depth, d_idx in thread.depths {
				start_idx := find_idx(trace, depth.events[:], i64(trace.stats_start_time))
				end_idx := find_idx(trace, depth.events[:], i64(trace.stats_end_time))
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

					start := f64(ev.timestamp - trace.total_min_time)
					width := f64(bound_duration(&ev, thread.max_time))
					if !range_in_range(start, start + width, trace.stats_start_time, trace.stats_end_time) {
						continue fwd_scan_loop
					}

					real_start = start_idx + i
					break fwd_scan_loop
				}

				real_end := -1
				rev_scan_loop: for i := len(scan_arr) - 1; i >= 0; i -= 1 {
					ev := scan_arr[i]

					start := f64(ev.timestamp - trace.total_min_time)
					width := f64(bound_duration(&ev, thread.max_time))
					if !range_in_range(start, start + width, trace.stats_start_time, trace.stats_end_time) {
						continue rev_scan_loop
					}

					real_end = start_idx + i + 1
					break rev_scan_loop
				}

				if real_start != -1 && real_end != -1 {
					append(&trace.selected_ranges, Range{i32(p_idx), i32(t_idx), i32(d_idx), i32(real_start), i32(real_end)})
				}
			}
		}
	}
}

init_stat_state :: proc(trace: ^Trace, ui_state: ^UIState) {
	stats_state = .Pass1
	total_tracked_time = 0
	cur_stat_offset = StatOffset{}
	selected_event = {-1, -1, -1, -1}

	ui_state.stats_pane_scroll_pos = 0
	ui_state.stats_pane_scroll_vel = 0

	stats_just_started = true

	sm_clear(&trace.stats)
	resize(&trace.selected_ranges, 0)
}

process_stats :: proc(trace: ^Trace, ui_state: ^UIState) {
	if stats_state == .Finished || stats_state == .NoStats {
		return
	}

	ui_state.render_one_more = true
	if (stats_state == .Pass1 || stats_state == .Pass2) {
		event_count := 0
		iter_max := stats_just_started ? INITIAL_ITER : FULL_ITER

		broke_early := false
		if stats_state == .Pass1 {
			pass1_range_loop: for range, r_idx in trace.selected_ranges {
				start_idx := range.start
				if cur_stat_offset.range_idx > i32(r_idx) {
					continue
				} else if cur_stat_offset.range_idx == i32(r_idx) {
					start_idx = max(start_idx, cur_stat_offset.event_idx)
				}

				thread := trace.processes[range.pid].threads[range.tid]
				events := thread.depths[range.did].events[start_idx:range.end]

				for ev, e_idx in &events {
					if event_count > iter_max {
						cur_stat_offset = StatOffset{i32(r_idx), start_idx + i32(e_idx)}
						broke_early = true
						break pass1_range_loop
					}

					duration := bound_duration(&ev, thread.max_time)
					name := in_getstr(&trace.string_block, ev.name)
					s, ok := sm_get(&trace.stats, ev.name)
					if !ok {
						s = sm_insert(&trace.stats, ev.name, Stats{min_time = max(i64), max_time = min(i64)})
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
				stats_state = .Pass2
				cur_stat_offset = StatOffset{}
			}
		}

		if stats_state == .Pass2 {
			pass2_range_loop: for range, r_idx in trace.selected_ranges {
				start_idx := range.start
				if cur_stat_offset.range_idx > i32(r_idx) {
					continue
				} else if cur_stat_offset.range_idx == i32(r_idx) {
					start_idx = max(start_idx, cur_stat_offset.event_idx)
				}

				thread := trace.processes[range.pid].threads[range.tid]
				events := thread.depths[range.did].events[start_idx:range.end]

				for ev, e_idx in &events {
					if event_count > iter_max {
						cur_stat_offset = StatOffset{i32(r_idx), start_idx + i32(e_idx)}
						broke_early = true
						break pass2_range_loop
					}

					duration := bound_duration(&ev, thread.max_time)
					s, _ := sm_get(&trace.stats, ev.name)

					idx: u32
					if (s.max_time - s.min_time <= 0) {
						idx = 50
					} else {
						t := f64(duration - s.min_time) / f64(s.max_time - s.min_time)
						t = min(1, max(t, 0))
						t *= 99
						idx = u32(t)
					}

					s.hist[idx] += 1
					event_count += 1
				}
			}

			if !broke_early {
				for i := 0; i < len(trace.stats.entries); i += 1 {
					stat := &trace.stats.entries[i].val
					stat.avg_time = f64(stat.total_time) / f64(stat.count)
				}

				self_sort :: proc(a, b: StatEntry) -> bool {
					return a.val.self_time > b.val.self_time
				}
				sm_sort(&trace.stats, self_sort)
				stats_state = .Finished
			}
		}
	}
}

draw_errorbox :: proc(trace: ^Trace, ui_state: ^UIState) {
	inner_flamegraph_rect := ui_state.inner_flamegraph_rect

	msg_width := measure_text(trace.error_message, .PSize, .DefaultFont)
	msg_height := em

	error_rect := inner_flamegraph_rect
	error_rect.w = min(msg_width  + (2 * em), inner_flamegraph_rect.w)
	error_rect.h = min(msg_height + (2 * em),  inner_flamegraph_rect.h)
	error_rect.x = (inner_flamegraph_rect.x + inner_flamegraph_rect.w) - error_rect.w

	draw_rect(error_rect, error_color)
	draw_text(trace.error_message, Vec2{(error_rect.x + (error_rect.w / 2)) - (msg_width / 2), (error_rect.y + (error_rect.h / 2)) - (msg_height / 2)}, .PSize, .DefaultFont, text_color)
}
