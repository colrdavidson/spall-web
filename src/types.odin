package main

import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:runtime"

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
	Instant,
	Complete,
	Begin,
	End
}
EventScope :: enum u8 {
	Global,
	Process,
	Thread,
}

TempEvent :: struct {
	type: EventType,
	scope: EventScope,
	name: string,
	duration: f64,
	timestamp: f64,
	thread_id: u32,
	process_id: u32,
}
Instant :: struct #packed {
	name: string,
	timestamp: f64,
}

Event :: struct #packed {
	type: EventType,
	name: string,
	timestamp: f64,
	duration: f64,
	depth: u16,
}

EventQueue :: distinct queue.Queue(int)
Thread :: struct {
	min_time: f64,
	max_time: f64,
	max_depth: u16,
	current_depth: u16,

	thread_id: u32,
	events: [dynamic]Event,
	depths: [dynamic][]Event,
	bs_depths: [dynamic][dynamic]Event,
	instants: [dynamic]Instant,

	bande_q: EventQueue,
}

Process :: struct {
	min_time: f64,

	process_id: u32,
	threads: [dynamic]Thread,
	instants: [dynamic]Instant,
	thread_map: ValHash,
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

init_process :: proc(process_id: u32) -> Process {
	return Process{
		min_time = 0x7fefffffffffffff, 
		process_id = process_id,
		threads = make([dynamic]Thread, small_global_allocator),
		thread_map = vh_init(scratch_allocator),
		instants = make([dynamic]Instant, big_global_allocator),
	}
}

init_thread :: proc(thread_id: u32) -> Thread {
	t := Thread{
		min_time = 0x7fefffffffffffff, 
		thread_id = thread_id,
		events = make([dynamic]Event, big_global_allocator),
		depths = make([dynamic][]Event, small_global_allocator),
		bs_depths = make([dynamic][dynamic]Event, big_global_allocator),
		instants = make([dynamic]Instant, big_global_allocator),
	}
	queue.init(&t.bande_q, 0, scratch_allocator)
	return t
}
