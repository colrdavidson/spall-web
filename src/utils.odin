package main

import "core:mem"
import "core:math/rand"
import "core:math"
import "core:fmt"
import "core:c"
import "core:strings"
import "core:runtime"

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
	x1 := box.x
	y1 := box.y
	x2 := box.x + box.w
	y2 := box.y + box.h

	return x1 <= pt.x && pt.x <= x2 && y1 <= pt.y && pt.y <= y2
}

rect_in_rect :: proc(a, b: Rect) -> bool {
	a_left := a.x
	a_right := a.x + a.w

	a_top := a.y
	a_bottom := a.y + a.h

	b_left := b.x
	b_right := b.x + b.w

	b_top := b.y
	b_bottom := b.y + b.h

	return !(b_left > a_right || a_left > b_right || a_top > b_bottom || b_top > a_bottom)
}

ease_in :: proc(t: f32) -> f32 {
	return 1 - math.cos((t * math.PI) / 2)
}
ease_in_out :: proc(t: f32) -> f32 {
    return -(math.cos(math.PI * t) - 1) / 2;
}

ONE_DAY    :: 1000 * 1000 * 60 * 60 * 24
ONE_HOUR   :: 1000 * 1000 * 60 * 60
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

my_write_float :: proc(b: ^strings.Builder, f: f64, prec: int) -> (n: int) {
	return strings.write_float(b, f, 'f', prec, 8*size_of(f))
}

TimeUnits :: struct {
	unit: string,
	period: f64,
	digits: int,
}
time_unit_table := [?]TimeUnits{
	{"d", max(f64), 3},
	{"h",       24, 2},
	{"m",       60, 2},
	{"s",       60, 2},
	{"ms",    1000, 3},
	{"μs",    1000, 3},
	{"ns",    1000, 3},
	{"ps",    1000, 3},
}

get_div_clump_idx :: proc(divider: f64) -> (int, f64, f64) {
	div_clump_idx := 0

	time_fracts := [?]f64{
		divider / ONE_DAY,
		divider / ONE_HOUR,
		divider / ONE_MINUTE,
		divider / ONE_SECOND,
		divider / ONE_MILLI,
		divider / ONE_MICRO,
		divider,
		math.round(divider * 1000),
	}

	for fract, idx in time_fracts {
		tmp : f64 = 0

		tu := time_unit_table[idx]
		if idx == len(time_fracts) - 1 {
			tmp = f64(int(fract) % int(tu.period))
		} else {
			tmp = math.floor(math.mod(fract, tu.period))
		}

		if tmp != 0 {
			div_clump_idx = idx
		}
	}

	fract := time_fracts[div_clump_idx]
	tu    := time_unit_table[div_clump_idx]
	return div_clump_idx, fract, tu.period
}



// if bool is true, draw the top string
clump_time :: proc(time: f64, div_clump_idx: int) -> (string, string, f64) {
	start_b := strings.builder_make(context.temp_allocator)
	tick_b := strings.builder_make(context.temp_allocator)

	_time := time
	if time < 0 {
		_time = math.abs(time)
		return "", "", 0
	}

	// preserving precision as much as possible while getting the fractional bits
	picos := f64(i64(math.round(_time * 1000)) % 1000)
	nanos  := math.floor(math.mod(_time, 1000))
	micros := math.floor(math.mod(_time / ONE_MICRO, 1000))
	millis := math.floor(math.mod(_time / ONE_MILLI, 1000))
	secs   := math.floor(math.mod(_time / ONE_SECOND, 60))
	mins   := math.floor(math.mod(_time / ONE_MINUTE, 60))
	hours  := math.floor(math.mod(_time / ONE_HOUR,   24))
	days   := math.floor(_time / ONE_DAY)

	clumps := [?]f64{days, hours, mins, secs, millis, micros, nanos, picos}

	b := &start_b
	tick_val := 0.0
	last_val := false
	first_num := true
	for clump, idx in clumps {
		tu := time_unit_table[idx]

		if idx == div_clump_idx {
			b = &tick_b

			if idx > 0 {
				tick_val = clumps[idx - 1]
			}
			last_val = true
		}

		if !last_val && (clump <= 0 || clump >= tu.period) {
			continue
		}

		if !first_num && !last_val {
			strings.write_rune(b, ' ')
		}
		my_write_float(b, clump, 0)
		strings.write_string(b, tu.unit)

		if last_val {
			break
		}
		first_num = false
	}

	start_str := strings.to_string(start_b)
	if len(start_str) == 0 {
		if div_clump_idx > 0 {
			strings.write_string(&start_b, "0")
			strings.write_string(&start_b, time_unit_table[div_clump_idx - 1].unit)
		}
	}
	start_str = strings.to_string(start_b)
	tick_str := strings.to_string(tick_b)
	return start_str, tick_str, tick_val
}

time_fmt :: proc(time: f64) -> string {
	b := strings.builder_make(context.temp_allocator)

	if time == 0 {
		strings.write_string(&b, " 0ns")
		return strings.to_string(b)
	}

	_time := time
	if time < 0 {
		strings.write_rune(&b, '-')
		_time = math.abs(time)
	}


	// preserving precision as much as possible while getting the fractional bits
	picos := f64(i64(math.round(_time * 1000)) % 1000)

	nanos  := math.floor(math.mod(_time, 1000))
	micros := math.floor(math.mod(_time / ONE_MICRO, 1000))
	millis := math.floor(math.mod(_time / ONE_MILLI, 1000))
	secs   := math.floor(math.mod(_time / ONE_SECOND, 60))
	mins   := math.floor(math.mod(_time / ONE_MINUTE, 60))
	hours  := math.floor(math.mod(_time / ONE_HOUR,   24))
	days  := math.floor(_time / ONE_DAY)

	clumps := [?]f64{days, hours, mins, secs, millis, micros, nanos, picos}

	first_num := true
	for clump, idx in clumps {
		tu := time_unit_table[idx]
		if (clump <= 0 || clump >= tu.period) {
			continue
		}

		if !first_num {
			strings.write_rune(&b, ' ')
		}
		my_write_float(&b, clump, 0)
		strings.write_string(&b, tu.unit)
		first_num = false
	}

	return strings.to_string(b)
}

measure_fmt :: proc(time: f64) -> string {
	b := strings.builder_make(context.temp_allocator)

	// preserving precision as much as possible while getting the fractional bits
	picos := f64(i64(math.round(time * 1000)) % 1000)

	nanos  := math.floor(math.mod(time, 1000))
	micros := math.floor(math.mod(time / ONE_MICRO, 1000))
	millis := math.floor(math.mod(time / ONE_MILLI, 1000))
	secs   := math.floor(math.mod(time / ONE_SECOND, 60))
	mins   := math.floor(math.mod(time / ONE_MINUTE, 60))
	hours  := math.floor(math.mod(time / ONE_HOUR,   24))
	days  := math.floor(time / ONE_DAY)

	clumps := [?]f64{days, hours, mins, secs, millis, micros, nanos, picos}
	for clump, idx in clumps {
		tu := time_unit_table[idx]
		if (clump <= 0 || clump >= tu.period) {
			continue
		}

		if (strings.builder_len(b) > 0 && idx > 0) {
			strings.write_rune(&b, ' ')
		}

		digits := int(math.log10(clump) + 1)
		for ;digits < tu.digits; digits += 1 {
			strings.write_byte(&b, ' ')
		}

		my_write_float(&b, clump, 0)
		strings.write_string(&b, tu.unit)
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

// This only works for positive doubles. Don't be a dummy and use negative doubles
squashy_downer : f64 = 1 / math.F64_EPSILON
ceil_f64 :: proc(x: f64) -> f64 {
	i := transmute(u64)x

	e := int((i >> 52) & 0x7FF)
	if e >= (0x3FF + 52) || x == 0 {
		return x
	}

	y := x + squashy_downer - squashy_downer - x
	if e <= 0x3FF - 1 { return 1.0 }
	if y < 0 {
		return x + y + 1
	}
	return x + y
}


distance :: proc(p1, p2: Vec2) -> f64 {
	dx := p2.x - p1.x
	dy := p2.y - p1.y
	return math.sqrt((dx * dx) + (dy * dy))
}

geomean :: proc(a, b: f64) -> f64 {
	return math.sqrt(a * b)
}

trunc_string :: proc(str: string, pad, max_width: f64) -> string {
	text_width := int(math.floor((max_width - (pad * 2)) / ch_width))
	max_chars := max(0, min(len(str), text_width))
	chopped_str := str[:max_chars]
	if max_chars != len(str) {
		chopped_str = fmt.tprintf("%s…", chopped_str[:len(chopped_str)-1])
	}

	return chopped_str
}

slice_to_type :: proc(buf: []u8, $T: typeid) -> (T, bool) #optional_ok {
    if len(buf) < size_of(T) {
        return {}, false
    }

    return intrinsics.unaligned_load((^T)(raw_data(buf))), true
}

disp_time :: proc(trace: ^Trace, ts: f64) -> f64 {
	return ceil_f64(ts * trace.stamp_scale)
}

slice_to_dyn :: proc(a: $T/[]$E) -> [dynamic]E {
	s := transmute(runtime.Raw_Slice)a
	d := runtime.Raw_Dynamic_Array{
		data = s.data,
		len  = s.len,
		cap  = s.len,
		allocator = runtime.nil_allocator(),
	}
	return transmute([dynamic]E)d
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
