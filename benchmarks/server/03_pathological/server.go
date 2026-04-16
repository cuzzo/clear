package main

import (
	"bufio"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// heavyCompute does N iterations of integer math. Pure compute, no crypto.
func heavyCompute(seed int64, n int) int64 {
	x := seed
	for i := 0; i < n; i++ {
		x = x*6364136223846793005 + 1442695040888963407
		x = x*x + 1
	}
	if x < 0 {
		x = -x
	}
	return x % 1000000000
}

func handleClient(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	writer := bufio.NewWriter(conn)

	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" {
			continue
		}

		if strings.HasPrefix(line, "WORK:") {
			parts := strings.SplitN(line[5:], ":", 2)
			id := parts[0]
			n, _ := strconv.Atoi(parts[1])
			if n < 1 {
				n = 1
			}
			idNum, _ := strconv.ParseInt(id, 10, 64)
			result := heavyCompute(idNum, n)
			fmt.Fprintf(writer, ":%d\r\n", result)
			writer.Flush()
		} else if line == "QUIT" {
			fmt.Fprintf(writer, "+OK\r\n")
			writer.Flush()
			return
		} else if line == "READY?" {
			fmt.Fprintf(writer, "+READY\r\n")
			writer.Flush()
		} else {
			fmt.Fprintf(writer, "-ERR unknown command\r\n")
			writer.Flush()
		}
	}
}

func main() {
	ln, err := net.Listen("tcp", ":6390")
	if err != nil {
		fmt.Printf("listen error: %v\n", err)
		return
	}
	defer ln.Close()
	fmt.Println("Go pathological server listening on port 6390")

	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleClient(conn)
	}
}
