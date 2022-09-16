package main

import (
	"log"
	"os"
	"net"
)

func main() {
	if len(os.Args) != 2 {
		log.Fatalf("Expected %s <name_of_file>\n", os.Args[0])
	}

	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}

	conn, err := net.Dial("tcp", ":8080")
	if err != nil {
		panic(err)
	}

	r, err := conn.Write(data)
	if err != nil {
		panic(err)
	}

	if r != len(data) {
		log.Fatal("Failed to send all bytes!\n")
	}
}
