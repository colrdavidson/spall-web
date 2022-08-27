package main

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
	max_time: u64,
	min_duration: u64,
	max_duration: u64,
	total_duration: u64,
	max_depth: int,

	thread_id: u64,
	events: [dynamic]Event,
}

Process :: struct {
	min_time: u64,
	max_time: u64,
	min_duration: u64,
	max_duration: u64,
	total_duration: u64,

	process_id: u64,
	threads: [dynamic]Thread,
	thread_map: map[u64]int,
}

rescale :: proc(val, old_min, old_max, new_min, new_max: f32) -> f32 {
	old_range := old_max - old_min
	new_range := new_max - new_min
	return (((val - old_min) * new_range) / old_range) + new_min
}
