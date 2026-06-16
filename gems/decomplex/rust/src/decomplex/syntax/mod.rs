pub mod ruby;

use serde::Serialize;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
pub struct StateWrite {
    pub field: String,
    pub receiver: String,
    pub file: String,
    pub function: String,
    pub line: usize,
    pub span: [usize; 4],
    pub owner: String,
}
