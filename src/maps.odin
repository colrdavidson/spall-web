package main

import "core:fmt"
import "core:hash"
import "core:runtime"
import "core:strings"

// u32 -> u32 map
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
	v.hashes = make([dynamic]int, 32, allocator) // must be a power of two
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	return v
}

// this is a fibhash.. Replace me if I'm dumb
vh_hash :: proc "contextless" (key: u32) -> u32 {
	return key * 2654435769
}

vh_find :: proc "contextless" (v: ^ValHash, key: u32, loc := #caller_location) -> (int, bool) {
	hv := vh_hash(key) & u32(len(v.hashes) - 1)

	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

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

	for entry, idx in v.entries {
		vh_reinsert(v, entry, idx)
	}
}

vh_reinsert :: proc "contextless" (v: ^ValHash, entry: PTEntry, v_idx: int) {
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

// String interning
INMap :: struct {
	entries: [dynamic]string,
	hashes:  [dynamic]int,
	allocator: runtime.Allocator,
}

in_init :: proc(allocator := context.allocator) -> INMap {
	v := INMap{}
	v.entries = make([dynamic]string, 0, allocator)
	v.hashes = make([dynamic]int, 32, allocator) // must be a power of two
	v.allocator = allocator
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	return v
}

in_hash :: proc (key: string) -> u32 {
	k := transmute([]u8)key
	return #force_inline hash.murmur32(k)
}


in_reinsert :: proc (v: ^INMap, entry: string, v_idx: int) {
	hv := in_hash(entry) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = v_idx
			return
		}
	}
}

in_grow :: proc(v: ^INMap) {
	resize(&v.hashes, len(v.hashes) * 2)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}

	for entry, idx in v.entries {
		in_reinsert(v, entry, idx)
	}
}

in_get :: proc(v: ^INMap, key: string) -> string {
	if len(v.entries) >= int(f64(len(v.hashes)) * 0.75) {
		in_grow(v)
	}

	hv := in_hash(key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = len(v.entries)
			str := strings.clone(key, v.allocator)
			append(&v.entries, str)
			return str
		} else if v.entries[e_idx] == key {
			return v.entries[e_idx]
		}
	}

	fmt.printf("No more potatoes!\n")
	trap()
	return ""
}

// Key mashing
KeyMap :: struct {
	entries: [dynamic]string,
	hashes:  [dynamic]int,
}

km_init :: proc(allocator := context.allocator) -> KeyMap {
	v := KeyMap{}
	v.entries = make([dynamic]string, 0, 16, allocator)
	v.hashes = make([dynamic]int, 16, allocator) // must be a power of two
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}
	return v
}

km_hash :: proc (key: string) -> u32 {
	k := transmute([]u8)key
	return hash.fnv32a(k)
}

km_reinsert :: proc (v: ^KeyMap, entry: string, v_idx: int) {
	hv := km_hash(entry) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = v_idx
			return
		}
	}
}

km_grow :: proc(v: ^KeyMap) {
	resize(&v.hashes, len(v.hashes) * 2)
	for i in 0..<len(v.hashes) {
		v.hashes[i] = -1
	}

	for entry, idx in v.entries {
		km_reinsert(v, entry, idx)
	}
}

// expects that we only get static strings
km_insert :: proc(v: ^KeyMap, key: string) {
	if len(v.entries) >= int(f64(len(v.hashes)) * 0.75) {
		km_grow(v)
	}

	hv := km_hash(key) & u32(len(v.hashes) - 1)
	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			v.hashes[idx] = len(v.entries)
			append(&v.entries, key)
			return
		} else if v.entries[e_idx] == key {
			return
		}
	}

	fmt.printf("No more potatoes!\n")
	trap()
}

km_find :: proc (v: ^KeyMap, key: string, loc := #caller_location) -> (string, bool) {
	hv := km_hash(key) & u32(len(v.hashes) - 1)

	for i: u32 = 0; i < u32(len(v.hashes)); i += 1 {
		idx := (hv + i) & u32(len(v.hashes) - 1)

		e_idx := v.hashes[idx]
		if e_idx == -1 {
			return "", false
		}

		if v.entries[e_idx] == key {
			return v.entries[e_idx], true
		}
	}

	return "", false
}
