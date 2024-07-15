package main

import "base:intrinsics"
import "base:runtime"

import "core:fmt"
import "core:mem"

PAGE_SIZE :: 64 * 1024

page_alloc :: proc(page_count: int) -> (data: []byte, err: mem.Allocator_Error) {
	prev_page_count := intrinsics.wasm_memory_grow(0, uintptr(page_count))
	if prev_page_count == -1 {
		return nil, .Out_Of_Memory
	}

	ptr := ([^]u8)(uintptr(prev_page_count) * PAGE_SIZE)
	return ptr[:page_count * PAGE_SIZE], nil
}

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
	case .Alloc, .Alloc_Non_Zeroed:
		#no_bounds_check end := &arena.data[arena.offset]
		ptr := mem.align_forward(end, uintptr(alignment))
		align_skip := int(uintptr(ptr) - uintptr(end))
		total_size := size + align_skip

		if arena.offset + total_size > len(arena.data) {
			fmt.printf("Out of memory @ %s\n", location)
			push_fatal(SpallError.OutOfMemory)
		}

		arena.offset = arena.offset + total_size
		arena.peak_used = max(arena.peak_used, arena.offset)

		if mode != .Alloc_Non_Zeroed {
			mem.zero(ptr, size)
		}

		return mem.byte_slice(ptr, size), nil

	case .Free:
		return nil, .Mode_Not_Implemented

	case .Free_All:
		arena.offset = 0

	case .Resize:
		return mem.default_resize_bytes_align(
            mem.byte_slice(old_memory, old_size), size, alignment, arena_allocator(arena), location,
        )

	case .Resize_Non_Zeroed:
		return mem.default_resize_bytes_align_non_zeroed(
            mem.byte_slice(old_memory, old_size), size, alignment, arena_allocator(arena), location,
        )

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Alloc_Non_Zeroed, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}

growing_arena_init :: proc(a: ^Arena, loc := #caller_location) {
	chunk, err := page_alloc(10)
	if err != nil {
		fmt.printf("OOM'd @ init | %s %s\n", err, loc)
		push_fatal(SpallError.OutOfMemory)
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
	case .Alloc, .Alloc_Non_Zeroed:
		#no_bounds_check end := &arena.data[uint(arena.offset)]
		ptr := mem.align_forward(end, uintptr(alignment))
		align_skip := int(uintptr(ptr) - uintptr(end))
		total_size := size + align_skip

		if arena.offset + total_size > len(arena.data) {
			page_count := mem.align_formula(total_size, PAGE_SIZE) / PAGE_SIZE
			new_tail, err := page_alloc(page_count)
			if err != nil {
				fmt.printf("tried to get %M\n", total_size)
				fmt.printf("OOM'd @ %M | %s\n", len(arena.data), location)

				push_fatal(SpallError.OutOfMemory)
			}

			head_ptr := raw_data(arena.data)
			#no_bounds_check arena.data = head_ptr[:u64(len(arena.data))+u64(len(new_tail))]
			//fmt.printf("resized to %f MB\n", f64(u32(len(arena.data))) / 1024 / 1024)
		}

		arena.offset = arena.offset + total_size
		arena.peak_used = max(arena.peak_used, arena.offset)

		return mem.byte_slice(ptr, size), nil

	case .Free:
		return nil, .Mode_Not_Implemented

	case .Free_All:
		arena.offset = 0

	case .Resize:
		return mem.default_resize_bytes_align(mem.byte_slice(old_memory, old_size), size, alignment, growing_arena_allocator(arena), location)

	case .Resize_Non_Zeroed:
		return mem.default_resize_bytes_align_non_zeroed(mem.byte_slice(old_memory, old_size), size, alignment, growing_arena_allocator(arena), location)

	case .Query_Features:
		set := (^mem.Allocator_Mode_Set)(old_memory)
		if set != nil {
			set^ = {.Alloc, .Free_All, .Resize, .Resize_Non_Zeroed, .Query_Features}
		}
		return nil, nil

	case .Query_Info:
		return nil, .Mode_Not_Implemented
	}

	return nil, nil
}
