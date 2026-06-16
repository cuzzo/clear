use crate::decomplex::syntax::{ruby, StateWrite};
use anyhow::Result;
use std::path::PathBuf;

pub fn state_writes_for_files(files: &[PathBuf]) -> Result<Vec<StateWrite>> {
    let mut facts = Vec::new();
    for file in files {
        facts.extend(ruby::state_writes_for_file(file)?);
    }
    Ok(facts)
}
