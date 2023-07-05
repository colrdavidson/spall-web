package main

import "core:fmt"
import "core:hash"
import "core:runtime"
import "core:strings"
import "core:slice"

// u32 -> u32 map for pids and tids
PTEntry :: struct {
	key: u32,
	val: i32,
}
ValHash :: struct {
	entries: [dynamic]PTEntry,
	hashes:  [dynamic]i32,
	len_minus_one: u32,
}

vh_init :: proc(allocator := context.allocator) -> ValHash {
	v := ValHash{}
	v.entries = make([dynamic]PTEntry, 0, allocator)
	v.hashes = make([dynamic]i32, 32, allocator) // must be a power of two
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	v.len_minus_one = u32(len(v.hashes) - 1)
	return v
}

// this is a fibhash.. Replace me if I'm dumb
vh_hash :: proc "contextless" (key: u32) -> u32 {
	return key * 2654435769
}

vh_find :: proc "contextless" (v: ^ValHash, key: u32, loc := #caller_location) -> (i32, bool) {
	hv := vh_hash(key) & v.len_minus_one

	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & v.len_minus_one

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			return -1, false
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
	v.len_minus_one = u32(len(v.hashes) - 1)

	for entry, idx in v.entries {
		vh_reinsert(v, entry, i32(idx))
	}
}

vh_reinsert :: proc "contextless" (v: ^ValHash, entry: PTEntry, v_idx: i32) {
	hv := vh_hash(entry.key) & v.len_minus_one
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & v.len_minus_one

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = v_idx
			return
		}
	}
}

vh_insert :: proc(v: ^ValHash, key: u32, val: i32) {
	if i32(len(v.entries)) >= i32(f64(len(v.hashes)) * 0.75) {
		vh_grow(v)
	}

	hv := vh_hash(key) & v.len_minus_one
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & v.len_minus_one

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = i32(len(v.entries))
			append(&v.entries, PTEntry{key, val})
			return
		} else if v.entries[e_idx].key == key {
			v.entries[e_idx] = PTEntry{key, val}
			return
		}
	}

	push_fatal(SpallError.Bug)
}

INMAP_LOAD_FACTOR :: 0.75

// String interning
INMap :: struct {
	entries: [dynamic]u32,
	hashes:  [dynamic]i32,
	resize_threshold: i64,
}

in_init :: proc(allocator := context.allocator) -> INMap {
	v := INMap{}
	v.entries = make([dynamic]u32, 0, allocator)
	v.hashes = make([dynamic]i32, 32, allocator) // must be a power of two
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	v.resize_threshold = i64(f64(len(v.hashes)) * INMAP_LOAD_FACTOR) 
	return v
}

in_hash :: proc (key: string) -> u32 {
	k := transmute([]u8)key
	return #force_inline hash.murmur32(k)
}

in_reinsert :: proc (v: ^INMap, strings: ^[dynamic]u8, entry: u32, v_idx: i32) {
	hv := in_hash(in_getstr(strings, entry)) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = v_idx
			return
		}
	}
}

in_grow :: proc(v: ^INMap, strings: ^[dynamic]u8) {
	resize(&v.hashes, len(v.hashes) * 2)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}

	v.resize_threshold = i64(f64(len(v.hashes)) * INMAP_LOAD_FACTOR) 
	for entry, idx in v.entries {
		in_reinsert(v, strings, entry, i32(idx))
	}
}

in_get :: proc(v: ^INMap, strings: ^[dynamic]u8, key: string) -> u32 {
	if i64(len(v.entries)) >= v.resize_threshold {
		in_grow(v, strings)
	}
	if len(key) == 0 {
		return 0
	}

	hv := in_hash(key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = i32(len(v.entries))

			in_str := u32(len(strings))
			key_len := u16(len(key))
			key_len_bytes := (([^]u8)(&key_len)[:2])
			append_elem(strings, key_len_bytes[0])
			append_elem(strings, key_len_bytes[1])
			append_elem_string(strings, key)
			append(&v.entries, in_str)

			return in_str
		} else if in_getstr(strings, v.entries[e_idx]) == key {
			return v.entries[e_idx]
		}
	}

	push_fatal(SpallError.Bug)
}

in_getstr :: #force_inline proc(v: ^[dynamic]u8, s: u32) -> string {
	str_len := u32((^u16)(raw_data(v[s:]))^)
	str_start := s+size_of(u16)
	return string(v[str_start:str_start+str_len])
}

KM_CAP :: 32

// Key mashing
KeyMap :: struct {
	keys:   [KM_CAP]string,
	types: [KM_CAP]FieldType,
	hashes: [KM_CAP]i32,
	len: int,
}

km_init :: proc() -> KeyMap {
	v := KeyMap{}
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	return v
}

// lol, fibhash win
km_hash :: proc "contextless" (key: string) -> u32 {
	return u32(key[0]) * 2654435769 
}

// expects that we only get static strings
km_insert :: proc(v: ^KeyMap, key: string, type: FieldType) {
	hv := km_hash(key) & (KM_CAP - 1)
	for i: u32 = 0; i < KM_CAP; i += 1 {
		idx := (hv + i) & (KM_CAP - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = i32(v.len)
			v.keys[v.len] = key
			v.types[v.len] = type
			v.len += 1
			return
		} else if v.keys[e_idx] == key {
			return
		}
	}

	push_fatal(SpallError.Bug)
}

km_find :: proc (v: ^KeyMap, key: string) -> (FieldType, bool) {
	hv := km_hash(key) & (KM_CAP - 1)

	for i: u32 = 0; i < KM_CAP; i += 1 {
		idx := (hv + i) & (KM_CAP - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			return .Invalid, false
		}

		if v.keys[e_idx] == key {
			return v.types[e_idx], true
		}
	}

	return .Invalid, false
}

// Tracking for Stats
SMMAP_LOAD_FACTOR :: 0.75
StatEntry :: struct {
	key: u32,
	val: Stats,
}
StatMap :: struct {
	entries: [dynamic]StatEntry,
	hashes:  [dynamic]i32,
	resize_threshold: i64,
}
sm_init :: proc(allocator := context.allocator) -> StatMap {
	v := StatMap{}
	v.entries = make([dynamic]StatEntry, 0, allocator)
	v.hashes = make([dynamic]i32, 32, allocator) // must be a power of two
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	return v
}
sm_hash :: proc (start: u32) -> u32 {
	return start * 2654435769
}
sm_reinsert :: proc (v: ^StatMap, entry: StatEntry, v_idx: i32) {
	hv := sm_hash(entry.key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = v_idx
			return
		}
	}

	push_fatal(SpallError.Bug)
}

sm_grow :: proc(v: ^StatMap) {
	resize(&v.hashes, len(v.hashes) * 2)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}

	v.resize_threshold = i64(f64(len(v.hashes)) * SMMAP_LOAD_FACTOR) 
	for entry, idx in v.entries {
		sm_reinsert(v, entry, i32(idx))
	}
}

sm_get :: proc(v: ^StatMap, key: u32) -> (^Stats, bool) {
	hv := sm_hash(key) & u32(len(v.hashes) - 1)

	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			return nil, false
		} else if v.entries[e_idx].key == key {
			return &v.entries[e_idx].val, true
		}
	}

	push_fatal(SpallError.Bug)
}
sm_insert :: proc(v: ^StatMap, key: u32, val: Stats) -> ^Stats {
	if i64(len(v.entries)) >= v.resize_threshold {
		sm_grow(v)
	}

	hv := sm_hash(key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			e_idx = i32(len(v.entries))
			v.hashes[idx] = e_idx
			append(&v.entries, StatEntry{key, val})
			return &v.entries[e_idx].val
		} else if v.entries[e_idx].key == key {
			v.entries[e_idx] = StatEntry{key, val}
			return &v.entries[e_idx].val
		}
	}

	push_fatal(SpallError.Bug)
}
sm_sort :: proc(v: ^StatMap, less: proc(i, j: StatEntry) -> bool) {
	slice.sort_by(v.entries[:], less)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}

	for entry, idx in v.entries {
		sm_reinsert(v, entry, i32(idx))
	}
}
sm_clear :: proc(v: ^StatMap)  {
	resize(&v.entries, 0)
	resize(&v.hashes, 32)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	v.resize_threshold = i64(f64(len(v.hashes)) * SMMAP_LOAD_FACTOR) 
}
