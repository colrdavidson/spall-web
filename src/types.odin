package main

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
	InvalidFile = 3,
	InvalidFileVersion = 4,
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

JSONEvent :: struct #packed {
	name: INStr,
	args: INStr,
	depth: u16,
	timestamp: f64,
	duration: f64,
	self_time: f64,
}
Event :: struct #packed {
	name: INStr,
	args: INStr,
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

Thread :: struct {
	min_time: f64,
	max_time: f64,
	current_depth: u16,

	thread_id: u32,

	events: [dynamic]Event,
	json_events: [dynamic]JSONEvent,

	depths: [dynamic]Depth,
	instants: [dynamic]Instant,

	bande_q: IdStack,
}

Process :: struct {
	min_time: f64,

	process_id: u32,
	threads: [dynamic]Thread,
	instants: [dynamic]Instant,
	thread_map: ValHash,
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
		bande_q = ids_init(scratch_allocator),
	}
	return t
}

IdStack :: struct {
	arr: [dynamic]int,
	len: int,
}
ids_init :: proc(allocator := context.allocator) -> IdStack {
	return IdStack{ arr = make([dynamic]int, 16, allocator), len = 0 }
}
ids_push_back :: proc(s: ^IdStack, id: int) #no_bounds_check {
	if s.len >= cap(s.arr) {
		new_capacity := max(uint(8), uint(len(s.arr))*2)
		resize(&s.arr, int(new_capacity))
	}
	s.arr[s.len] = id
	s.len += 1
}
ids_pop_back :: proc(s: ^IdStack) -> int #no_bounds_check {
	s.len -= 1
	return s.arr[s.len]
}
ids_peek_back :: proc(s: ^IdStack) -> int #no_bounds_check { return s.arr[s.len - 1] }
ids_clear :: proc(s: ^IdStack) { s.len = 0 }

PathStack :: struct {
	arr: [dynamic]string,
	len: int,
}
path_init :: proc(allocator := context.allocator) -> PathStack {
	return PathStack{ arr = make([dynamic]string, 16, allocator), len = 0 }
}
path_push_back :: proc(s: ^PathStack, path: string) #no_bounds_check {
	if s.len >= cap(s.arr) {
		new_capacity := max(uint(8), uint(len(s.arr))*2)
		resize(&s.arr, int(new_capacity))
	}
	s.arr[s.len] = path
	s.len += 1
}
path_pop_back :: proc(s: ^PathStack) -> string #no_bounds_check { s.len -= 1; return s.arr[s.len] }
path_peek_back :: proc(s: ^PathStack) -> string #no_bounds_check { return s.arr[s.len - 1] }
path_clear :: proc(s: ^PathStack) { s.len = 0 }
