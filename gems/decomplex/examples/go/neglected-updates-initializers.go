package main

type TaskConfig struct {
    stack_size int
    timeout int
}

type ServerConfig struct {
    port int
    timeout int
}

func setup_task1() {
    _ = TaskConfig{stack_size: 1024, timeout: 10}
}

func setup_task2() {
    _ = TaskConfig{stack_size: 2048, timeout: 20}
}

func setup_task3() {
    _ = TaskConfig{stack_size: 4096, timeout: 30}
}

func setup_server() {
    _ = ServerConfig{port: 8080, timeout: 30}
}

func partial_setup() {
    // Missing timeout, should be flagged as neglected-update on TaskConfig, 
    // but without normalization it would be conflated with ServerConfig due to .literal god-class.
    _ = TaskConfig{stack_size: 1024}
}
