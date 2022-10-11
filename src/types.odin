package main

import "core:container/queue"
import "core:fmt"
import "core:mem"
import "core:runtime"

Vec2 :: [2]f64
Vec3 :: [3]f64
FVec3 :: [3]f32
FVec4 :: [4]f32
Rect :: struct {
	pos: Vec2,
	size: Vec2,
}

rect :: #force_inline proc(x, y, w, h: f64) -> Rect {
	return Rect{Vec2{x, y}, Vec2{w, h}}
}

DrawRect :: struct #packed {
	start: f32,
	width: f32,
	color: [4]u8,
}

ColorMode :: enum {
	Dark,
	Light,
	Auto
}

SpallError :: enum int {
	NoError = 0,
	OutOfMemory = 1,
	Bug = 2,
}

Camera :: struct {
	pan: Vec2,
	vel: Vec2,
	target_pan_x: f64,

	current_scale: f64,
	target_scale: f64,
}

EventID :: struct {
	pid: i64,
	tid: i64,
	did: i64,
	eid: i64,
}
Stats :: struct {
	total_time: f64,
	self_time: f64,
	count: u32,
	min_time: f32,
	max_time: f32,
}
Range :: struct {
	pid: int,
	tid: int,
	did: int,

	start: int,
	end: int,
}
StatState :: enum {
	NoStats,
	Started,
	Finished,
}
StatOffset :: struct {
	range_idx: int,
	event_idx: int,
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
	name: INStr,
	args: INStr,
	duration: f64,
	timestamp: f64,
	thread_id: u32,
	process_id: u32,
}
Instant :: struct #packed {
	name: INStr,
	timestamp: f64,
}
Event :: struct #packed {
	name: INStr,
	depth: u16,
	timestamp: f64,
	duration: f64,
	self_time: f64,
}

BUCKET_SIZE :: 8
CHUNK_NARY_WIDTH :: 4
ChunkNode :: struct #packed {
	start_time: f64,
	end_time: f64,

	avg_color: FVec3,
	weight: f64,

	start_idx: uint,
	end_idx: uint,
	children: [CHUNK_NARY_WIDTH]uint,

	child_count: i8,
	arr_len: i8,
}

Depth :: struct {
	head: uint,
	tree: [dynamic]ChunkNode,
	bs_events: [dynamic]Event,
	events: []Event,
}

EventQueue :: distinct queue.Queue(int)
Thread :: struct {
	min_time: f64,
	max_time: f64,
	current_depth: u16,

	thread_id: u32,
	events: [dynamic]Event,
	depths: [dynamic]Depth,
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
		depths = make([dynamic]Depth, small_global_allocator),
		instants = make([dynamic]Instant, big_global_allocator),
	}
	queue.init(&t.bande_q, 0, scratch_allocator)
	return t
}
