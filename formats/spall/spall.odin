package spall

MAGIC :: u64(0x0BADF00D)

Header :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
}

Event_Type :: enum u8 {
	Begin,
	End,
}

Begin_Event :: struct #packed {
	type: Event_Type,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
}

End_Event :: struct #packed {
	type: Event_Type,
	pid:  u32,
	tid:  u32,
	time: f64,
}