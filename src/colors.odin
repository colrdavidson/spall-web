package main

import "core:mem"
import "core:math/rand"
import "core:math/linalg/glsl"

bg_color      := BVec4{}
bg_color2     := BVec4{}
text_color    := BVec4{}
text_color2   := BVec4{}
text_color3   := BVec4{}
line_color    := BVec4{}
division_color    := BVec4{}
subdivision_color := BVec4{}
outline_color := BVec4{}
xbar_color    := BVec4{}
error_color   := BVec4{}

subbar_color := BVec4{}
subbar_split_color := BVec4{}
toolbar_color := BVec4{}
toolbar_button_color  := BVec4{}
toolbar_text_color := BVec4{}
loading_block_color := BVec4{}
tabbar_color := BVec4{}

graph_color   := BVec4{}
highlight_color := BVec4{}
shadow_color := BVec4{}
wide_rect_color := BVec4{}
wide_bg_color := BVec4{}
rect_tooltip_stats_color := BVec4{}
test_color := BVec4{}
grip_color := BVec4{}

default_colors :: proc "contextless" (is_dark: bool) {
	loading_block_color  = BVec4{100, 194, 236, 255}

	error_color = BVec4{0xFF, 0x3F, 0x83, 255}
	test_color = BVec4{255, 10, 10, 255}

	// dark mode
	if is_dark {
		bg_color         = BVec4{15,   15,  15, 255}
		bg_color2        = BVec4{0,     0,   0, 255}
		text_color       = BVec4{255, 255, 255, 255}
		text_color2      = BVec4{180, 180, 180, 255}
		text_color3      = BVec4{0,     0,   0, 255}
		line_color       = BVec4{0,     0,   0, 255}
		outline_color    = BVec4{80,   80,  80, 255}

		subbar_color         = BVec4{0x33, 0x33, 0x33, 255}
		subbar_split_color   = BVec4{0x50, 0x50, 0x50, 255}
		toolbar_button_color = BVec4{40, 40, 40, 255}
		toolbar_color        = BVec4{0x00, 0x83, 0xb7, 255}
		toolbar_text_color   = BVec4{0xF5, 0xF5, 0xF5, 255}
		tabbar_color         = BVec4{0x3A, 0x3A, 0x3A, 255}

		graph_color      = BVec4{180, 180, 180, 255}
		highlight_color  = BVec4{ 64,  64, 255,   7}
		wide_rect_color  = BVec4{  0, 255,   0,   0}
		wide_bg_color    = BVec4{  0,   0,   0, 255}
		shadow_color     = BVec4{  0,   0,   0, 120}

		subdivision_color = BVec4{ 30,  30, 30, 255}
		division_color    = BVec4{100, 100, 100, 255}
		xbar_color        = BVec4{180, 180, 180, 255}
		grip_color        = BVec4{40, 40, 40, 255}

		rect_tooltip_stats_color = BVec4{80, 255, 80, 255}

	// light mode
	} else {
		bg_color         = BVec4{254, 252, 248, 255}
		bg_color2        = BVec4{255, 255, 255, 255}
		text_color       = BVec4{20,   20,  20, 255}
		text_color2      = BVec4{80,   80,  80, 255}
		text_color3      = BVec4{0,     0,   0, 255}
		line_color       = BVec4{200, 200, 200, 255}
		outline_color    = BVec4{219, 211, 205, 255}

		subbar_color         = BVec4{235, 230, 225, 255}
		subbar_split_color   = BVec4{150, 150, 150, 255}
		tabbar_color         = BVec4{220, 215, 210, 255}
		toolbar_button_color = BVec4{40, 40, 40, 255}
		toolbar_color        = BVec4{0x00, 0x83, 0xb7, 255}
		toolbar_text_color   = BVec4{0xF5, 0xF5, 0xF5, 255}

		graph_color      = BVec4{69,   49,  34, 255}
		highlight_color  = BVec4{255, 255,   0,  64}
		wide_rect_color  = BVec4{  0, 255,   0,   0}
		wide_bg_color    = BVec4{  0,  0,    0, 255}
		shadow_color     = BVec4{  0,   0,   0,  30}

		subdivision_color = BVec4{230, 230, 230, 255}
		division_color    = BVec4{180, 180, 180, 255}
		xbar_color        = BVec4{ 80,  80,  80, 255}
		grip_color        = BVec4{180, 175, 170, 255}

		rect_tooltip_stats_color = BVec4{20, 60, 20, 255}
	}
}

@export
set_color_mode :: proc "contextless" (auto: bool, is_dark: bool) {
	default_colors(is_dark)

	if auto {
		colormode = ColorMode.Auto
	} else {
		colormode = is_dark ? ColorMode.Dark : ColorMode.Light
	}
}

// color_choices must be power of 2
name_color_idx :: proc(name_idx: u32) -> u32 {
	return name_idx & u32(COLOR_CHOICES - 1)
}

generate_color_choices :: proc(trace: ^Trace) {
	for i := 0; i < COLOR_CHOICES; i += 1 {

		h := rand.float32() * 0.5 + 0.5
		h *= h
		h *= h
		h *= h
		s := 0.5 + rand.float32() * 0.1
		v : f32 = 0.85

		trace.color_choices[i] = hsv2rgb(FVec3{h, s, v}) * 255
	}
}

hsv2rgb :: proc(c: FVec3) -> FVec3 {
	K := glsl.vec3{1.0, 2.0 / 3.0, 1.0 / 3.0}
	sum := glsl.vec3{c.x, c.x, c.x} + K.xyz
	p := glsl.abs_vec3(glsl.fract(sum) * 6.0 - glsl.vec3{3,3,3})
	result := glsl.vec3{c.z, c.z, c.z} * glsl.mix(K.xxx, glsl.clamp(p - K.xxx, 0.0, 1.0), glsl.vec3{c.y, c.y, c.y})
	return FVec3{result.x, result.y, result.z}
}

hex_to_bvec :: proc "contextless" (v: u32) -> BVec4 {
	a := u8(v >> 24)
	r := u8(v >> 16)
	g := u8(v >> 8)
	b := u8(v >> 0)

	return BVec4{r, g, b, a}
}

bvec_to_fvec3 :: proc "contextless" (c: BVec4) -> FVec3 {
	return FVec3{f32(c.r), f32(c.g), f32(c.b)}
}
bvec_to_fvec4 :: proc "contextless" (c: BVec4) -> FVec4 {
	return FVec4{f32(c.r), f32(c.g), f32(c.b), f32(c.a)}
}

greyscale :: proc "contextless" (c: FVec3) -> FVec3 {
	return (c.x * 0.299) + (c.y * 0.587) + (c.z * 0.114)
}
