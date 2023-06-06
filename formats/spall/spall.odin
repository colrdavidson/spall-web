package spall

MANUAL_MAGIC :: u64(0x0BADF00D)
NATIVE_MAGIC :: u64(0xABADF00D)

Header :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
	must_be_0:      u64,
}

Event_Type :: enum u8 {
	Invalid             = 0,
	Custom_Data         = 1, // Basic readers can skip this.
	StreamOver          = 2,

	Begin               = 3,
	End                 = 4,
	Instant             = 5,

	Overwrite_Timestamp = 6, // Retroactively change timestamp units - useful for incrementally improving RDTSC frequency.
}

Begin_Event :: struct #packed {
	type:     Event_Type,
	category: u8,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
	args_len: u8,
}

End_Event :: struct #packed {
	type: Event_Type,
	pid:  u32,
	tid:  u32,
	time: f64,
}
