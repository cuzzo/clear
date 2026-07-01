// Benchmark 24: TCP JSON File Server — Go
//
// Same protocol as server.clear. Uses encoding/json for parsing.

package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"strconv"
	"strings"
)

func sizeForId(id int64) int64 {
	return ((id*7 + 13) % 997) + 10
}

func generateJson(id int64) []byte {
	sz := sizeForId(id)
	data := make([]int64, sz)
	for i := int64(0); i < sz; i++ {
		data[i] = i + 1
	}
	type Doc struct {
		ID   int64   `json:"id"`
		Data []int64 `json:"data"`
	}
	b, _ := json.Marshal(Doc{ID: id, Data: data})
	return b
}

type Doc struct {
	ID   int64   `json:"id"`
	Data []int64 `json:"data"`
}

func parseAndSum(content []byte) int64 {
	var doc Doc
	if err := json.Unmarshal(content, &doc); err != nil {
		return 0
	}
	var sum int64
	for _, v := range doc.Data {
		sum += v
	}
	return sum
}

func handleClient(conn net.Conn) {
	defer conn.Close()
	scanner := bufio.NewScanner(conn)
	for scanner.Scan() {
		line := scanner.Text()
		if len(line) == 0 {
			continue
		}

		if strings.HasPrefix(line, "SET:") {
			idStr := line[4:]
			id, _ := strconv.ParseInt(idStr, 10, 64)
			data := generateJson(id)
			path := fmt.Sprintf("data/%d.json", id)
			os.WriteFile(path, data, 0644)
			fmt.Fprintf(conn, "+OK\r\n")
		} else if strings.HasPrefix(line, "GET:") {
			idStr := line[4:]
			id, _ := strconv.ParseInt(idStr, 10, 64)
			path := fmt.Sprintf("data/%d.json", id)
			content, err := os.ReadFile(path)
			if err != nil {
				fmt.Fprintf(conn, "-ERR file not found\r\n")
				continue
			}
			sum := parseAndSum(content)
			fmt.Fprintf(conn, ":%d\r\n", sum)
		} else if line == "QUIT" {
			fmt.Fprintf(conn, "+OK\r\n")
			return
		} else if line == "READY?" {
			fmt.Fprintf(conn, "+READY\r\n")
		} else {
			fmt.Fprintf(conn, "-ERR unknown command\r\n")
		}
	}
}

func main() {
	os.MkdirAll("data", 0755)
	ln, err := net.Listen("tcp", ":6390")
	if err != nil {
		fmt.Fprintf(os.Stderr, "listen error: %v\n", err)
		os.Exit(1)
	}
	fmt.Println("Go json-api listening on port 6390")
	for {
		conn, err := ln.Accept()
		if err != nil {
			continue
		}
		go handleClient(conn)
	}
}
