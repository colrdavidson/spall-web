package main

import "core:intrinsics"
import "core:math/rand"
import "core:math"

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

round_down :: proc(x, align: f32) -> f32 {
	return x - math.mod(x, align)
}

round_up :: proc(x, align: f32) -> f32 {
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
