package main

import "core:mem"
import "core:math/rand"
import "core:math/linalg/glsl"

bg_color      := FVec4{}
bg_color2     := FVec4{}
text_color    := FVec4{}
text_color2   := FVec4{}
text_color3   := FVec4{}
button_color  := FVec4{}
button_color2 := FVec4{}
line_color    := FVec4{}
division_color    := FVec4{}
subdivision_color := FVec4{}
outline_color := FVec4{}
toolbar_color := FVec4{}
graph_color   := FVec4{}
highlight_color := FVec4{}
shadow_color := FVec4{}
wide_rect_color := FVec4{}
wide_bg_color := FVec4{}

choice_count :: 16
color_choices: [choice_count]FVec3

default_colors :: proc "contextless" (is_dark: bool) {
	if is_dark {
		bg_color         = FVec4{15,   15,  15, 255}
		bg_color2        = FVec4{0,     0,   0, 255}
		text_color       = FVec4{255, 255, 255, 255}
		text_color2      = FVec4{180, 180, 180, 255}
		text_color3      = FVec4{0,     0,   0, 255}
		button_color     = FVec4{40,   40,  40, 255}
		button_color2    = FVec4{20,   20,  20, 255}
		line_color       = FVec4{100, 100, 100, 255}
		outline_color    = FVec4{80,   80,  80, 255}
		toolbar_color    = FVec4{120, 120, 120, 255}
		graph_color      = FVec4{180, 180, 180, 255}
		highlight_color  = FVec4{  0,   0, 255,  32}
		wide_rect_color  = FVec4{  0, 255,   0,   0}
		wide_bg_color    = FVec4{  0,   0,   0, 255}
		shadow_color     = FVec4{  0,   0,   0, 120}

		subdivision_color = FVec4{ 30,  30, 30, 255}
		division_color    = FVec4{100, 100, 100, 255}
	} else {
		bg_color         = FVec4{254, 252, 248, 255}
		bg_color2        = FVec4{255, 255, 255, 255}
		text_color       = FVec4{0,     0,   0, 255}
		text_color2      = FVec4{80,   80,  80, 255}
		text_color3      = FVec4{0,     0,   0, 255}
		button_color     = FVec4{141, 119, 104, 255}
		button_color2    = FVec4{191, 169, 154, 255}
		line_color       = FVec4{150, 150, 150, 255}
		outline_color    = FVec4{219, 211, 205, 255}
		toolbar_color    = FVec4{219, 211, 205, 255}
		graph_color      = FVec4{69,   49,  34, 255}
		highlight_color  = FVec4{255, 255,   0,  32}
		wide_rect_color  = FVec4{  0, 255,   0,   0}
		wide_bg_color    = FVec4{  0,  0,    0, 255}
		shadow_color     = FVec4{  0,   0,   0,  15}

		subdivision_color = FVec4{230, 230, 230, 255}
		division_color    = FVec4{180, 180, 180, 255}
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
name_color_idx :: proc(name: string) -> u32 {
	return u32(uintptr(raw_data(name))) & u32(len(color_choices) - 1)
}

generate_color_choices :: proc() {
	// reset render state
	mem.zero_slice(color_choices[:])
	for i := 0; i < choice_count; i += 1 {

		h := rand.float32() * 0.5 + 0.5
		h *= h
		h *= h
		h *= h
		s := 0.5 + rand.float32() * 0.1
		v : f32 = 0.85

		color_choices[i] = hsv2rgb(FVec3{h, s, v}) * 255
	}
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
