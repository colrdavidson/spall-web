package spall

MANUAL_MAGIC :: u64(0x0BADF00D)
NATIVE_MAGIC :: u64(0xABADF00D)

Manual_Header :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
	must_be_0:      u64,
}

Manual_Event_Type :: enum u8 {
	Invalid             = 0,
	Custom_Data         = 1, // Basic readers can skip this.
	StreamOver          = 2,

	Begin               = 3,
	End                 = 4,
	Instant             = 5,

	Overwrite_Timestamp = 6, // Retroactively change timestamp units - useful for incrementally improving RDTSC frequency.
	Pad_Skip            = 7,

	Name_Process        = 8,
	Name_Thread         = 9,
}

Manual_Buffer_Header :: struct #packed {
	size:     u32,
	tid:      u32,
	pid:      u32,
	first_ts: u64,
}

Begin_Event_V1 :: struct #packed {
	type:     Manual_Event_Type,
	category: u8,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
	args_len: u8,
}

End_Event_V1 :: struct #packed {
	type: Manual_Event_Type,
	pid:  u32,
	tid:  u32,
	time: f64,
}


Begin_Event_V2 :: struct #packed {
	type: Manual_Event_Type,
	time: u64,
	name_len: u8,
	args_len: u8,
}

End_Event_V2 :: struct #packed {
	type: Manual_Event_Type,
	time: u64,
}

Pad_Skip :: struct #packed {
	type: Manual_Event_Type,
	size: u32,
}

Name_Container :: struct #packed {
	type: Manual_Event_Type,
	name_len: u8,
}
