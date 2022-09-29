rm test_DUMP.json test_DUMP.spall
odin build main.odin -file -collection:formats='../../formats' -o:speed -out:gentrace
