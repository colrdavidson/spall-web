package main

import "core:intrinsics"
import "core:math/rand"
import "core:math"
import "core:math/linalg/glsl"
import "core:fmt"

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
	return x - (x %% align)
}

f_round_down :: proc(x, align: $T) -> T {
	return x - math.mod(x, align)
}

f_round_up :: proc(x, align: $T) -> T {
	return x - math.mod(x, align)
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

hsv2rgb :: proc(c: Vec3) -> Vec3 {
	K := glsl.vec3{1.0, 2.0 / 3.0, 1.0 / 3.0}
	sum := glsl.vec3{f32(c.x), f32(c.x), f32(c.x)} + K.xyz
	p := glsl.abs_vec3(glsl.fract(sum) * 6.0 - glsl.vec3{3,3,3})
	result := glsl.vec3{f32(c.z), f32(c.z), f32(c.z)} * glsl.mix(K.xxx, glsl.clamp(p - K.xxx, 0.0, 1.0), glsl.vec3{f32(c.y), f32(c.y), f32(c.y)})
	return Vec3{f64(result.x), f64(result.y), f64(result.z)}
}

ONE_SECOND :: 1000 * 1000
ONE_MILLI :: 1000
ONE_NANO :: 0.001
time_fmt :: proc(time: f64, aligned := false) -> string {
	if time > ONE_SECOND {
		cur_time := time / ONE_SECOND
		return fmt.tprintf("%.3f s%s", cur_time, aligned ? " " : "")
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
