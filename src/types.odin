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

	grip_delta: f64,
}

DrawRect :: struct #packed {
	start: f32,
	width: f32,
	color: BVec4,
}
FontSize :: enum u8 {
	PSize = 0,
	H1Size,
	H2Size,
	LastSize,
}
FontType :: enum u8 {
	DefaultFont = 0,
	MonoFont,
	IconFont,
	LastFont,
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
	total_time: i64,
	self_time:  i64,
	avg_time:   f64,
	min_time:   i64,
	max_time:   i64,
	count:      u32,
	hist:  [100]f64,
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
	Pass1,
	Pass2,
	Finished,
}
SortState :: enum {
	SelfTime,
	TotalTime,
	MinTime,
	MaxTime,
	AvgTime,
	Count,
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
	duration: i64,
	timestamp: i64,
	thread_id: u32,
	process_id: u32,
	name: u32,
	args: u32,
}
Instant :: struct #packed {
	name: u32,
	timestamp: i64,
}

JSONEvent :: struct #packed {
	name: u32,
	args: u32,
	depth: u16,
	timestamp: i64,
	duration: i64,
	self_time: i64,
}
Event :: struct #packed {
	name: u32,
	args: u32,
	timestamp: i64,
	duration: i64,
	self_time: i64,
}

COLOR_CHOICES :: 16
Trace :: struct {
	total_size: i64,
	parser: Parser,
	json_parser: JSONParser,
	intern: INMap,
	string_block: [dynamic]u8,

	color_choices: [COLOR_CHOICES]FVec3,

	processes: [dynamic]Process,
	process_map: ValHash,
	selected_ranges: [dynamic]Range,
	stats: StatMap,
	global_instants: [dynamic]Instant,
	stats_start_time: f64,
	stats_end_time:   f64,

	total_max_time: i64,
	total_min_time: i64,
	event_count: u64,
	instant_count: u64,
	stamp_scale: f64,

	file_name: string,
	file_name_store: [1024]u8,

	error_message: string,
	error_storage: [4096]u8,
}

BUCKET_SIZE :: 8
CHUNK_NARY_WIDTH :: 4
ChunkNode :: struct #packed {
	start_time: i64,
	end_time: i64,

	avg_color: FVec3,
	weight: i64,
}

Depth :: struct {
	tree: []ChunkNode,
	events: [dynamic]Event,
	leaf_count:   int,
	overhang_len: int,
	full_leaves: int,
}

EVData :: struct {
	idx: i32,
	depth: u16,
	self_time: i64,
}

Thread :: struct {
	min_time: i64,
	max_time: i64,
	current_depth: u16,

	id: u32,
	name: u32,

	in_stats: bool,

	json_events: [dynamic]JSONEvent,
	depths: [dynamic]Depth,
	instants: [dynamic]Instant,

	bande_q: Stack(EVData),
}

Process :: struct {
	min_time: i64,
	name: u32,

	in_stats: bool,

	id: u32,

	threads: [dynamic]Thread,
	instants: [dynamic]Instant,
	thread_map: ValHash,
}

init_process :: proc(process_id: u32) -> Process {
	return Process{
		min_time = 0x7fefffffffffffff, 
		id = process_id,
		threads = make([dynamic]Thread, small_global_allocator),
		thread_map = vh_init(scratch_allocator),
		instants = make([dynamic]Instant, big_global_allocator),
		in_stats = true,
	}
}
get_proc_name :: proc(trace: ^Trace, process: ^Process) -> string {
	if process.name > 0 {
		return fmt.tprintf("%s (PID %d)", in_getstr(&trace.string_block, process.name), process.id)
	} else {
		return fmt.tprintf("PID: %d", process.id)
	}
}

init_thread :: proc(thread_id: u32) -> Thread {
	t := Thread{
		min_time = 0x7fefffffffffffff, 
		id = thread_id,
		depths = make([dynamic]Depth, small_global_allocator),
		instants = make([dynamic]Instant, big_global_allocator),
		in_stats = true,
	}

	stack_init(&t.bande_q, scratch_allocator)
	return t
}
get_thread_name :: proc(trace: ^Trace, thread: ^Thread) -> string {
	if thread.name > 0 {
		return fmt.tprintf("%s (TID %d)", in_getstr(&trace.string_block, thread.name), thread.id)
	} else {
		return fmt.tprintf("TID: %d", thread.id)
	}
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
