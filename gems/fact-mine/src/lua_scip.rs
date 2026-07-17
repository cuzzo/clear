//! Lua SCIP production through LuaLS.
//!
//! Lua has no maintained native SCIP indexer. This adapter confines Lua-owned
//! standard-library identity and descriptor spelling here, while the reusable
//! LSP transport and SCIP construction live in `lsp_scip`.

use crate::lsp_scip::{self, GeneratedIndex, LspScipAdapter};
use crate::profile::CallRecord;
use crate::syntax::Language;
use anyhow::Result;
use serde_json::{json, Value};
use std::path::{Component, Path, PathBuf};

struct LuaLspScipAdapter;

impl LspScipAdapter for LuaLspScipAdapter {
    fn language(&self) -> Language {
        Language::Lua
    }

    fn language_id(&self) -> &'static str {
        "lua"
    }

    fn scheme(&self) -> &'static str {
        "scip-lua"
    }

    fn package_manager(&self) -> &'static str {
        "luarocks"
    }

    fn is_stdlib_definition(&self, path: &Path) -> bool {
        let components = path
            .components()
            .filter_map(|component| match component {
                Component::Normal(value) => value.to_str(),
                _ => None,
            })
            .collect::<Vec<_>>();
        components.windows(2).any(|pair| {
            pair[0] == "meta" && (pair[1].starts_with("Lua ") || pair[1].starts_with("LuaJIT "))
        })
    }

    fn external_descriptor(
        &self,
        call: &CallRecord,
        definition_path: &Path,
        definition_source: &str,
        definition_range: [usize; 4],
    ) -> String {
        if self.is_stdlib_definition(definition_path) {
            let declared = lua_function_name_at(definition_source, definition_range[0]);
            let message = declared.as_deref().unwrap_or(&call.message);
            if let Some(module) = lua_core_module(definition_path) {
                return format!(
                    "{}/{}().",
                    lsp_scip::scip_path(&module),
                    lsp_scip::scip_atom(message)
                );
            }
            return format!("{}().", lsp_scip::scip_atom(message));
        }
        let receiver = call.receiver.trim().trim_start_matches("_G.");
        if receiver.is_empty() || receiver == "self" {
            format!("{}().", lsp_scip::scip_atom(&call.message))
        } else {
            format!(
                "{}/{}().",
                lsp_scip::scip_path(receiver),
                lsp_scip::scip_atom(&call.message)
            )
        }
    }

    fn stdlib_package(&self) -> &'static str {
        "lua"
    }

    fn workspace_settings(&self) -> Value {
        json!({"Lua": {
            "workspace": {"checkThirdParty": false},
            "telemetry": {"enable": false}
        }})
    }
}

fn lua_function_name_at(source: &str, line: usize) -> Option<String> {
    let declaration = source.lines().nth(line)?.trim();
    let callable = declaration
        .strip_prefix("function ")?
        .split('(')
        .next()?
        .trim();
    let name = callable
        .rsplit(['.', ':'])
        .find(|part| !part.is_empty())?;
    (!name.is_empty()
        && name
            .chars()
            .all(|character| character == '_' || character.is_alphanumeric()))
    .then(|| name.to_string())
}

fn lua_core_module(path: &Path) -> Option<String> {
    let components = path
        .components()
        .filter_map(|component| match component {
            Component::Normal(value) => value.to_str().map(str::to_string),
            _ => None,
        })
        .collect::<Vec<_>>();
    let marker = components
        .iter()
        .position(|component| component.starts_with("Lua ") || component.starts_with("LuaJIT "))?;
    let mut module = components.get(marker + 1..)?.to_vec();
    let last = module.last_mut()?;
    *last = last.strip_suffix(".lua").unwrap_or(last).to_string();
    let module = module.join(".");
    (!matches!(module.as_str(), "basic" | "builtin")).then_some(module)
}

pub fn generate(
    files: &[PathBuf],
    root: Option<&Path>,
    server: Option<&Path>,
) -> Result<GeneratedIndex> {
    let server = server
        .map(PathBuf::from)
        .or_else(|| std::env::var_os("LUA_LANGUAGE_SERVER").map(PathBuf::from))
        .unwrap_or_else(|| PathBuf::from("lua-language-server"));
    lsp_scip::generate(files, root, &server, &LuaLspScipAdapter)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lua_dialect_classifies_only_luals_core_meta_as_stdlib() {
        let adapter = LuaLspScipAdapter;
        assert!(
            adapter.is_stdlib_definition(Path::new("/opt/luals/meta/Lua 5.4 en-us utf8/basic.lua"))
        );
        assert!(!adapter.is_stdlib_definition(Path::new("/workspace/vendor/meta/custom.lua")));
        assert_eq!(
            lua_core_module(Path::new(
                "/opt/luals/meta/Lua 5.4 en-us utf8/table/new.lua"
            ))
            .as_deref(),
            Some("table.new")
        );
        assert_eq!(
            lua_core_module(Path::new("/opt/luals/meta/Lua 5.4 en-us utf8/basic.lua")),
            None
        );
        assert_eq!(
            lua_function_name_at("---@param value any\nfunction table.insert(value) end\n", 1)
                .as_deref(),
            Some("insert")
        );
    }
}
