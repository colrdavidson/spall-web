package json2bin

import "core:fmt"
import "core:os"
import "core:encoding/json"
import "core:strconv"
import "core:strings"

BinEventType :: enum u8 {
	Invalid    = 0,
	Completion = 1,
	Begin      = 2,
	End        = 3,
	Instant    = 4,
	StreamOver = 5
}
BinHeader :: struct #packed {
	magic:          u64,
	version:        u64,
	timestamp_unit: f64,
	must_be_0:      u64
}
BeginEvent :: struct #packed {
	type:     BinEventType,
	pid:      u32,
	tid:      u32,
	time:     f64,
	name_len: u8,
}
EndEvent :: struct #packed {
	type: BinEventType,
	pid:  u32,
	tid:  u32,
	time: f64,
}

Trace :: struct {
	displayTimeUnit: string,
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

	timestamp_unit := 1.0
	if trace.displayTimeUnit == "ns" { timestamp_unit = 1000 }

	header := BinHeader{magic = 0x0BADF00D, version = 0, timestamp_unit = timestamp_unit, must_be_0 = 0}
	header_bytes := transmute([size_of(BinHeader)]u8)header
	append(&buf, ..header_bytes[:])

	for event in trace.traceEvents {
		name_len := min(len(event.name), 255)
		name     := event.name[:name_len]

		if (event.ph == "B") {
			begin := BeginEvent {
				type = .Begin,
				pid  = event.pid,
				tid  = event.tid,
				time = event.ts,
				name_len = u8(name_len),
 			}
			begin_bytes := transmute([size_of(BeginEvent)]u8)begin
			append(&buf, ..begin_bytes[:])
			append(&buf, name)
		}

		if (event.ph == "E") {
			end := EndEvent {
				type = .End,
				pid  = event.pid,
				tid  = event.tid,
				time = event.ts,
			}
			end_bytes := transmute([size_of(EndEvent)]u8)end
			append(&buf, ..end_bytes[:])
		}
	}

	out_file, _ := strings.replace(os.args[1], ".json", ".flint", 1)

	if os.write_entire_file(out_file, buf[:]) {
		fmt.printf("Done, wrote %v events to %v (%v bytes)\n", len(trace.traceEvents), out_file, len(buf))
	} else {
		fmt.eprintf("Problem writing to %v\n", out_file)
		os.exit(1)
	}
}