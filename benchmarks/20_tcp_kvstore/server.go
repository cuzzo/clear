// TCP KV Store — Go baseline
//
// Minimal RESP-compatible GET/SET/INCR server using sync.Map.
// One goroutine per connection. Supports pipelining.

package main

import (
	"bufio"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
	"sync"
)

var (
	store    sync.Map
	counters sync.Map
	counterMu sync.Mutex
)

func handleClient(conn net.Conn) {
	defer conn.Close()
	reader := bufio.NewReader(conn)
	for {
		line, err := reader.ReadString('\n')
		if err != nil {
			return
		}
		line = strings.TrimRight(line, "\r\n")
		if len(line) == 0 {
			continue
		}

		if line[0] == '*' {
			// RESP array
			argCount, _ := strconv.Atoi(line[1:])
			args := make([]string, 0, argCount)
			for i := 0; i < argCount; i++ {
				hdr, err := reader.ReadString('\n')
				if err != nil {
					return
				}
				hdr = strings.TrimRight(hdr, "\r\n")
				if len(hdr) == 0 || hdr[0] != '$' {
					continue
				}
				n, _ := strconv.Atoi(hdr[1:])
				buf := make([]byte, n+2)
				reader.Read(buf)
				args = append(args, string(buf[:n]))
			}
			if len(args) == 0 {
				continue
			}
			cmd := strings.ToUpper(args[0])
			switch cmd {
			case "SET":
				if len(args) >= 3 {
					store.Store(args[1], args[2])
					fmt.Fprint(conn, "+OK\r\n")
				}
			case "GET":
				if len(args) >= 2 {
					v, ok := store.Load(args[1])
					if ok {
						s := v.(string)
						fmt.Fprintf(conn, "$%d\r\n%s\r\n", len(s), s)
					} else {
						fmt.Fprint(conn, "$-1\r\n")
					}
				}
			case "INCR":
				if len(args) >= 2 {
					counterMu.Lock()
					v, _ := counters.Load(args[1])
					n := int64(0)
					if v != nil {
						n = v.(int64)
					}
					n++
					counters.Store(args[1], n)
					counterMu.Unlock()
					fmt.Fprintf(conn, ":%d\r\n", n)
				}
			case "DECR":
				if len(args) >= 2 {
					counterMu.Lock()
					v, _ := counters.Load(args[1])
					n := int64(0)
					if v != nil {
						n = v.(int64)
					}
					n--
					counters.Store(args[1], n)
					counterMu.Unlock()
					fmt.Fprintf(conn, ":%d\r\n", n)
				}
			case "PING":
				fmt.Fprint(conn, "+PONG\r\n")
			case "COMMAND":
				fmt.Fprint(conn, "*0\r\n")
			case "QUIT":
				fmt.Fprint(conn, "+OK\r\n")
				return
			default:
				fmt.Fprintf(conn, "-ERR unknown command '%s'\r\n", args[0])
			}
		} else {
			// Inline command
			cmd := strings.TrimSpace(line)
			switch strings.ToUpper(cmd) {
			case "PING":
				fmt.Fprint(conn, "+PONG\r\n")
			case "READY?":
				fmt.Fprint(conn, "+READY\r\n")
			case "QUIT":
				fmt.Fprint(conn, "+OK\r\n")
				return
			default:
				fmt.Fprintf(conn, "-ERR unknown command '%s'\r\n", cmd)
			}
		}
	}
}

func main() {
	ln, err := net.Listen("tcp", ":6390")
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Go kvstore listening on port 6390")
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleClient(conn)
	}
}
