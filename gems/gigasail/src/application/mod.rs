//! Application services used by Gigasail's CLI, UI, and future API clients.
//!
//! These modules own policy and state transitions. Command-line code should
//! only translate flags to requests and render the returned results.

pub mod affected;
pub mod analyse;
pub mod checks;
pub mod time_tests;
pub mod ci;
pub mod diff;
pub mod ingest;
pub mod revision;
pub mod test;
