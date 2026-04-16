use std::time::Instant;

fn fib(n: i64) -> i64 {
    if n <= 1 {
        return n;
    }
    fib(n - 1) + fib(n - 2)
}

fn main() {
    let start = Instant::now();
    let result = fib(40);
    assert_eq!(result, 102334155);
    let duration = start.elapsed();

    // BENCH_RESULT = elapsed ms
    println!("BENCH_RESULT: {} ms", duration.as_millis());
    println!("Fib(40) = {}", result);
    println!("Time: {:.4} seconds", duration.as_secs_f64());
}
