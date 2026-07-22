//! The canonical, dependency-free hazard contract.
//!
//! Consumers parse `CONTRACT_JSON` with their native data model.  Keeping the
//! data in one resource crate means scanners do not have to depend on one
//! another's parser or Tree-sitter versions, while the query text is still
//! shared byte-for-byte.

pub const CONTRACT_JSON: &str = include_str!("../contract.json");

pub const C_HAZARDS: &str = include_str!("../queries/c_hazards.scm");
pub const CPP_HAZARDS: &str = include_str!("../queries/cpp_hazards.scm");
pub const CSHARP_HAZARDS: &str = include_str!("../queries/csharp_hazards.scm");
pub const GO_HAZARDS: &str = include_str!("../queries/go_hazards.scm");
pub const RUST_HAZARDS: &str = include_str!("../queries/rust_hazards.scm");
pub const ZIG_HAZARDS: &str = include_str!("../queries/zig_hazards.scm");
pub const RUBY_HAZARDS: &str = include_str!("../queries/ruby_hazards.scm");
pub const PYTHON_HAZARDS: &str = include_str!("../queries/python_hazards.scm");
pub const JAVASCRIPT_HAZARDS: &str = include_str!("../queries/javascript_hazards.scm");
pub const TYPESCRIPT_HAZARDS: &str = include_str!("../queries/typescript_hazards.scm");
pub const LUA_HAZARDS: &str = include_str!("../queries/lua_hazards.scm");
pub const JAVA_HAZARDS: &str = include_str!("../queries/java_hazards.scm");
pub const PHP_HAZARDS: &str = include_str!("../queries/php_hazards.scm");
pub const KOTLIN_HAZARDS: &str = include_str!("../queries/kotlin_hazards.scm");
pub const SWIFT_HAZARDS: &str = include_str!("../queries/swift_hazards.scm");
