#[path = "../decomplex/mod.rs"]
mod decomplex;

use anyhow::{bail, Result};
use decomplex::ast::{self, Child, Node};
use decomplex::syntax::Language;
use serde_json::{json, Value};
use std::env;
use std::fs;
use std::path::PathBuf;
use tree_sitter::{Language as TreeSitterLanguage, Parser};

fn main() -> Result<()> {
    let mut args = env::args().skip(1).collect::<Vec<_>>();
    let raw = args.first().map(|arg| arg == "--raw").unwrap_or(false);
    if raw {
        args.remove(0);
    }
    let mut args = args.into_iter();
    let language = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: dump_ast [--raw] LANGUAGE FILE"))?;
    let file = args
        .next()
        .ok_or_else(|| anyhow::anyhow!("usage: dump_ast [--raw] LANGUAGE FILE"))?;
    if args.next().is_some() {
        bail!("usage: dump_ast [--raw] LANGUAGE FILE");
    }

    let language = Language::parse(&language)?;
    let file = PathBuf::from(file);
    if raw {
        let source = fs::read_to_string(&file)?;
        let mut parser = Parser::new();
        parser.set_language(&language_grammar(language))?;
        let tree = parser
            .parse(&source, None)
            .ok_or_else(|| anyhow::anyhow!("tree-sitter produced no tree"))?;
        println!(
            "{}",
            serde_json::to_string(&raw_node_value(tree.root_node(), &source))?
        );
    } else {
        let (root, _lines) = ast::parse_with_language(&file, language)?;
        println!("{}", serde_json::to_string(&node_value(&root))?);
    }
    Ok(())
}

fn node_value(node: &Node) -> Value {
    json!({
        "type": node.r#type,
        "children": node.children.iter().map(child_value).collect::<Vec<_>>(),
        "first_lineno": node.first_lineno,
        "first_column": node.first_column,
        "last_lineno": node.last_lineno,
        "last_column": node.last_column,
        "text": node.text,
    })
}

fn child_value(child: &Child) -> Value {
    match child {
        Child::Node(node) => node_value(node),
        Child::Symbol(value) | Child::String(value) => Value::String(value.clone()),
        Child::Integer(value) => Value::Number((*value).into()),
        Child::Bool(value) => Value::Bool(*value),
        Child::Nil => Value::Null,
    }
}

fn raw_node_value(node: tree_sitter::Node<'_>, source: &str) -> Value {
    let mut cursor = node.walk();
    json!({
        "kind": node.kind(),
        "named": node.is_named(),
        "start_byte": node.start_byte(),
        "end_byte": node.end_byte(),
        "start": {"row": node.start_position().row, "column": node.start_position().column},
        "end": {"row": node.end_position().row, "column": node.end_position().column},
        "text": node.utf8_text(source.as_bytes()).unwrap_or(""),
        "children": node.children(&mut cursor).map(|child| raw_node_value(child, source)).collect::<Vec<_>>(),
    })
}

fn language_grammar(language: Language) -> TreeSitterLanguage {
    match language {
        Language::Ruby => tree_sitter_ruby::LANGUAGE.into(),
        Language::Python => tree_sitter_python::LANGUAGE.into(),
        Language::JavaScript => tree_sitter_javascript::LANGUAGE.into(),
        Language::Java => tree_sitter_java::LANGUAGE.into(),
        Language::TypeScript => tree_sitter_typescript::LANGUAGE_TYPESCRIPT.into(),
        Language::Swift => tree_sitter_swift::LANGUAGE.into(),
        Language::Kotlin => tree_sitter_kotlin_ng::LANGUAGE.into(),
        Language::Go => tree_sitter_go::LANGUAGE.into(),
        Language::Rust => tree_sitter_rust::LANGUAGE.into(),
        Language::Zig => tree_sitter_zig::LANGUAGE.into(),
        Language::Lua => tree_sitter_lua::LANGUAGE.into(),
        Language::C => tree_sitter_c::LANGUAGE.into(),
        Language::Cpp => tree_sitter_cpp::LANGUAGE.into(),
        Language::CSharp => tree_sitter_c_sharp::LANGUAGE.into(),
    }
}
