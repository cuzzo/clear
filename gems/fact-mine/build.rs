use std::env;
use std::fs;
use std::path::PathBuf;

fn main() {
    let manifest_dir = PathBuf::from(env::var_os("CARGO_MANIFEST_DIR").unwrap());
    let protocol_dir = manifest_dir.join("../../protocol/runtime-evidence/v1");
    let protocol = protocol_dir.join("runtime_evidence.proto");
    println!("cargo:rerun-if-changed={}", protocol.display());
    protobuf_codegen::Codegen::new()
        .pure()
        .includes([&protocol_dir])
        .input(&protocol)
        .cargo_out_dir("runtime_evidence_protocol")
        .run_from_script();
    let generated_protocol = PathBuf::from(env::var_os("OUT_DIR").unwrap())
        .join("runtime_evidence_protocol/runtime_evidence.rs");
    let embedded_protocol = PathBuf::from(env::var_os("OUT_DIR").unwrap())
        .join("runtime_evidence_protocol_embedded.rs");
    let generated_source = fs::read_to_string(&generated_protocol).unwrap();
    let embedded_source = generated_source
        .lines()
        .filter(|line| !line.starts_with("#![") && !line.starts_with("//!"))
        .collect::<Vec<_>>()
        .join("\n");
    fs::write(embedded_protocol, embedded_source).unwrap();

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
