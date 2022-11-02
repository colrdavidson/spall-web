package main

import "core:intrinsics"
import "core:mem"
import "core:math/rand"
import "core:math"
import "core:fmt"
import "core:c"
import "core:strings"

trap :: proc() -> ! {
	intrinsics.trap()
}

rand_int :: proc(min, max: int) -> int {
    return int(rand.int31()) % (max-min) + min
}

split_u64 :: proc(x: u64) -> (u32, u32) {
	lo := u32(x)
	hi := u32(x >> 32)
	return lo, hi
}

compose_u64 :: proc(lo, hi: u32) -> (u64) {
	return u64(hi) << 32 | u64(lo)
}

rescale :: proc(val, old_min, old_max, new_min, new_max: $T) -> T {
	old_range := old_max - old_min
	new_range := new_max - new_min
	return (((val - old_min) * new_range) / old_range) + new_min
}

i_round_down :: proc(x, align: $T) -> T {
	return x - (x %% align)
}

i_round_up :: proc(x, align: $T) -> T {
	return ((x + align - 1) / align) * align
}

f_round_down :: proc(x, align: $T) -> T {
	return x - math.remainder(x, align)
}

val_in_range :: proc(val, start, end: $T) -> bool {
	return val >= start && val <= end
}
range_in_range :: proc(s1, e1, s2, e2: $T) -> bool {
	return s1 <= e2 && e1 >= s2
}

pt_in_rect :: proc(pt: Vec2, box: Rect) -> bool {
	x1 := box.pos.x
	y1 := box.pos.y
	x2 := box.pos.x + box.size.x
	y2 := box.pos.y + box.size.y

	return x1 <= pt.x && pt.x <= x2 && y1 <= pt.y && pt.y <= y2
}

rect_in_rect :: proc(a, b: Rect) -> bool {
	a_left := a.pos.x
	a_right := a.pos.x + a.size.x

	a_top := a.pos.y
	a_bottom := a.pos.y + a.size.y

	b_left := b.pos.x
	b_right := b.pos.x + b.size.x

	b_top := b.pos.y
	b_bottom := b.pos.y + b.size.y

	return !(b_left > a_right || a_left > b_right || a_top > b_bottom || b_top > a_bottom)
}

ease_in :: proc(t: f32) -> f32 {
	return 1 - math.cos((t * math.PI) / 2)
}
ease_in_out :: proc(t: f32) -> f32 {
    return -(math.cos(math.PI * t) - 1) / 2;
}

ONE_MINUTE :: 1000 * 1000 * 60
ONE_SECOND :: 1000 * 1000
ONE_MILLI :: 1000
ONE_MICRO :: 1
ONE_NANO :: 0.001

tooltip_fmt :: proc(time: f64) -> string {
	if time > ONE_SECOND {
		cur_time := time / ONE_SECOND
		return fmt.tprintf("%.1f s ", cur_time)
	} else if time > ONE_MILLI {
		cur_time := time / ONE_MILLI
		return fmt.tprintf("%.1f ms", cur_time)
	} else if time >= ONE_MICRO {
		return fmt.tprintf("%.1f μs", time)
	} else {
		cur_time := time / ONE_NANO
		return fmt.tprintf("%.1f ns", cur_time)
	}
}

stat_fmt :: proc(time: f64) -> string {
	if time > ONE_SECOND {
		cur_time := time / ONE_SECOND
		return fmt.tprintf("%.1f s ", cur_time)
	} else if time > ONE_MILLI {
		cur_time := time / ONE_MILLI
		return fmt.tprintf("%.1f ms", cur_time)
	} else if time >= ONE_MICRO {
		return fmt.tprintf("%.1f us", time) // μs
	} else {
		cur_time := time / ONE_NANO
		return fmt.tprintf("%.1f ns", cur_time)
	}
}

time_fmt :: proc(time: f64) -> string {
	minutes_str: string
	seconds_str: string
	millis_str : string
	micros_str : string
	nanos_str  : string
	picos_str  : string

	mins := math.floor(math.mod(time / ONE_MINUTE, 60))
	if mins > 0 && mins < 60 {
		minutes_str = fmt.tprintf(" %.0fm", mins)
	} 

	secs := math.floor(math.mod(time / ONE_SECOND, 60))
	if secs > 0 && secs < 60 {
		seconds_str = fmt.tprintf(" %.0fs", secs)
	} 

	millis := math.floor(math.mod(time / ONE_MILLI, 1000))
	if millis > 0 && millis < 1000 {
		millis_str = fmt.tprintf(" %.0fms", millis)
	} 

	micros := math.floor(math.mod(time, 1000))
	if micros > 0 && micros < 1000 {
		micros_str = fmt.tprintf(" %.0fμs", micros)
	}

	_, nanos := math.modf(time)
	nanos = math.floor(nanos * 1000)
	if (nanos > 0 && nanos < 1000) || time == 0 {
		nanos_str = fmt.tprintf(" %.0fns", nanos)
	}

	_, picos := math.modf(time)
	picos = math.floor(picos * 1000000)
	if (picos > 0 && picos < 1000) {
		picos_str = fmt.tprintf(" %.0fps", picos)
	}

	return fmt.tprintf("%s%s%s%s%s%s", minutes_str, seconds_str, millis_str, micros_str, nanos_str, picos_str)
}

TimeClump :: struct {
	value: f64,
	unit: string,
	max: f64,
	digits: int,
}

measure_fmt :: proc(time: f64) -> string {
	b := strings.builder_make(temp_allocator)

	_, picos := math.modf(time)
	picos = math.floor(picos * 1_000_000)

	_, nanos := math.modf(time)
	nanos = math.floor(nanos * 1000)

	micros := math.floor(math.mod(time, 1000))
	millis := math.floor(math.mod(time / ONE_MILLI, 1000))
	secs := math.floor(math.mod(time / ONE_SECOND, 60))
	mins := math.floor(math.mod(time / ONE_MINUTE, 60))

	clumps := [?]TimeClump{
		{mins,   "m",    60, 2},
		{secs,   "s",    60, 2},
		{millis, "ms", 1000, 3},
		{micros, "μs", 1000, 3},
		{nanos,  "ns", 1000, 3},
		{picos,  "ps", 1000, 3},
	}

	for clump, idx in clumps {
		if (clump.value > 0) && (clump.value < clump.max) {
			if (strings.builder_len(b) > 0 && idx > 0) {
				strings.write_rune(&b, ' ')
			}

			digits := int(math.log10(clump.value) + 1)
			for ;digits < clump.digits; digits += 1 {
				strings.write_byte(&b, ' ')
			}

			fmt.sbprintf(&b, "%.0f%s", clump.value, clump.unit)
		}
	}

	return strings.to_string(b)
}

parse_u32 :: proc(str: string) -> (val: u32, ok: bool) {
	ret : u64 = 0

	s := transmute([]u8)str
	for ch in s {
		if ch < '0' || ch > '9' || ret > u64(c.UINT32_MAX) {
			return
		}
		ret = (ret * 10) + u64(ch & 0xf)
	}
	return u32(ret), true
}

// this *shouldn't* be called with 0-len strings. 
// The current JSON parser enforces it due to the way primitives are parsed
// We reject NaNs, Infinities, and Exponents in this house.
parse_f64 :: proc(str: string) -> (ret: f64, ok: bool) #no_bounds_check {
	sign: f64 = 1

	i := 0
	if str[0] == '-' {
		sign = -1
		i += 1

		if len(str) == 1 {
			return 0, false
		}
	}

	val: f64 = 0
	for ; i < len(str); i += 1 {
		ch := str[i]

		if ch == '.' {
			break
		}

		if ch < '0' || ch > '9' {
			return 0, false
		}

		val = (val * 10) + f64(ch & 0xf)
	}

	if i < len(str) && str[i] == '.' {
		pow10: f64 = 10
		i += 1

		for ; i < len(str); i += 1 {
			ch := str[i]

			if ch < '0' || ch > '9' {
				return 0, false
			}

			val += f64(ch & 0xf) / pow10
			pow10 *= 10
		}
	}

	return sign * val, true
}

distance :: proc(p1, p2: Vec2) -> f64 {
	dx := p2.x - p1.x
	dy := p2.y - p1.y
	return math.sqrt((dx * dx) + (dy * dy))
}

ingest_start_time: u64
start_time: u64
start_mem: i64
allocator: mem.Allocator
start_bench :: proc(name: string, al := context.allocator) {
	start_time = u64(get_time())
	allocator = al
	arena := cast(^Arena)al.data
	start_mem = i64(u32(arena.offset))
}
stop_bench :: proc(name: string) {
	end_time := u64(get_time())
	arena := cast(^Arena)allocator.data
	end_mem := i64(u32(arena.offset))

	time_range := end_time - start_time
	mem_range := end_mem - start_mem
	fmt.printf("%s -- ran in %fs (%dms), used %f MB\n", name, f32(time_range) / 1000, time_range, f64(mem_range) / 1024 / 1024)
}

save_offset :: proc(alloc: ^mem.Allocator) -> int {
	arena := cast(^Arena)scratch_allocator.data
	return arena.offset
}

restore_offset :: proc(alloc: ^mem.Allocator, offset: int) {
	arena := cast(^Arena)scratch_allocator.data
	arena.offset = offset
}

