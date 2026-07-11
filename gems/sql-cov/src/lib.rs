pub mod driver;
pub mod hazard;
pub mod instrument;
pub mod model;
pub mod parser;
pub mod reporter;
pub mod sarif;
pub mod schema;

pub use driver::{
    cover_mysql, cover_postgres, cover_sqlite, execute_mysql_setup, execute_postgres_setup,
    execute_sqlite_setup,
};
pub use hazard::{analyze_hazards, HazardFinding, HazardKind, HazardReport};
pub use model::{CoverageMetric, SourceFileCoverage, ThreeValuedLogicState};
pub use parser::{analyze_sql, DialectName};
