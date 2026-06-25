public class TaskConfig {
    public int stack_size { get; set; }
    public int timeout { get; set; }
}

public class ServerConfig {
    public int port { get; set; }
    public int timeout { get; set; }
}

public class Test {
    public static void setup_task1() {
        var c = new TaskConfig { stack_size = 1024, timeout = 10 };
    }

    public static void setup_task2() {
        var c = new TaskConfig { stack_size = 2048, timeout = 20 };
    }

    public static void setup_task3() {
        var c = new TaskConfig { stack_size = 4096, timeout = 30 };
    }

    public static void setup_server() {
        var c = new ServerConfig { port = 8080, timeout = 30 };
    }

    public static void partial_setup() {
        // Missing timeout, should be flagged as neglected-update on TaskConfig.
        // Without normalization, it gets conflated with ServerConfig's literal initialization.
        var c = new TaskConfig { stack_size = 1024 };
    }
}
