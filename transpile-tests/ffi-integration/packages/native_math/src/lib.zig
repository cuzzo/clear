// Native Zig math library for CLEAR FFI integration test.
// These functions use f64 (CLEAR's Number type) and have no runtime parameter.

pub fn native_add(a: f64, b: f64) f64 {
    return a + b;
}

pub fn native_multiply(a: f64, b: f64) f64 {
    return a * b;
}

pub fn native_clamp(val: f64, min: f64, max: f64) f64 {
    if (val < min) return min;
    if (val > max) return max;
    return val;
}

pub fn native_abs(val: f64) f64 {
    return if (val < 0) -val else val;
}
