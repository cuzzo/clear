use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let summary_dir = manifest_dir.join("config/complexity_summaries");
    println!("cargo:rerun-if-changed={}", summary_dir.display());

    let mut summaries = fs::read_dir(&summary_dir)
        .unwrap()
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.to_string_lossy().ends_with(".json.gz"))
        .collect::<Vec<_>>();
    summaries.sort();

    let mut generated = String::from("const BUNDLED_SUMMARIES: &[(&str, &[u8])] = &[\n");
    for path in summaries {
        let name = path.file_name().unwrap().to_string_lossy();
        generated.push_str(&format!(
            "    ({name:?}, include_bytes!(concat!(env!(\"CARGO_MANIFEST_DIR\"), \"/config/complexity_summaries/\", {name:?}))),\n"
        ));
    }
    generated.push_str("];\n");

    let output =
        PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("bundled_complexity_summaries.rs");
    fs::write(output, generated).unwrap();
}
