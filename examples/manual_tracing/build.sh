clang -O3 hello_world_example.c -o hello

case "$(uname -sr)" in
	Linux*)
		clang -O3 advanced_threads_example_linux.c -o advanced_example
		;;
esac
