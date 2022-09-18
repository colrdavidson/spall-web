package main

import "core:container/queue"
import "core:fmt"
import "core:hash"
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

	bande_q: EventQueue,
}

Process :: struct {
	min_time: f64,

	process_id: u32,
	threads: [dynamic]Thread,
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

PTEntry :: struct {
	key: u32,
	val: int,
}
ValHash :: struct {
	entries: [dynamic]PTEntry,
	hashes:  [dynamic]int,
}

vh_init :: proc(allocator := context.allocator) -> ValHash {
	v := ValHash{}
	v.entries = make([dynamic]PTEntry, 0, allocator)
	v.hashes = make([dynamic]int, 16, allocator) // must be a power of two
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	return v
}

vh_hash :: proc(key: u32) -> u32 {
	return key * 2654435769
}

vh_find :: proc(v: ^ValHash, key: u32, loc := #caller_location) -> (int, bool) {
	hv := vh_hash(key) & u32(len(v.hashes) - 1)

	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			continue
		}

		if v.entries[e_idx].key == key {
			return v.entries[e_idx].val, true
		}
	}

	return -1, false
}

vh_grow :: proc(v: ^ValHash) {
	resize(&v.hashes, len(v.hashes) * 2)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}

	for entry, idx in v.entries {
		vh_reinsert(v, entry, idx)
	}
}

vh_reinsert :: proc(v: ^ValHash, entry: PTEntry, v_idx: int) {
	hv := vh_hash(entry.key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = v_idx
			return
		}
	}
}

vh_insert :: proc(v: ^ValHash, key: u32, val: int) {
	if len(v.entries) >= int(f64(len(v.hashes)) * 0.75) {
		vh_grow(v)
	}

	hv := vh_hash(key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = len(v.entries)
			append(&v.entries, PTEntry{key, val})
			return
		} else if v.entries[e_idx].key == key {
			v.entries[e_idx] = PTEntry{key, val}
			return
		}
	}

	fmt.printf("No more potatoes!\n")
	trap()
}
