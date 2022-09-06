package main

import "core:container/queue"
import "core:fmt"

Vec2 :: [2]f32
Vec3 :: [3]f32
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}
DRect :: struct {
	x: f64,
	y: f32,
	size: Vec2,
}
Window :: [2]i64

rect :: #force_inline proc(x, y, w, h: f32) -> Rect {
	return Rect{Vec2{x, y}, Vec2{w, h}}
}

Camera :: struct {
	pan: Vec2,
	vel: Vec2,
	scale: f32,
}

EventType :: enum u8 {
	Complete,
	Begin,
	End
}

Event :: struct {
	name: string,
	type: EventType,
	duration: f64,
	timestamp: f64,
	thread_id: u64,
	process_id: u64,
	depth: u16,
}

Thread :: struct {
	min_time: f64,
	max_depth: u16,

	thread_id: u64,
	events: [dynamic]Event,
	rects: []EventRect,
}

Process :: struct {
	min_time: f64,

	process_id: u64,
	threads: [dynamic]Thread,
	thread_map: map[u64]int,
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
