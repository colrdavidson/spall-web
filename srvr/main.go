package main

import (
	"log"
	"net"
	"net/http"
	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{}

var read_offset = 0
var write_offset = 0

func handle_connection(conn net.Conn, buffer *[]byte) {
	defer log.Printf("closing stream!\n")
	defer func() {socket_count -= 1}()
	defer conn.Close()

	log.Printf("New stream started!\n")	

	chunk := [1 * 1024 * 1024]byte{}
	bl, err := conn.Read(chunk[:])
	if err != nil {
		log.Printf("Failed to read! %s\n", err)
		return
	}

	log.Printf("Got %d bytes\n", bl)

	write_chunk := chunk[0:bl]
	*buffer = append(*buffer, write_chunk...)
	read_offset = len(*buffer)
}

var socket_count = 0
var ingest_port = ":8080"
var server_port = ":8000"
func main() {
	buffer := make([]byte, 0, 1 * 1024 * 1024)

	http.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		ws, err := upgrader.Upgrade(w, r, nil)
		if err != nil {
			log.Printf("upgrade failed: ", err)
			return
		}
		defer ws.Close()
		defer func() { write_offset = 0; }()
		log.Printf("ws opened\n")

		for {
			_, data, err := ws.ReadMessage()
			if err != nil {
				log.Print("ws read failed:", err)
				break
			}

			log.Printf("Got %s from frontend\n", string(data))

			cmd := string(data)
			switch cmd {
			case "start":
				write_offset = 0
			default:
				continue
			}

			if write_offset == read_offset {
				continue
			}

			message := buffer[write_offset:read_offset]
			log.Printf("Sending %d bytes to frontend!\n", len(message))
			//log.Printf("%s\n", string(message))

			err = ws.WriteMessage(websocket.BinaryMessage, message)
			if err != nil {
				log.Printf("ws write failed:", err)
				break
			}

			write_offset += len(message)
		}

		log.Printf("ws closed\n")
	})

	fs := http.FileServer(http.Dir("./dist"))
	http.Handle("/", fs)

	go func() {
		log.Printf("Spinning up server on %s", server_port)
		err := http.ListenAndServe(server_port, nil)
		if err != nil {
			log.Fatal(err)
		}
	}()

	ln, err := net.Listen("tcp", ingest_port)
	if err != nil {
		log.Printf("listen on %s failed\n", ingest_port)
		return
	}
	log.Printf("Listening for profile events on %s", ingest_port)

	for {
		conn, err := ln.Accept()
		if err != nil {
			log.Printf("accept failed?\n")
			return
		}
		if socket_count > 0 {
			conn.Close()
			continue
		}

		socket_count += 1
		go handle_connection(conn, &buffer)
	}
}
