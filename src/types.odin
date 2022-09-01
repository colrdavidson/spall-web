package main

import "core:container/queue"
import "core:fmt"

Vec2 :: [2]f32
Vec3 :: [3]f32
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}
rect :: proc(x, y, w, h: f32) -> Rect {
	return Rect{Vec2{x, y}, Vec2{w, h}}
}

Event :: struct {
	name: string,
	duration: u64,
	timestamp: u64,
	thread_id: u64,
	process_id: u64,
	depth: int,
}

Thread :: struct {
	min_time: u64,
	max_depth: int,

	thread_id: u64,
	events: [dynamic]Event,
}

Process :: struct {
	min_time: u64,

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
