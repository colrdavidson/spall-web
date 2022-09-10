package json2bin

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strconv"
import "core:strings"
import "formats:spall"

Trace :: struct {
	otherData: map[string]any,
	traceEvents: []struct{
		cat:  string,
		dur:  f64,
		name: string,
		ph:   string,
		pid:  u32,
		tid:  u32,
		ts:   f64,
	},
}

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintf("%v <trace.json>\n", os.args[0])
		os.exit(1)
	}

	data, ok := os.read_entire_file(os.args[1])
	defer delete(data)
	if !ok {
		fmt.eprintf("%v could not be opened for reading.\n", os.args[1])
		os.exit(1)
	}

	trace: Trace
	if json.unmarshal(data, &trace) != nil {
		fmt.eprintf("%v could not be parsed as an event trace.\n", os.args[1])
		os.exit(1)
	}

	buf: [dynamic]u8

	header := spall.Header{magic = spall.MAGIC, version = 0, timestamp_unit = 1}
	header_bytes := transmute([size_of(spall.Header)]u8)header
	append(&buf, ..header_bytes[:])

	/*
		{"cat":"function", "name":"main", "ph": "X", "pid": 0, "tid": 0, "ts": 0, "dur": 1},
		{"cat":"function", "name":"myfunction", "ph": "B", "pid": 0, "tid": 0, "ts": 0},
		{"cat":"function", "ph": "E", "pid": 0, "tid": 0, "ts": 0}
	*/

	for event in trace.traceEvents {
		switch event.ph {
		case "X", "B": // Complete or Begin Event
			name_len := min(len(event.name), 255)
			name     := event.name[:name_len]

			begin := spall.Begin_Event {
			 	type = .Begin,
			 	pid  = event.pid,
			 	tid  = event.tid,
			 	time = event.ts,
			 	name_len = u8(name_len),
		 	}

			begin_bytes := transmute([size_of(spall.Begin_Event)]u8)begin
			append(&buf, ..begin_bytes[:])
			append(&buf, name)
		}

		switch event.ph {
		case "X", "E": // Complete or End Event
			end := spall.End_Event {
			 	type = .End,
			 	pid  = event.pid,
			 	tid  = event.tid,
			 	time = event.ts + event.dur,
		 	}
			end_bytes := transmute([size_of(spall.End_Event)]u8)end
			append(&buf, ..end_bytes[:])
		}
	}
	out_file := fmt.tprintf("%v.spall", os.args[1])

	if os.write_entire_file(out_file, buf[:]) {
		fmt.printf("Done, wrote %v events to %v (%v bytes)\n", len(trace.traceEvents), out_file, len(buf))
	} else {
		fmt.eprintf("Problem writing to %v\n", out_file)
		os.exit(1)
	}
}