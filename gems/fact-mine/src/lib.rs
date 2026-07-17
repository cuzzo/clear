#![recursion_limit = "256"]

#[cfg(test)]
mod architecture_test;
mod ast;
pub mod external_summary;
pub mod lsp_scip;
pub mod lua_scip;
pub mod parallel;
pub mod profile;
pub mod scip;
pub mod syntax;
pub mod syntax_oracle;
pub mod type_inference;

pub mod test_helpers {
    pub fn run_all() {
        crate::ast::run_ast_helpers_tests();
        crate::ast::run_base_adapter_defaults_tests();
        crate::ast::run_normalizer_uncovered_paths_tests();
        crate::profile::run_profile_tests();
    }
}
