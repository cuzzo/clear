use std::fs;

// O(N): each file is read once, so the reads sum to the total input.
pub fn total_len(paths: &[String]) -> usize {
    let mut total = 0;
    for path in paths {
        total += fs::read(path).map(|bytes| bytes.len()).unwrap_or(0);
    }
    total
}
