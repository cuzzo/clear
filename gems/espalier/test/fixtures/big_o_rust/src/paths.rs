use std::path::PathBuf;

// O(N): each path is stripped once, so the strips sum to the input.
pub fn strip_paths(paths: &[PathBuf], root: &str) -> usize {
    let mut total = 0;
    for path in paths {
        total += path.strip_prefix(root).map(|rest| rest.components().count()).unwrap_or(0);
    }
    total
}
