package main

import "core:fmt"
import "core:math"
import "core:container/queue"

tooltip :: proc(pos: Vec2, min_x, max_x: f64, text: string) {
	text_width := measure_text(text, p_font_size, default_font)
	text_height := get_text_height(p_font_size, default_font)

	tooltip_rect := rect(pos.x, pos.y - (em / 2), text_width + em, text_height + (1.25 * em))
	if tooltip_rect.pos.x + tooltip_rect.size.x > max_x {
		tooltip_rect.pos.x = max_x - tooltip_rect.size.x
	}
	if tooltip_rect.pos.x < min_x {
		tooltip_rect.pos.x = min_x
	}

	draw_rect(tooltip_rect, bg_color)
	draw_rect_outline(tooltip_rect, 1, line_color)
	draw_text(text, Vec2{tooltip_rect.pos.x + (em / 2), tooltip_rect.pos.y + (em / 2)}, p_font_size, default_font, text_color)
}

button :: proc(in_rect: Rect, label_text, tooltip_text, font: string, min_x, max_x: f64) -> bool {
	draw_rectc(in_rect, 3, toolbar_button_color)
	label_width := measure_text(label_text, p_font_size, font)
	label_height := get_text_height(p_font_size, font)
	draw_text(label_text, 
		Vec2{
			in_rect.pos.x + (in_rect.size.x / 2) - (label_width / 2), 
			in_rect.pos.y + (in_rect.size.y / 2) - (label_height / 2),
		}, p_font_size, font, toolbar_text_color)

	if pt_in_rect(mouse_pos, in_rect) {
		set_cursor("pointer")
		if clicked {
			return true
		} else {
			tip_pos := Vec2{in_rect.pos.x, in_rect.pos.y + in_rect.size.y + em}
			tooltip(tip_pos, min_x, max_x, tooltip_text)
		}
	}
	return false
}

draw_graph :: proc(header: string, history: ^queue.Queue(f64), pos: Vec2) {
	line_width : f64 = 1
	graph_edge_pad : f64 = 2 * em
	line_gap := (em / 1.5)

	max_val : f64 = 0
	min_val : f64 = 10000000
	sum_val : f64 = 0
	for i := 0; i < queue.len(history^); i += 1 {
		entry := queue.get(history, i)
		max_val = max(max_val, entry)
		min_val = min(min_val, entry)
		sum_val += entry
	}
	max_range := max_val - min_val
	avg_val := sum_val / 100

	text_width := measure_text(header, p_font_size, default_font)
	center_offset := (graph_size / 2) - (text_width / 2)
	draw_text(header, Vec2{pos.x + center_offset, pos.y}, p_font_size, default_font, text_color)

	graph_top := pos.y + em + line_gap
	draw_rect(rect(pos.x, graph_top, graph_size, graph_size), bg_color2)
	draw_rect_outline(rect(pos.x, graph_top, graph_size, graph_size), 2, outline_color)

	draw_line(Vec2{pos.x - 5, graph_top + graph_size - graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_size - graph_edge_pad}, 1, graph_color)
	draw_line(Vec2{pos.x - 5, graph_top + graph_edge_pad}, Vec2{pos.x + 5, graph_top + graph_edge_pad}, 1, graph_color)

	if queue.len(history^) > 1 {
		high_height := graph_top + graph_edge_pad - (em / 2)
		low_height := graph_top + graph_size - graph_edge_pad - (em / 2)
		avg_height := rescale(f64(avg_val), f64(min_val), f64(max_val), low_height, high_height)

		high_str := fmt.tprintf("%.0f", max_val)
		high_width := measure_text(high_str, p_font_size, default_font) + line_gap
		draw_text(high_str, Vec2{(pos.x - 5) - high_width, high_height}, p_font_size, default_font, text_color)

		if queue.len(history^) > 90 {
			draw_line(Vec2{pos.x - 5, avg_height + (em / 2)}, Vec2{pos.x + 5, avg_height + (em / 2)}, 1, graph_color)
			avg_str := fmt.tprintf("%.0f", avg_val)
			avg_width := measure_text(avg_str, p_font_size, default_font) + line_gap
			draw_text(avg_str, Vec2{(pos.x - 5) - avg_width, avg_height}, p_font_size, default_font, text_color)
		}

		low_str := fmt.tprintf("%.0f", min_val)
		low_width := measure_text(low_str, p_font_size, default_font) + line_gap
		draw_text(low_str, Vec2{(pos.x - 5) - low_width, low_height}, p_font_size, default_font, text_color)
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

to_world_x :: proc(cam: Camera, x: f64) -> f64 {
	return (x - cam.pan.x) / cam.current_scale
}
to_world_y :: proc(cam: Camera, y: f64) -> f64 {
	return y + cam.pan.y
}
to_world_pos :: proc(cam: Camera, pos: Vec2) -> Vec2 {
	return Vec2{to_world_x(cam, pos.x), to_world_y(cam, pos.y)}
}

get_current_window :: proc(cam: Camera, display_width: f64) -> (f64, f64) {
	display_range_start := to_world_x(cam, 0)
	display_range_end   := to_world_x(cam, display_width)
	return display_range_start, display_range_end
}

reset_camera :: proc(display_width: f64) {
	cam = Camera{Vec2{0, 0}, Vec2{0, 0}, 0, 1, 1}

	if event_count == 0 { total_min_time = 0; total_max_time = 1000 }

	start_time : f64 = 0
	end_time   := total_max_time - total_min_time

	side_pad := 2 * em

	cam.current_scale = rescale(cam.current_scale, start_time, end_time, 0, display_width - (side_pad * 2))
	cam.target_scale = cam.current_scale

	cam.pan.x += side_pad
	cam.target_pan_x = cam.pan.x
}

render_widetree :: proc(p_idx, t_idx: int, start_x: f64, scale: f64, layer_count: int) {
	thread := &processes[p_idx].threads[t_idx]
	depth := thread.depths[0]
	tree := depth.tree

	// If we blow this, we're in space
	tree_stack := [128]uint{}
	stack_len := 0

	alpha := u8(255.0 / f64(layer_count))
	tree_stack[0] = depth.head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		if tree_idx >= len(tree) {
			fmt.printf("%d, %d\n", p_idx, t_idx)
			fmt.printf("%d\n", depth.head)
			fmt.printf("%d\n", stack_len)
			fmt.printf("%v\n", tree_stack)
			fmt.printf("%v\n", tree)
			fmt.printf("hmm????\n")
			push_fatal(SpallError.Bug)
		}

		cur_node := tree[tree_idx]
		range := cur_node.end_time - cur_node.start_time
		range_width := range * scale

		// draw summary faketangle
		min_width := 2.0 
		if range_width < min_width {
			x := cur_node.start_time
			w := min_width
			xm := x * scale

			r_x   := x * scale
			end_x := r_x + w

			r_x   += start_x
			end_x += start_x

			r_x    = max(r_x, 0)
			r_w   := end_x - r_x

			draw_rect := DrawRect{f32(r_x), f32(r_w), {u8(wide_rect_color.x), u8(wide_rect_color.y), u8(wide_rect_color.z), alpha}}
			append(&gl_rects, draw_rect)
			continue
		}

		// we're at a bottom node, draw the whole thing
		if cur_node.child_count == 0 {
			scan_arr := depth.events[cur_node.start_idx:cur_node.start_idx+uint(cur_node.arr_len)]
			render_wideevents(scan_arr, thread.max_time, start_x, scale, alpha)
			continue
		}

		for i := cur_node.child_count - 1; i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}
}

render_wideevents :: proc(scan_arr: []Event, thread_max_time: f64, start_x: f64, scale: f64, alpha: u8) {
	for ev, de_id in scan_arr {
		x := ev.timestamp - total_min_time
		duration := bound_duration(ev, thread_max_time)
		w := max(duration * scale, 2.0)
		xm := x * scale

		// Carefully extract the [start, end] interval of the rect so that we can clip the left
		// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
		// problems drawing a rectangle which starts at a massively huge negative number on
		// the left.
		r_x   := x * scale
		end_x := r_x + w

		r_x   += start_x
		end_x += start_x

		r_x    = max(r_x, 0)
		r_w   := end_x - r_x

		draw_rect := DrawRect{f32(r_x), f32(r_w), {u8(wide_rect_color.x), u8(wide_rect_color.y), u8(wide_rect_color.z), alpha}}
		append(&gl_rects, draw_rect)
	}
}

render_minitree :: proc(pid, tid: int, depth_idx: int, start_x: f64, scale: f64) {
	thread := processes[pid].threads[tid]
	depth := thread.depths[depth_idx]
	tree := depth.tree

	if len(tree) == 0 {
		fmt.printf("depth_idx: %d, depth count: %d, %v\n", depth_idx, len(thread.depths), thread.depths)
		push_fatal(SpallError.Bug)
	}

	found_rid := -1
	range_loop: for range, r_idx in selected_ranges {
		if range.pid == pid && range.tid == tid && range.did == depth_idx {
			found_rid = r_idx
			break
		}
	}

	// If we blow this, we're in space
	tree_stack := [128]uint{}
	stack_len := 0

	tree_stack[0] = depth.head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := tree[tree_idx]
		range := cur_node.end_time - cur_node.start_time
		range_width := range * scale

		// draw summary faketangle
		min_width := 2.0 
		if range_width < min_width {
			x := cur_node.start_time
			w := min_width
			xm := x * scale

			r_x   := x * scale
			end_x := r_x + w

			r_x   += start_x
			end_x += start_x

			r_x    = max(r_x, 0)
			r_w   := end_x - r_x

			rect_color := cur_node.avg_color
			grey := greyscale(cur_node.avg_color)
			should_fade := false
			if did_multiselect {
				if found_rid == -1 { should_fade = true } 
				else {
					range := selected_ranges[found_rid]	
					if !range_in_range(cur_node.start_idx, cur_node.end_idx, 
									   uint(range.start), uint(range.end)) {
						should_fade = true
					}
				}
			}
			if should_fade {
				if multiselect_t != 0 && greyanim_t > 1 {
					anim_playing = false
					rect_color = grey
				} else {
					st := ease_in_out(greyanim_t)
					rect_color = math.lerp(rect_color, grey, greymotion)
				}
			}

			draw_rect := DrawRect{f32(r_x), f32(r_w), {u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}}
			append(&gl_rects, draw_rect)
			continue
		}

		// we're at a bottom node, draw the whole thing
		if cur_node.child_count == 0 {
			scan_arr := depth.events[cur_node.start_idx:cur_node.start_idx+uint(cur_node.arr_len)]
			render_minievents(scan_arr, thread.max_time, start_x, scale, int(cur_node.start_idx), found_rid)
			continue
		}

		for i := cur_node.child_count - 1; i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}
}

render_minievents :: proc(scan_arr: []Event, thread_max_time: f64, start_x: f64, scale: f64, start_idx, found_rid: int) {
	for ev, de_id in scan_arr {
		x := ev.timestamp - total_min_time
		duration := bound_duration(ev, thread_max_time)
		w := max(duration * scale, 2.0)
		xm := x * scale

		// Carefully extract the [start, end] interval of the rect so that we can clip the left
		// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
		// problems drawing a rectangle which starts at a massively huge negative number on
		// the left.
		r_x   := x * scale
		end_x := r_x + w

		r_x   += start_x
		end_x += start_x

		r_x    = max(r_x, 0)
		r_w   := end_x - r_x

		idx := name_color_idx(in_getstr(ev.name))
		rect_color := color_choices[idx]
		e_idx := int(start_idx) + de_id

		grey := greyscale(color_choices[idx])
		should_fade := false
		if did_multiselect {
			if found_rid == -1 { should_fade = true } 
			else {
				range := selected_ranges[found_rid]	
				if !val_in_range(e_idx, range.start, range.end - 1) { should_fade = true }
			}
		}

		if should_fade {
			if multiselect_t != 0 && greyanim_t > 1 {
				anim_playing = false
				rect_color = grey
			} else {
				st := ease_in_out(greyanim_t)
				rect_color = math.lerp(rect_color, grey, greymotion)
			}
		}

		draw_rect := DrawRect{f32(r_x), f32(r_w), {u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}}
		append(&gl_rects, draw_rect)
	}
}

render_tree :: proc(pid, tid, depth_idx: int, y_start: f64, start_time, end_time: f64) {
	thread := processes[pid].threads[tid]
	depth := thread.depths[depth_idx]
	tree := depth.tree

	found_rid := -1
	range_loop: for range, r_idx in selected_ranges {
		if range.pid == pid && range.tid == tid && range.did == depth_idx {
			found_rid = r_idx
			break
		}
	}

	// If we blow this, we're in space
	tree_stack := [128]uint{}
	stack_len := 0

	tree_stack[0] = depth.head; stack_len += 1
	for stack_len > 0 {
		stack_len -= 1

		tree_idx := tree_stack[stack_len]
		cur_node := tree[tree_idx]

		if cur_node.end_time < f64(start_time) || cur_node.start_time > f64(end_time) {
			continue
		}

		range := cur_node.end_time - cur_node.start_time
		range_width := range * cam.current_scale

		// draw summary faketangle
		min_width := 2.0
		if range_width < min_width {
			y := rect_height * f64(depth_idx)
			h := rect_height

			x := cur_node.start_time
			w := min_width
			xm := x * cam.target_scale

			r_x   := x * cam.current_scale
			end_x := r_x + w

			r_x   += cam.pan.x + disp_rect.pos.x
			end_x += cam.pan.x + disp_rect.pos.x

			r_x    = max(r_x, 0)

			r_y := y_start + y
			dr := Rect{Vec2{r_x, r_y}, Vec2{end_x - r_x, h}}

			rect_color := cur_node.avg_color

			grey := greyscale(cur_node.avg_color)
			should_fade := false
			if did_multiselect {
				if found_rid == -1 { should_fade = true } 
				else {
					range := selected_ranges[found_rid]	
					if !range_in_range(cur_node.start_idx, cur_node.end_idx, 
									   uint(range.start), uint(range.end)) {
						should_fade = true
					}
				}
			}
			if should_fade {
				if multiselect_t != 0 && greyanim_t > 1 {
					anim_playing = false
					rect_color = grey
				} else {
					st := ease_in_out(greyanim_t)
					rect_color = math.lerp(rect_color, grey, greymotion)
				}
			}

			draw_rect := DrawRect{f32(dr.pos.x), f32(dr.size.x), {u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}}
			append(&gl_rects, draw_rect)

			rect_count += 1
			bucket_count += 1
			continue
		}

		// we're at a bottom node, draw the whole thing
		if cur_node.child_count == 0 {
			render_events(pid, tid, depth_idx, depth.events, cur_node.start_idx, cur_node.arr_len, thread.max_time, depth_idx, y_start, found_rid)
			continue
		}

		for i := cur_node.child_count - 1; i >= 0; i -= 1 {
			tree_stack[stack_len] = cur_node.children[i]; stack_len += 1
		}
	}
}

render_events :: proc(p_idx, t_idx, d_idx: int, events: []Event, start_idx: uint, arr_len: i8, thread_max_time: f64, y_depth: int, y_start: f64, found_rid: int) {
	scan_arr := events[start_idx:start_idx+uint(arr_len)]
	y := rect_height * f64(y_depth)
	h := rect_height

	for ev, de_id in scan_arr {
		x := ev.timestamp - total_min_time
		duration := bound_duration(ev, thread_max_time)
		w := max(duration * cam.current_scale, 2.0)
		xm := x * cam.target_scale


		// Carefully extract the [start, end] interval of the rect so that we can clip the left
		// side to 0 before sending it to draw_rect, so we can prevent f32 (f64?) precision
		// problems drawing a rectangle which starts at a massively huge negative number on
		// the left.
		r_x   := x * cam.current_scale
		end_x := r_x + w

		r_x   += cam.pan.x + disp_rect.pos.x
		end_x += cam.pan.x + disp_rect.pos.x

		r_x    = max(r_x, 0)

		r_y := y_start + y
		dr := Rect{Vec2{r_x, r_y}, Vec2{end_x - r_x, h}}

		if !rect_in_rect(dr, graph_rect) {
			continue
		}

		ev_name := in_getstr(ev.name)
		idx := name_color_idx(ev_name)
		rect_color := color_choices[idx]
		e_idx := int(start_idx) + de_id

		grey := greyscale(color_choices[idx])

		should_fade := false
		if did_multiselect {
			if found_rid == -1 { should_fade = true } 
			else {
				range := selected_ranges[found_rid]	
				if !val_in_range(e_idx, range.start, range.end - 1) { should_fade = true }
			}
		}

		if should_fade {
			if multiselect_t != 0 && greyanim_t > 1 {
				anim_playing = false
				rect_color = grey
			} else {
				rect_color = math.lerp(rect_color, grey, greymotion)
			}
		}

		if int(selected_event.pid) == p_idx && int(selected_event.tid) == t_idx &&
		   int(selected_event.did) == d_idx && int(selected_event.eid) == e_idx {
			rect_color.x += 30
			rect_color.y += 30
			rect_color.z += 30
		}

		draw_rect := DrawRect{f32(dr.pos.x), f32(dr.size.x), {u8(rect_color.x), u8(rect_color.y), u8(rect_color.z), 255}}
		append(&gl_rects, draw_rect)
		rect_count += 1

		underhang := disp_rect.pos.x - dr.pos.x
		overhang := (disp_rect.pos.x + disp_rect.size.x) - dr.pos.x
		disp_w := min(dr.size.x - underhang, dr.size.x, overhang)

		display_name := ev_name
		if ev.duration == -1 {
			display_name = fmt.tprintf("%s (Did Not Finish)", ev_name)
		}
		text_pad := (em / 2)
		text_width := int(math.floor((disp_w - (text_pad * 2)) / ch_width))
		max_chars := max(0, min(len(display_name), text_width))
		name_str := display_name[:max_chars]
		str_x := max(dr.pos.x, disp_rect.pos.x) + text_pad

		if len(name_str) > 4 || max_chars == len(display_name) {
			if max_chars != len(display_name) {
				name_str = fmt.tprintf("%s…", name_str[:len(name_str)-1])
			}

			draw_text(name_str, Vec2{str_x, dr.pos.y + (rect_height / 2) - (em / 2)}, p_font_size, monospace_font, text_color3)
		}

		if pt_in_rect(mouse_pos, graph_rect) && pt_in_rect(mouse_pos, dr) {
			set_cursor("pointer")
			if !rendered_rect_tooltip && !shift_down {
				rect_tooltip_pos = dr.pos
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
}
