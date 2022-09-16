package main

import "core:fmt"
import "core:os"

main :: proc() {
	json_fd, err := os.open("test_DUMP.json", os.O_WRONLY | os.O_CREATE, 0o644)
	if err != 0 {
		fmt.printf("failed to open file: %s\n", err)
	}

	fmt.fprintf(json_fd, "{{\n\t\"traceEvents\": [\n")

	//size := 100
	//size := 12_000_000
	size := 1000
	ts_count := 0
	for i := 0; i < size; i += 1 {
		fmt.fprintf(json_fd, "\t\t{{\"cat\":\"function\", \"dur\":1, \"name\":\"foo\", \"ph\":\"X\", \"pid\":0, \"tid\": 0, \"ts\": %d}}", ts_count)

		if (i + 1) != size {
			fmt.fprintf(json_fd, ",\n")
		}

		ts_count += 1
	}
	fmt.fprintf(json_fd, "\n\t]\n}}")
}
