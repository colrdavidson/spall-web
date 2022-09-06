package main

import "core:fmt"
import "core:intrinsics"
import "core:mem"
import "core:runtime"
import "vendor:wasm/js"

Arena :: struct {
	data:       []byte,
	offset:     int,
	peak_used:  int,
	temp_count: int,
}

Arena_Temp_Memory :: struct {
	arena:       ^Arena,
	prev_offset: int,
}

arena_init :: proc(a: ^Arena, data: []byte) {
	a.data       = data
	a.offset     = 0
	a.peak_used  = 0
	a.temp_count = 0
}

arena_allocator :: proc(arena: ^Arena) -> mem.Allocator {
	return mem.Allocator{
		procedure = arena_allocator_proc,
		data = arena,
	}
}

arena_allocator_proc :: proc(
    allocator_data: rawptr,
    mode: mem.Allocator_Mode,
    size, alignment: int,
    old_memory: rawptr,
    old_size: int,
    location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	arena := cast(^Arena)allocator_data

	switch mode {
	case .Alloc:
		#no_bounds_check end := &arena.data[arena.offset]

		ptr := mem.align_forward(end, uintptr(alignment))

		total_size := size + mem.ptr_sub((^byte)(ptr), (^byte)(end))

		if arena.offset + total_size > len(arena.data) {
			fmt.printf("Out of memory @ %s\n", location)
			intrinsics.trap()
		}

		arena.offset += total_size
		arena.peak_used = max(arena.peak_used, arena.offset)
		mem.zero(ptr, size)
		return mem.byte_slice(ptr, size), nil

	case .Free:
		return nil, .Mode_Not_Implemented

	case .Free_All:
		arena.offset = 0

	case .Resize:
		return mem.default_resize_bytes_align(
            mem.byte_slice(old_memory, old_size), size, alignment, arena_allocator(arena)
        )

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Free_All, .Resize, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}

growing_arena_init :: proc(a: ^Arena, loc := #caller_location) {
	chunk, err := js.page_alloc(1)
	if err != nil {
		fmt.printf("OOM'd @ init | %s %s\n", err, loc)
		trap()
	}

	a.data       = chunk
	a.offset     = 0
	a.peak_used  = 0
	a.temp_count = 0
}

growing_arena_allocator :: proc(arena: ^Arena) -> mem.Allocator {
	return mem.Allocator{
		procedure = growing_arena_allocator_proc,
		data = arena,
	}
}

growing_arena_allocator_proc :: proc(
    allocator_data: rawptr,
    mode: mem.Allocator_Mode,
    size, alignment: int,
    old_memory: rawptr,
    old_size: int,
    location := #caller_location,
) -> ([]byte, mem.Allocator_Error) {
	arena := cast(^Arena)allocator_data

	switch mode {
	case .Alloc:
		#no_bounds_check end := &arena.data[arena.offset]
		ptr := mem.align_forward(end, uintptr(alignment))
		total_size := size + mem.ptr_sub((^byte)(ptr), (^byte)(end))

		if arena.offset + total_size > len(arena.data) {
			page_count := mem.align_formula(total_size, js.PAGE_SIZE) / js.PAGE_SIZE
			new_tail, err := js.page_alloc(page_count)
			if err != nil {
				fmt.printf("tried to get %f MB\n", f64(total_size) / 1024 / 1024)
				fmt.printf("OOM'd @ %f MB | %s\n", f64(len(arena.data)) / 1024 / 1024, location)
				trap()
			}

			head_ptr := raw_data(arena.data)
			arena.data = head_ptr[:len(arena.data)+len(new_tail)]
			//fmt.printf("resized to %f MB\n", f64(len(arena.data)) / 1024 / 1024)
		}

		arena.offset += total_size
		arena.peak_used = max(arena.peak_used, arena.offset)
		mem.zero(ptr, size)
		return mem.byte_slice(ptr, size), nil

	case .Free:
		return nil, .Mode_Not_Implemented

	case .Free_All:
		arena.offset = 0

	case .Resize:
		return mem.default_resize_bytes_align(
            mem.byte_slice(old_memory, old_size), size, alignment, growing_arena_allocator(arena)
        )

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Free_All, .Resize, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}
