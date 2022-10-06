package main

import "core:intrinsics"
import "core:math/rand"
import "core:math"
import "core:math/linalg/glsl"
import "core:fmt"
import "core:c"

trap :: proc() {
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

hsv2rgb :: proc(c: FVec3) -> FVec3 {
	K := glsl.vec3{1.0, 2.0 / 3.0, 1.0 / 3.0}
	sum := glsl.vec3{c.x, c.x, c.x} + K.xyz
	p := glsl.abs_vec3(glsl.fract(sum) * 6.0 - glsl.vec3{3,3,3})
	result := glsl.vec3{c.z, c.z, c.z} * glsl.mix(K.xxx, glsl.clamp(p - K.xxx, 0.0, 1.0), glsl.vec3{c.y, c.y, c.y})
	return FVec3{result.x, result.y, result.z}
}

hex_to_fvec :: proc "contextless" (v: u32) -> FVec4 {
	a := f32(u8(v >> 24))
	r := f32(u8(v >> 16))
	g := f32(u8(v >> 8))
	b := f32(u8(v >> 0))

	return FVec4{r, g, b, a}
}

ONE_MINUTE :: 1000 * 1000 * 60
ONE_SECOND :: 1000 * 1000
ONE_MILLI :: 1000
ONE_NANO :: 0.001
stat_fmt :: proc(time: f64) -> string {
	if time > ONE_SECOND {
		cur_time := time / ONE_SECOND
		return fmt.tprintf("%.3f s%s", cur_time, " ")
	} else if time > ONE_MILLI {
		cur_time := time / ONE_MILLI
		return fmt.tprintf("%.3f ms", cur_time)
	} else if time >= ONE_NANO {
		return fmt.tprintf("%.3f us", time) // μs
	} else {
		cur_time := time / ONE_NANO
		return fmt.tprintf("%.3f ns", cur_time)
	}
}

time_fmt :: proc(time: f64) -> string {
	minutes_str: string
	seconds_str: string
	millis_str : string
	micros_str : string
	nanos_str  : string

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

	nanos := math.floor((time - math.floor(time)) * 1000)
	if (nanos > 0 && nanos < 1000) || time == 0 {
		nanos_str = fmt.tprintf(" %.0fns", nanos)
	}

	return fmt.tprintf("%s%s%s%s%s", minutes_str, seconds_str, millis_str, micros_str, nanos_str)
}

parse_u32 :: proc(str: string) -> (u32, bool) {
	ret : u64 = 0

	s := transmute([]u8)str
	for ch in s {
		if ch < '0' || ch > '9' || ret > u64(c.UINT32_MAX) {
			return 0, false
		}
		ret = (ret * 10) + u64(ch & 0xf)
	}
	return u32(ret), true
}
