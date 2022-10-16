package main

import "core:fmt"
import "core:os"
import "core:strings"


MAGIC :: u64(0x0BADF00D)

V0_Header :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
	must_be_0:      u64,
}

V0_Event_Type :: enum u8 {
	Invalid             = 0,
	Custom_Data         = 1, // Basic readers can skip this.
	StreamOver          = 2,

	Begin               = 3,
	End                 = 4,
	Instant             = 5,

	Overwrite_Timestamp = 6, // Retroactively change timestamp units - useful for incrementally improving RDTSC frequency.
}

V0_Begin_Event :: struct #packed {
	type:     V0_Event_Type,
	category: u8,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
	args_len: u8,
}

V0_End_Event :: struct #packed {
	type: V0_Event_Type,
	pid:  u32,
	tid:  u32,
	time: f64,
}

V1_Header :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
	must_be_0:      u64,
}

V1_Event_Type :: enum u8 {
	Invalid             = 0,
	Custom_Data         = 1, // Basic readers can skip this.
	StreamOver          = 2,

	Begin               = 3,
	End                 = 4,
	Instant             = 5,

	Overwrite_Timestamp = 6, // Retroactively change timestamp units - useful for incrementally improving RDTSC frequency.
}

V1_Begin_Event :: struct #packed {
	type:     V1_Event_Type,
	category: u8,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
	args_len: u8,
}

V1_End_Event :: struct #packed {
	type: V1_Event_Type,
	pid:  u32,
	tid:  u32,
	time: f64,
}


EventType :: enum u8 {
	Begin,
	End
}
Event :: struct {
	type: EventType,
	name: string,
	duration: f64,
	timestamp: f64,
	thread_id: u32,
	process_id: u32,
}

emit_header :: proc(buf: ^[dynamic]u8, stamp_scale: f64) {
	header := V1_Header{magic = MAGIC, version = 1, timestamp_unit = stamp_scale, must_be_0 = 0}
	header_bytes := transmute([size_of(V1_Header)]u8)header
	append(buf, ..header_bytes[:])
}
emit_begin_event :: proc(buf: ^[dynamic]u8, name: string, pid, tid: u32, ts: f64) {
	begin := V1_Begin_Event {
		type = .Begin,
		category = 0,
		pid  = pid,
		tid  = tid,
		time = ts,
		name_len = u8(len(name)),
		args_len = 0,
	}

	begin_bytes := transmute([size_of(V1_Begin_Event)]u8)begin
	append(buf, ..begin_bytes[:])
	append(buf, name)

}
emit_end_event :: proc(buf: ^[dynamic]u8, pid, tid: u32, ts: f64) {
	end := V1_End_Event {
		type = .End,
		pid  = pid,
		tid  = tid,
		time = ts,
	}
	end_bytes := transmute([size_of(V1_End_Event)]u8)end
	append(buf, ..end_bytes[:])
}

parse_v0_file :: proc(data: []u8) -> (f64, []Event, bool) {
	header_sz := size_of(V0_Header)
	if len(data) < header_sz {
		return 0, nil, false
	}
	magic := (^u64)(raw_data(data))^
	if magic != MAGIC {
		return 0, nil, false
	}

	hdr := cast(^V0_Header)raw_data(data)
	if hdr.version != 0 {
		return 0, nil, false
	}

	intern := strings.Intern{}
	strings.intern_init(&intern)

	stamp_scale := hdr.timestamp_unit
	offset := int(header_sz)

	events := make([dynamic]Event)
	for ;; {
		if offset >= len(data) {
			return stamp_scale, events[:], true
		}

		header_sz := int(size_of(u64))
		if offset + header_sz > len(data) {
			return 0, nil, false
		}

		type := (^V0_Event_Type)(raw_data(data[offset:]))^
		switch type {
		case .Begin:
			event_sz := size_of(V0_Begin_Event)
			if offset + event_sz > len(data) {
				return 0, nil, false
			}
			event := (^V0_Begin_Event)(raw_data(data[offset:]))^

			event_tail := int(event.name_len) + int(event.args_len)
			if offset + event_sz + event_tail > len(data) {
				return 0, nil, false
			}

			name := string(data[offset + event_sz:offset + event_sz + int(event.name_len)])
			str, err := strings.intern_get(&intern, name)
			if err != nil {
				return 0, nil, false
			}

			ev := Event{
				type = .Begin,
				timestamp = event.time,
				thread_id = event.tid,
				process_id = event.pid,
				name = str,
			}

			offset += event_sz + int(event.name_len) + int(event.args_len)
			append(&events, ev)
			continue
		case .End:
			event_sz := size_of(V0_End_Event)
			if offset + event_sz > len(data) {
				return 0, nil, false
			}
			event := (^V0_End_Event)(raw_data(data[offset:]))^

			ev := Event{
				type = .End,
				timestamp = event.time,
				thread_id = event.tid,
				process_id = event.pid,
			}
			
			offset += event_sz
			append(&events, ev)
			continue
		case .StreamOver:          fallthrough; // @Todo
		case .Custom_Data:         fallthrough; // @Todo
		case .Instant:             fallthrough; // @Todo
		case .Overwrite_Timestamp: fallthrough; // @Todo
		case .Invalid: fallthrough;
		case:
			fmt.printf("Unknown/invalid chunk (%v)\n", type)
		}

		return 0, nil, false
	}
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintf("%v <trace_in.spall> <trace_out.spall>\n", os.args[0])
		os.exit(1)
	}

	data, ok := os.read_entire_file(os.args[1])
	defer delete(data)
	if !ok {
		fmt.eprintf("%v could not be opened for reading.\n", os.args[1])
		os.exit(1)
	}

	stamp_scale, events, ok2 := parse_v0_file(data)
	if !ok2 {
		fmt.eprintf("Failed to read v0 file!\n");
		os.exit(1)
	}

	buf := make([dynamic]u8)
	emit_header(&buf, stamp_scale)
	for event in events {
		switch event.type {
		case .Begin: emit_begin_event(&buf, event.name, event.process_id, event.thread_id, event.timestamp)
		case .End:   emit_end_event(&buf, event.process_id, event.thread_id, event.timestamp)
		case:
			fmt.printf("Unknown/invalid event %v\n", event)
		}
	}

	out_file := fmt.tprintf("%v.spall", os.args[2])
	if os.write_entire_file(out_file, buf[:]) {
	} else {
		fmt.eprintf("Problem writing to %v\n", out_file)
		os.exit(1)
	}
}
