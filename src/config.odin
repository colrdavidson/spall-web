package main

import "core:encoding/json"
import "core:fmt"
import "core:strings"
import "core:sort"
import "core:slice"
import "core:container/queue"

load_config :: proc(config: string, events: ^[dynamic]Event) -> bool {
	blah, err := json.parse(transmute([]u8)config, json.DEFAULT_SPECIFICATION, true)
	if err != nil {
		fmt.printf("%s\n", err)
		return false
	}
	obj_map := blah.(json.Object) or_return

	events_arr := obj_map["traceEvents"].(json.Array) or_return
	for v in events_arr {
		ev := v.(json.Object) or_return

		name      := ev["name"].(string) or_return
		duration  := ev["dur"].(i64) or_return
		timestamp := ev["ts"].(i64) or_return
		tid       := ev["tid"].(i64) or_return

		append(events, Event{strings.clone(name), u64(duration), u64(timestamp), u64(tid), 0})
	}

	return true
}

process_events :: proc(events: []Event) -> ([]Timeline, u64, u64, int) {
	threads := make([dynamic]Timeline)
	thread_map := make(map[u64]int, 0, context.temp_allocator)
	event_map := make(map[u64][dynamic]Event, 0, context.temp_allocator)

	for event, idx in events {
		tm_idx, ok := thread_map[event.thread_id]
		if !ok {
			append(&threads, Timeline{
				min_time = 1000000, 
				max_time = 0, 
				min_duration = 1000000, 
				max_duration = 0, 
				total_duration = 0,
				thread_id = event.thread_id,
			})
			tm_idx = len(threads) - 1
			thread_map[event.thread_id] = tm_idx

			sub_events := make([dynamic]Event)
			event_map[event.thread_id] = sub_events
		}

		tm := &threads[tm_idx]
		tm.min_time = min(tm.min_time, event.timestamp)
		tm.max_time = max(tm.max_time, event.timestamp + event.duration)
		tm.min_duration = min(tm.min_duration, event.duration)
		tm.max_duration = max(tm.max_duration, event.duration)
		tm.total_duration += event.duration

		sub_events := &event_map[event.thread_id]
		append(sub_events, event)
	}

	total_min_time : u64 = 10000000
	total_max_time : u64 = 0
	for k, v in thread_map {
		tm := &threads[v]
		tm.events = event_map[k][:]

		event_sort_proc :: proc(a, b: Event) -> int {
			switch {
			case a.timestamp < b.timestamp: return -1
			case a.timestamp > b.timestamp: return +1
			}
			return 0
		}
		sort.quick_sort_proc(tm.events, event_sort_proc)

		total_max_time = max(total_max_time, tm.max_time)
		total_min_time = min(total_min_time, tm.min_time)
	}

	
	thread_sort_proc :: proc(a, b: Timeline) -> int {
		switch {
		case a.min_time < b.min_time: return -1
		case a.min_time > b.min_time: return +1
		}
		return 0
	}
	sort.quick_sort_proc(threads[:], thread_sort_proc)

	// generate depth mapping
	total_max_depth := 0
	for tm, t_idx in &threads {
		ev_stack: queue.Queue(int)
		queue.init(&ev_stack, 0, context.temp_allocator)

		for event, e_idx in &tm.events {
			cur_start := event.timestamp
			cur_end   := event.timestamp + event.duration
			if queue.len(ev_stack) == 0 {
				queue.push_back(&ev_stack, e_idx)
			} else {
				prev_e_idx := queue.get(&ev_stack, queue.len(ev_stack) - 1)
				prev_ev := tm.events[prev_e_idx]

				prev_start := prev_ev.timestamp
				prev_end   := prev_ev.timestamp + prev_ev.duration

				// if it fits within the parent
				if cur_start >= prev_start && cur_end <= prev_end {
					queue.push_back(&ev_stack, e_idx)
				} else {

					// while it doesn't overlap the parent
					for queue.len(ev_stack) > 0 {
						prev_e_idx = queue.get(&ev_stack, queue.len(ev_stack) - 1)
						prev_ev = tm.events[prev_e_idx]

						prev_start = prev_ev.timestamp
						prev_end   = prev_ev.timestamp + prev_ev.duration

						if cur_start >= prev_start && cur_end >= prev_end {
							queue.pop_back(&ev_stack)
						} else {
							break;
						}
					}
					queue.push_back(&ev_stack, e_idx)
				}
			}

			event.depth = queue.len(ev_stack)
			tm.max_depth = max(tm.max_depth, event.depth)
		}

		total_max_depth = max(total_max_depth, tm.max_depth)
	}

	return threads[:], total_max_time, total_min_time, total_max_depth
}
