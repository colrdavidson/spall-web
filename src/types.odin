package main

import "core:container/queue"
import "core:fmt"

Vec2 :: [2]f64
Vec3 :: [3]f64
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}

rect :: #force_inline proc(x, y, w, h: f64) -> Rect {
	return Rect{Vec2{x, y}, Vec2{w, h}}
}

Camera :: struct {
	pan: Vec2,
	vel: Vec2,
	target_pan_x: f64,

	current_scale: f64,
	target_scale: f64,
}

EventType :: enum u8 {
	Complete,
	Begin,
	End
}

TempEvent :: struct {
	type: EventType,
	name: string,
	duration: f64,
	timestamp: f64,
	thread_id: u32,
	process_id: u32,
}

Event :: struct #packed {
	type: EventType,
	name: string,
	duration: f64,
	timestamp: f64,
	depth: u16,
}

Thread :: struct {
	min_time: f64,
	max_depth: u16,

	thread_id: u32,
	events: [dynamic]Event,
	depths: [dynamic][]Event,
}

Process :: struct {
	min_time: f64,

	process_id: u32,
	threads: [dynamic]Thread,
	thread_map: map[u32]int,
}

print_queue :: proc(q: ^$Q/queue.Queue($T)) {
	if queue.len(q^) == 0 {
		fmt.printf("Queue{{}}\n")
		return
	}

	fmt.printf("Queue{{\n")
	for i := 0; i < queue.len(q^); i += 1 {
		fmt.printf("\t%v", queue.get(q, i))

		if i + 1 < queue.len(q^) {
			fmt.printf(",")
		}
		fmt.printf("\n")
	}
	fmt.printf("}}\n")
}
