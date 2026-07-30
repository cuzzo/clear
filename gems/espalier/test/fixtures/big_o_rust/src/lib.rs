// O(N): each file's name is scanned once, so the strips sum to the input.
pub fn strip_each(files: &[String], root: &str) -> usize {
    let mut total = 0;
    for file in files {
        total += file.strip_prefix(root).unwrap_or(file).len();
    }
    total
}

// O(N): appending each name copies that name, summing to the input.
pub fn join_each(files: &[String]) -> String {
    let mut out = String::new();
    for file in files {
        out.push_str(file);
    }
    out
}

// O(N^2): every iteration scans the whole accumulated buffer.
pub fn scan_accumulated(files: &[String]) -> usize {
    let mut seen = String::new();
    let mut hits = 0;
    for file in files {
        if seen.contains(file.as_str()) {
            hits += 1;
        }
        seen.push_str(file);
    }
    hits
}
