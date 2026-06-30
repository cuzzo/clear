mod actions;
mod schemas;

use actions::build_actions;
use anyhow::{Context, Result};
use schemas::{InputState, OutputState};
use std::env;
use std::fs;

fn main() -> Result<()> {
    let args: Vec<String> = env::args().collect();
    if args.len() != 3 {
        eprintln!("Usage: nil-kill-infer-rust <input.json> <output.json>");
        std::process::exit(1);
    }

    let input_path = &args[1];
    let output_path = &args[2];

    let input_data = fs::read_to_string(input_path)
        .with_context(|| format!("Failed to read input file: {}", input_path))?;
    
    let input_state: InputState = serde_json::from_str(&input_data)
        .with_context(|| "Failed to parse input JSON")?;

    let output_state = OutputState {
        actions: build_actions(&input_state),
        diagnostics: std::collections::HashMap::new(),
    };

    let output_data = serde_json::to_string_pretty(&output_state)?;
    fs::write(output_path, output_data)
        .with_context(|| format!("Failed to write output file: {}", output_path))?;

    Ok(())
}
