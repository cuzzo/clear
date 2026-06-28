package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io/ioutil"
	"os"
	"os/exec"
	"sync"
	"time"
)

type Input struct {
	Prefix     string   `json:"prefix"`
	Assertions []string `json:"assertions"`
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintf(os.Stderr, "Usage: %s <input.json>\n", os.Args[0])
		os.Exit(1)
	}

	data, err := ioutil.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintf(os.Stderr, "Failed to read input: %v\n", err)
		os.Exit(1)
	}

	var input Input
	if err := json.Unmarshal(data, &input); err != nil {
		fmt.Fprintf(os.Stderr, "Failed to parse input: %v\n", err)
		os.Exit(1)
	}

	fmt.Fprintf(os.Stderr, "Starting parallel Z3 cleaner with %d assertions...\n", len(input.Assertions))

	clean := filterAssertions(input.Prefix, input.Assertions)
	if clean == nil {
		clean = []string{}
	}

	outBytes, _ := json.Marshal(clean)
	fmt.Println(string(outBytes))
}

func checkSAT(prefix string, assertions []string) bool {
	var buf bytes.Buffer
	buf.WriteString(prefix)
	buf.WriteString("\n")
	for _, a := range assertions {
		buf.WriteString("(assert ")
		buf.WriteString(a)
		buf.WriteString(")\n")
	}
	buf.WriteString("(check-sat)\n")

	cmd := exec.Command("z3", "-smt2", "-in", "-t:5000")
	cmd.Stdin = &buf
	var out bytes.Buffer
	cmd.Stdout = &out
	err := cmd.Run()
	if err != nil {
		return false
	}

	res := bytes.TrimSpace(out.Bytes())
	return bytes.HasPrefix(res, []byte("sat"))
}

func filterAssertions(prefix string, assertions []string) []string {
	if len(assertions) == 0 {
		return []string{}
	}

	var mu sync.Mutex
	var clean []string

	var queueMu sync.Mutex
	queue := [][]string{assertions}
	activeTasks := 1

	numWorkers := 32
	var wg sync.WaitGroup

	for i := 0; i < numWorkers; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			for {
				var items []string

				queueMu.Lock()
				if len(queue) > 0 {
					items = queue[len(queue)-1]
					queue = queue[:len(queue)-1]
				}
				queueMu.Unlock()

				if items == nil {
					queueMu.Lock()
					allDone := (activeTasks == 0)
					queueMu.Unlock()
					if allDone {
						return
					}
					time.Sleep(1 * time.Millisecond)
					continue
				}

				if checkSAT(prefix, items) {
					mu.Lock()
					clean = append(clean, items...)
					mu.Unlock()

					queueMu.Lock()
					activeTasks--
					queueMu.Unlock()
				} else {
					if len(items) == 1 {
						queueMu.Lock()
						activeTasks--
						queueMu.Unlock()
						continue
					}

					mid := len(items) / 2
					queueMu.Lock()
					activeTasks++
					queue = append(queue, items[:mid], items[mid:])
					queueMu.Unlock()
				}
			}
		}()
	}

	wg.Wait()
	if clean == nil {
		return []string{}
	}
	return clean
}
