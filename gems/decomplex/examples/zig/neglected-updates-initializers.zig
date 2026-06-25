const TaskConfig = struct {
    stack_size: u32,
    timeout: u32,
};

const ServerConfig = struct {
    port: u32,
    timeout: u32,
};

pub fn setup_task1() void {
    const c = TaskConfig{ .stack_size = 1024, .timeout = 10 };
    _ = c;
}

pub fn setup_task2() void {
    const c = TaskConfig{ .stack_size = 2048, .timeout = 20 };
    _ = c;
}

pub fn setup_task3() void {
    const c = TaskConfig{ .stack_size = 4096, .timeout = 30 };
    _ = c;
}

pub fn setup_server() void {
    const c = ServerConfig{ .port = 8080, .timeout = 30 };
    _ = c;
}

pub fn partial_setup() void {
    // Missing timeout, should be flagged as neglected-update on TaskConfig.
    // Without normalization, it gets conflated with ServerConfig's literal initialization.
    const c = TaskConfig{ .stack_size = 1024 };
    _ = c;
}
