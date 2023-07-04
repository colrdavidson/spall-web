package main

import "core:fmt"
import "core:mem"
import "core:runtime"

Vec2  :: [2]f64
FVec2 :: [2]f32

Vec3  :: [3]f64
FVec3 :: [3]f32

FVec4 :: [4]f32
BVec4 :: [4]u8

Rect :: struct {
	x: f64,
	y: f64,
	w: f64,
	h: f64,
}

DrawRect :: struct #packed {
	start: f32,
	width: f32,
	color: BVec4,
}

UIState :: struct {
	width: f64,
	height: f64,
	side_pad: f64,
	rect_height: f64,
	top_line_gap: f64,
	topbars_height: f64,
	line_height: f64,

	flamegraph_header_height: f64,
	flamegraph_toptext_height: f64,
	info_pane_height:     f64,

	header_rect:          Rect,
	global_activity_rect: Rect,
	global_timebar_rect:  Rect,
	local_timebar_rect:   Rect,

	info_pane_rect:       Rect,
	tab_rect:             Rect,

	filter_pane_rect:      Rect,
	filter_pane_scroll_pos: f64,
	filter_pane_scroll_vel: f64,

	stats_pane_rect:      Rect,
	stats_pane_scroll_pos: f64,
	stats_pane_scroll_vel: f64,

	minimap_rect:         Rect,

	full_flamegraph_rect:   Rect,
	inner_flamegraph_rect:  Rect,
	padded_flamegraph_rect: Rect,

	render_one_more: bool,
	multiselecting: bool,
	resizing_pane: bool,
	filters_open: bool,
}

ColorMode :: enum {
	Dark,
	Light,
	Auto,
}

SpallError :: enum int {
	NoError = 0,
	OutOfMemory = 1,
	Bug = 2,
	InvalidFile = 3,
	InvalidFileVersion = 4,
	NativeFileDetected = 5,
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
	avg_time: f64,
	min_time: f64,
	max_time: f64,
	count: u32,
}
Range :: struct {
	pid: i32,
	tid: i32,
	did: i32,

	start: i32,
	end: i32,
}
StatState :: enum {
	NoStats,
	Started,
	Finished,
}
SortState :: enum {
	SelfTime,
	TotalTime,
	MinTime,
	MaxTime,
	AvgTime,
}
StatOffset :: struct {
	range_idx: i32,
	event_idx: i32,
}

EventType :: enum u8 {
	Unknown = 0,
	Instant,
	Complete,
	Begin,
	End,
	Metadata,
	Sample,
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

	start_idx: u32,
	end_idx: u32,
	children: [CHUNK_NARY_WIDTH]u32,

	child_count: i8,
	arr_len: i8,
}

Depth :: struct {
	head: u32,
	tree: [dynamic]ChunkNode,
	bs_events: [dynamic]Event,
	events: []Event,
}

EVData :: struct {
	idx: i32,
	depth: u16,
	self_time: f64,
}

Thread :: struct {
	min_time: f64,
	max_time: f64,
	current_depth: u16,

	thread_id: u32,
	name: INStr,

	events: [dynamic]Event,
	json_events: [dynamic]JSONEvent,

	depths: [dynamic]Depth,
	instants: [dynamic]Instant,

	bande_q: Stack(EVData),
}

Process :: struct {
	min_time: f64,
	name: INStr,

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
		json_events = make([dynamic]JSONEvent, big_global_allocator),
		depths = make([dynamic]Depth, small_global_allocator),
		instants = make([dynamic]Instant, big_global_allocator),
	}
	stack_init(&t.bande_q, scratch_allocator)
	return t
}

Stack :: struct($T: typeid) {
	arr: [dynamic]T,
	len: int,
}

stack_init :: proc(s: ^$Q/Stack($T), allocator := context.allocator) {
	s.arr = make([dynamic]T, 16, allocator)
	s.len = 0
}
stack_push_back :: proc(s: ^$Q/Stack($T), elem: T) #no_bounds_check {
	if s.len >= cap(s.arr) {
		new_capacity := max(8, len(s.arr)*2)
		resize(&s.arr, new_capacity)
	}
	s.arr[s.len] = elem
	s.len += 1
}
stack_pop_back :: proc(s: ^$Q/Stack($T)) -> T #no_bounds_check {
	s.len -= 1
	return s.arr[s.len]
}
stack_peek_back :: proc(s: ^$Q/Stack($T)) -> T #no_bounds_check { return s.arr[s.len - 1] }
stack_clear :: proc(s: ^$Q/Stack($T)) { s.len = 0 }

print_stack :: proc(s: ^$Q/Stack($T)) {
	fmt.printf("Stack{{\n")
	for i:= 0; i < s.len; i += 1 {
		fmt.printf("%#v\n", s.arr[i])
	}
	fmt.printf("}}\n")
}
