use std::time::Instant;

fn fib(n: i64) -> i64 {
    if n <= 1 {
        return n;
    }
    fib(n - 1) + fib(n - 2)
}

fn main() {
    let start = Instant::now();
    let result = fib(35);
    assert_eq!(result, 9227465);
    let duration = start.elapsed();

    println!("Fib(35) = {}", result);
    println!("Time: {:.4} seconds", duration.as_secs_f64());
}
