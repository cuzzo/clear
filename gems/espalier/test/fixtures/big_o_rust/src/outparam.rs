use std::path::PathBuf;

fn collect(root: &str, files: &mut Vec<PathBuf>) {
    files.push(PathBuf::from(root));
}

// O(N): each collected path is stripped once.
pub fn digest(root: &str) -> usize {
    let mut files = Vec::new();
    collect(root, &mut files);
    let mut total = 0;
    for file in files {
        total += file.strip_prefix(root).map(|rest| rest.components().count()).unwrap_or(0);
    }
    total
}
