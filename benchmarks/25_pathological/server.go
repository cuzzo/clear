package main

import (
	"bufio"
	"crypto/sha256"
	"fmt"
	"net"
	"strconv"
	"strings"
)

// hashN computes SHA256 iterated n times on seed, returns first 8 bytes as hex.
func hashN(seed string, n int) string {
	buf := sha256.Sum256([]byte(seed))
	for i := 1; i < n; i++ {
		buf = sha256.Sum256(buf[:])
	}
	return fmt.Sprintf("%x", buf[:8])
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
			result := hashN("seed:"+id, n)
			fmt.Fprintf(writer, ":%s\r\n", result)
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
	fmt.Println("Go pathological server listening on port 6391")

	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleClient(conn)
	}
}
