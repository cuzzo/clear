use super::{parse, parse_with_language, Child, Node};
use crate::syntax::Language;
use serde_json::{json, Value};
use std::collections::BTreeSet;
use std::io::Write;
use std::path::Path;
use std::process::Command;
use tree_sitter::{Node as TreeSitterNode, Parser as TreeSitterParser};

fn parse_source(source: &str) -> Node {
    let mut file = tempfile::Builder::new()
        .suffix(".rb")
        .tempfile()
        .expect("create temp ruby file");
    file.write_all(source.as_bytes())
        .expect("write temp ruby file");
    parse(file.path()).expect("parse temp ruby file").0
}

fn parse_language_source(source: &str, language: Language, suffix: &str) -> Node {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create temp source file");
    file.write_all(source.as_bytes())
        .expect("write temp source file");
    parse_with_language(file.path(), language)
        .expect("parse temp source file")
        .0
}

fn nodes_of_type<'a>(node: &'a Node, node_type: &str, out: &mut Vec<&'a Node>) {
    if node.r#type == node_type {
        out.push(node);
    }
    for child in node.children.iter().filter_map(super::node) {
        nodes_of_type(child, node_type, out);
    }
}

fn first_node<'a>(root: &'a Node, node_type: &str, text: &str) -> &'a Node {
    let mut nodes = Vec::new();
    nodes_of_type(root, node_type, &mut nodes);
    nodes
        .into_iter()
        .find(|node| node.text == text)
        .unwrap_or_else(|| panic!("expected {node_type} with text {text:?} in {root:#?}"))
}

fn child_node(node: &Node, index: usize) -> &Node {
    node.children
        .get(index)
        .and_then(super::node)
        .unwrap_or_else(|| panic!("expected child node {index} in {node:#?}"))
}

fn child_types(node: &Node) -> Vec<&str> {
    node.children
        .iter()
        .filter_map(super::node)
        .map(|child| child.r#type.as_str())
        .collect()
}

fn test_node(node_type: &str, children: Vec<Child>) -> Node {
    Node {
        r#type: node_type.to_string(),
        children,
        first_lineno: 1,
        first_column: 0,
        last_lineno: 1,
        last_column: 1,
        text: node_type.to_string(),
    }
}

fn infix_parts_text(
    normalizer: &super::TreeSitterNormalizer<'_>,
    node: TreeSitterNode<'_>,
    source: &str,
) -> Option<(String, String, String)> {
    let (left, operator, right) = normalizer.infix_statement_parts(node)?;
    Some((
        super::node_text(left, source).to_string(),
        operator,
        super::node_text(right, source).to_string(),
    ))
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

fn children_value(children: &[Child]) -> Value {
    Value::Array(children.iter().map(child_value).collect())
}

fn ruby_language_name(language: Language) -> &'static str {
    match language {
        Language::Ruby => "ruby",
        Language::Python => "python",
        Language::JavaScript => "javascript",
        Language::Java => "java",
        Language::TypeScript => "typescript",
        Language::Swift => "swift",
        Language::Kotlin => "kotlin",
        Language::Go => "go",
        Language::Rust => "rust",
        Language::Zig => "zig",
        Language::Lua => "lua",
        Language::C => "c",
        Language::Cpp => "cpp",
        Language::CSharp => "csharp",
        Language::Php => "php",
    }
}

fn ruby_normalized_value(path: &Path, language: Language) -> Value {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          root, = FactMine::Ast.parse(ARGV.fetch(0))

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(value(root))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(path)
        .output()
        .expect("run ruby normalizer");
    assert!(
        output.status.success(),
        "ruby normalizer failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby normalizer should emit JSON")
}

fn assert_ruby_parity(source: &str, language: Language, suffix: &str) {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create parity temp source file");
    file.write_all(source.as_bytes())
        .expect("write parity temp source file");

    let rust = node_value(
        &parse_with_language(file.path(), language)
            .expect("parse parity temp source file")
            .0,
    );
    let ruby = ruby_normalized_value(file.path(), language);
    assert_eq!(rust, ruby);
}

fn raw_tree(source: &str, language: Language) -> tree_sitter::Tree {
    let mut parser = TreeSitterParser::new();
    parser
        .set_language(&crate::syntax::parser_grammar::grammar_for_language(
            language,
        ))
        .expect("set raw parser language");
    parser.parse(source, None).expect("parse raw source")
}

fn first_raw_node<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
    kind: &str,
    text: &str,
) -> TreeSitterNode<'tree> {
    if node.kind() == kind && super::node_text(node, source) == text {
        return node;
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if let Some(found) = first_raw_node_opt(child, source, kind, text) {
            return found;
        }
    }
    panic!("expected raw node kind={kind:?} text={text:?}");
}

fn first_raw_node_opt<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
    kind: &str,
    text: &str,
) -> Option<TreeSitterNode<'tree>> {
    if node.kind() == kind && super::node_text(node, source) == text {
        return Some(node);
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        if let Some(found) = first_raw_node_opt(child, source, kind, text) {
            return Some(found);
        }
    }
    None
}

fn nth_raw_node<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
    kind: &str,
    text: &str,
    index: usize,
) -> TreeSitterNode<'tree> {
    let mut found = Vec::new();
    collect_raw_nodes(node, source, kind, text, &mut found);
    *found
        .get(index)
        .unwrap_or_else(|| panic!("expected raw node kind={kind:?} text={text:?} index={index}"))
}

fn collect_raw_nodes<'tree>(
    node: TreeSitterNode<'tree>,
    source: &str,
    kind: &str,
    text: &str,
    found: &mut Vec<TreeSitterNode<'tree>>,
) {
    if node.kind() == kind && super::node_text(node, source) == text {
        found.push(node);
    }
    let mut cursor = node.walk();
    for child in node.children(&mut cursor) {
        collect_raw_nodes(child, source, kind, text, found);
    }
}

fn ruby_private_predicate(
    source: &str,
    language: Language,
    suffix: &str,
    method: &str,
    kind: &str,
    text: &str,
) -> bool {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby predicate temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby predicate temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          result =
            case method
            when "ruby_definition_identifier?"
              adapter.definition_identifier?(target, helpers: normalizer)
            when "ruby_assignment_node?", "ruby_scope_boundary?", "ruby_scope_child_boundary?"
              adapter.send(method, target)
            else
              normalizer.send(method, target)
            end
          puts result ? "true" : "false"
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby private predicate");
    assert!(
        output.status.success(),
        "ruby predicate failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby predicate output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_collected_names(
    source: &str,
    language: Language,
    suffix: &str,
    method: &str,
    kind: &str,
    text: &str,
) -> BTreeSet<String> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby collected names temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby collected names temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          locals = Set.new
          adapter.send(method, target, locals)
          puts JSON.generate(locals.to_a.sort)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-r",
            "set",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby collected names helper");
    assert!(
        output.status.success(),
        "ruby collected names helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice::<Vec<String>>(&output.stdout)
        .expect("ruby collected names output should be json")
        .into_iter()
        .collect()
}

fn ruby_private_scope_collected_names(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    root: bool,
) -> BTreeSet<String> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby scope collected names temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby scope collected names temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          require "set"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          root = ARGV.fetch(3) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          locals = Set.new
          adapter.send(:collect_ruby_scope_locals, target, locals, root: root)
          puts JSON.generate(locals.to_a.sort)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(if root { "true" } else { "false" })
        .output()
        .expect("run ruby scope collected names helper");
    assert!(
        output.status.success(),
        "ruby scope collected names helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice::<Vec<String>>(&output.stdout)
        .expect("ruby scope collected names output should be json")
        .into_iter()
        .collect()
}

fn ruby_private_ruby_scope_locals(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> BTreeSet<String> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby scope locals temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby scope locals temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          puts JSON.generate(adapter.send(:ruby_scope_locals, target).to_a.sort)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-r",
            "set",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby scope locals helper");
    assert!(
        output.status.success(),
        "ruby scope locals helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice::<Vec<String>>(&output.stdout)
        .expect("ruby scope locals output should be json")
        .into_iter()
        .collect()
}

fn ruby_private_with_ruby_scope_trace(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    reset: bool,
    initial_stack: &[Vec<&str>],
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby with_ruby_scope temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby with_ruby_scope temp source file");
    let initial_stack_json =
        serde_json::to_string(initial_stack).expect("serialize initial local stack");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          reset = ARGV.fetch(3) == "true"
          initial = JSON.parse(ARGV.fetch(4)).map { |names| Set.new(names) }
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          adapter.instance_variable_set(:@local_stack, initial)
          snapshot = lambda do
            Array(adapter.instance_variable_get(:@local_stack)).map { |locals| locals.to_a.sort }
          end
          before = snapshot.call
          inside = nil
          result = adapter.with_local_scope(target, reset: reset) do
            inside = snapshot.call
            "block-result"
          end
          after = snapshot.call
          puts JSON.generate("before" => before, "inside" => inside, "after" => after, "result" => result)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-r",
            "set",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(if reset { "true" } else { "false" })
        .arg(initial_stack_json)
        .output()
        .expect("run ruby with_ruby_scope helper");
    assert!(
        output.status.success(),
        "ruby with_ruby_scope helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby with_ruby_scope output should be json")
}

fn local_stack_from(names: &[Vec<&str>]) -> Vec<BTreeSet<String>> {
    names
        .iter()
        .map(|scope| scope.iter().map(|name| name.to_string()).collect())
        .collect()
}

fn local_stack_value(stack: &[BTreeSet<String>]) -> Value {
    json!(stack
        .iter()
        .map(|scope| scope.iter().cloned().collect::<Vec<_>>())
        .collect::<Vec<_>>())
}

fn ruby_private_destructured_parameter_targets_value(
    source: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(".rb")
        .tempfile()
        .expect("create ruby destructured parameter temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby destructured parameter temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          targets = []
          normalizer.send(:collect_destructured_parameter_targets, target, targets)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(targets.map { |node| value(node) })
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env(
            "DECOMPLEX_FORCE_LANGUAGE",
            ruby_language_name(Language::Ruby),
        )
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby destructured parameter helper");
    assert!(
        output.status.success(),
        "ruby destructured parameter helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby destructured parameter output should be json")
}

fn ruby_private_scope_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    mode: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby scope temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby scope temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          mode = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)

          body = mode == "body" ? normalizer.send(:wrap, :BODY, children: [], source: target) : nil
          args = mode == "args" ? normalizer.send(:wrap, :ARGS, children: [], source: target) : nil
          result = normalizer.send(:scope, body, args: args, source: target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(mode)
        .output()
        .expect("run ruby scope helper");
    assert!(
        output.status.success(),
        "ruby scope helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby scope output should be json")
}

fn ruby_private_list_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    mode: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby list temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby list temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          mode = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)

          item = normalizer.send(:wrap, :ITEM, children: [], source: target)
          children =
            case mode
            when "nil" then nil
            when "empty" then []
            when "one" then [item]
            else abort "unknown list mode: #{mode}"
            end
          result = normalizer.send(:list, children, source: target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(mode)
        .output()
        .expect("run ruby list helper");
    assert!(
        output.status.success(),
        "ruby list helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby list output should be json")
}

fn ruby_private_string(
    source: &str,
    language: Language,
    suffix: &str,
    method: &str,
    kind: &str,
    text: &str,
) -> String {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby string temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby string temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(method, target).to_s
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby private string helper");
    assert!(
        output.status.success(),
        "ruby string helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby string helper output should be utf8")
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

fn ruby_private_text_predicate(language: Language, method: &str, text: &str) -> bool {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          language = ARGV.fetch(0).to_sym
          text = ARGV.fetch(1)
          method = ARGV.fetch(2)
          document = Object.new
          document.define_singleton_method(:language) { language }
          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          puts normalizer.send(method, text) ? "true" : "false"
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args(["-I", "lib", "-r", "fact_mine/ast", "-e", script])
        .arg(ruby_language_name(language))
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby private text predicate");
    assert!(
        output.status.success(),
        "ruby text predicate failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby text predicate output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_text_string(language: Language, method: &str, text: &str) -> String {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          language = ARGV.fetch(0).to_sym
          text = ARGV.fetch(1)
          method = ARGV.fetch(2)
          document = Object.new
          document.define_singleton_method(:language) { language }
          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          puts normalizer.send(method, text).to_s
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args(["-I", "lib", "-r", "fact_mine/ast", "-e", script])
        .arg(ruby_language_name(language))
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby private text string helper");
    assert!(
        output.status.success(),
        "ruby text string helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby text string output should be utf8")
        .trim_end_matches(['\r', '\n'])
        .to_string()
}

fn ruby_private_ts_node_value(value: &str) -> bool {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = Object.new
          document.define_singleton_method(:language) { :ruby }
          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          target =
            case ARGV.fetch(0)
            when "nil"
              nil
            when "string"
              "value"
            when "normalized_node"
              FactMine::Ast::Node.new(type: :LIT, children: [], first_lineno: 1, first_column: 0, last_lineno: 1, last_column: 1, text: "1")
            else
              abort "unknown ts_node? probe"
            end
          puts normalizer.send(:ts_node?, target) ? "true" : "false"
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args(["-I", "lib", "-r", "fact_mine/ast", "-e", script])
        .arg(value)
        .output()
        .expect("run ruby private ts_node? value helper");
    assert!(
        output.status.success(),
        "ruby ts_node? value helper failed for {value}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby ts_node? value output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_regex_literal_value(value: &str) -> bool {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = Object.new
          document.define_singleton_method(:language) { :ruby }
          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          normalizer.instance_variable_set(:@document, document)
          target =
            case ARGV.fetch(0)
            when "nil"
              nil
            when "string"
              "value"
            when "normalized_node"
              FactMine::Ast::Node.new(type: :LIT, children: [], first_lineno: 1, first_column: 0, last_lineno: 1, last_column: 1, text: "1")
            else
              abort "unknown regex_literal? probe"
            end
          puts normalizer.send(:regex_literal?, target) ? "true" : "false"
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args(["-I", "lib", "-r", "fact_mine/ast", "-e", script])
        .arg(value)
        .output()
        .expect("run ruby private regex_literal? value helper");
    assert!(
        output.status.success(),
        "ruby regex_literal? value helper failed for {value}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby regex_literal? value output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_node_signature(
    source: &str,
    language: Language,
    suffix: &str,
    method: &str,
    kind: &str,
    text: &str,
) -> Option<(String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby node signature temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby node signature temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(method, target)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby private node signature helper");
    assert!(
        output.status.success(),
        "ruby node signature helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value =
        serde_json::from_slice(&output.stdout).expect("ruby node signature output should be json");
    if value.is_null() {
        return None;
    }
    let pair = value
        .as_array()
        .expect("ruby node signature should be an array");
    Some((
        pair[0]
            .as_str()
            .expect("node kind should be string")
            .to_string(),
        pair[1]
            .as_str()
            .expect("node text should be string")
            .to_string(),
    ))
}

fn ruby_private_inline_def_name_after_receiver(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> String {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby inline def name temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby inline def name temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          receiver = normalizer.send(:inline_def_receiver, target)
          puts normalizer.send(:inline_def_name_after_receiver, target, receiver).to_s
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby inline def name helper");
    assert!(
        output.status.success(),
        "ruby inline def name helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby inline def name output should be utf8")
        .trim()
        .to_string()
}

fn ruby_private_inline_parameter_begin_marker_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby inline_parameter_begin_marker temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby inline_parameter_begin_marker temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:inline_parameter_begin_marker, target)
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private inline_parameter_begin_marker helper");
    assert!(
        output.status.success(),
        "ruby inline_parameter_begin_marker helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby inline_parameter_begin_marker output should be json")
}

fn ruby_private_prepend_inline_parameter_begin_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    body: &Value,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby prepend_inline_parameter_begin temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby prepend_inline_parameter_begin temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            FactMine::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |ts_node|
            if ts_node.respond_to?(:kind)
              target ||= ts_node if ts_node.kind == target_kind && ts_node.text.to_s == target_text
              ts_node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target

          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          body = node(JSON.parse(ARGV.fetch(3)))
          result = normalizer.send(:prepend_inline_parameter_begin, target, body)
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(body.to_string())
        .output()
        .expect("run ruby private prepend_inline_parameter_begin helper");
    assert!(
        output.status.success(),
        "ruby prepend_inline_parameter_begin helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby prepend_inline_parameter_begin output should be json")
}

fn ruby_private_local_or_call_for_name_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    name: &str,
    local: bool,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby local_or_call_for_name temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby local_or_call_for_name temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          require "set"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          name = ARGV.fetch(3)
          local = ARGV.fetch(4) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          adapter.instance_variable_set(:@local_stack, local ? [Set[name]] : [])
          result = normalizer.send(:local_or_call_for_name, name, target)
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(name)
        .arg(if local { "true" } else { "false" })
        .output()
        .expect("run ruby private local_or_call_for_name helper");
    assert!(
        output.status.success(),
        "ruby local_or_call_for_name helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby local_or_call_for_name output should be json")
}

fn ruby_private_ruby_vcall_identifier_predicate(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    local_names: &[&str],
) -> bool {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby ruby_vcall_identifier temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby ruby_vcall_identifier temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          require "set"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          local_names = ARGV.fetch(3).split(",").reject(&:empty?)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          adapter.instance_variable_set(:@local_stack, local_names.empty? ? [] : [Set.new(local_names)])
          puts adapter.implicit_call_identifier?(target, helpers: normalizer)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(local_names.join(","))
        .output()
        .expect("run ruby private ruby_vcall_identifier? helper");
    assert!(
        output.status.success(),
        "ruby ruby_vcall_identifier? helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby ruby_vcall_identifier? output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_vcall_identifier_predicate(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    local_names: &[&str],
) -> bool {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby vcall_identifier temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby vcall_identifier temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          require "set"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          local_names = ARGV.fetch(3).split(",").reject(&:empty?)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          adapter.instance_variable_set(:@local_stack, local_names.empty? ? [] : [Set.new(local_names)])
          puts normalizer.send(:vcall_identifier?, target)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(local_names.join(","))
        .output()
        .expect("run ruby private vcall_identifier? helper");
    assert!(
        output.status.success(),
        "ruby vcall_identifier? helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby vcall_identifier? output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_normalize_terminal_statement_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    local_names: &[&str],
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby normalize_terminal_statement temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby normalize_terminal_statement temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          require "set"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          local_names = ARGV.fetch(3).split(",").reject(&:empty?)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          adapter = normalizer.send(:normalization_adapter)
          adapter.instance_variable_set(:@local_stack, local_names.empty? ? [] : [Set.new(local_names)])
          result = normalizer.send(:normalize_terminal_statement, target)
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(local_names.join(","))
        .output()
        .expect("run ruby private normalize_terminal_statement helper");
    assert!(
        output.status.success(),
        "ruby normalize_terminal_statement helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby normalize_terminal_statement output should be json")
}

fn ruby_private_node_list_signature(
    source: &str,
    language: Language,
    suffix: &str,
    method: &str,
    kind: &str,
    text: &str,
) -> Vec<(String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby node list signature temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby node list signature temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = Array(normalizer.send(method, target))
          puts JSON.generate(result.map { |node| [node.kind, node.text.to_s] })
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby node list signature helper");
    assert!(
        output.status.success(),
        "ruby node list signature helper failed for {method}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout)
        .expect("ruby node list signature output should be json");
    value
        .as_array()
        .expect("ruby node list signature should be an array")
        .iter()
        .map(|item| {
            let item = item
                .as_array()
                .expect("ruby node list item should be an array");
            (
                item[0]
                    .as_str()
                    .expect("ruby node list kind should be a string")
                    .to_string(),
                item[1]
                    .as_str()
                    .expect("ruby node list text should be a string")
                    .to_string(),
            )
        })
        .collect()
}

fn ruby_private_dotted_call_parts(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Option<(String, String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby dotted_call_parts temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby dotted_call_parts temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          receiver, method = normalizer.send(:dotted_call_parts, target)
          if receiver
            puts JSON.generate([receiver.kind, receiver.text.to_s, method.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private dotted_call_parts helper");
    assert!(
        output.status.success(),
        "ruby dotted_call_parts helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout)
        .expect("ruby dotted_call_parts output should be json");
    if value.is_null() {
        return None;
    }
    let parts = value
        .as_array()
        .expect("ruby dotted_call_parts should be an array");
    Some((
        parts[0]
            .as_str()
            .expect("receiver kind should be string")
            .to_string(),
        parts[1]
            .as_str()
            .expect("receiver text should be string")
            .to_string(),
        parts[2]
            .as_str()
            .expect("method should be string")
            .to_string(),
    ))
}

fn ruby_private_member_parts(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Option<(String, String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby member_parts temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby member_parts temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          receiver, method = normalizer.send(:member_parts, target)
          if receiver
            puts JSON.generate([receiver.kind, receiver.text.to_s, method.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private member_parts helper");
    assert!(
        output.status.success(),
        "ruby member_parts helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value =
        serde_json::from_slice(&output.stdout).expect("ruby member_parts output should be json");
    if value.is_null() {
        return None;
    }
    let parts = value
        .as_array()
        .expect("ruby member_parts should be an array");
    Some((
        parts[0]
            .as_str()
            .expect("receiver kind should be string")
            .to_string(),
        parts[1]
            .as_str()
            .expect("receiver text should be string")
            .to_string(),
        parts[2]
            .as_str()
            .expect("method should be string")
            .to_string(),
    ))
}

fn ruby_private_named_field_signature(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    field: &str,
) -> Option<(String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby named_field temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby named_field temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          field = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:named_field, target, field)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(field)
        .output()
        .expect("run ruby private named_field helper");
    assert!(
        output.status.success(),
        "ruby named_field helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value =
        serde_json::from_slice(&output.stdout).expect("ruby named_field output should be json");
    if value.is_null() {
        return None;
    }
    let pair = value
        .as_array()
        .expect("ruby named_field output should be an array");
    Some((
        pair[0]
            .as_str()
            .expect("named_field kind should be string")
            .to_string(),
        pair[1]
            .as_str()
            .expect("named_field text should be string")
            .to_string(),
    ))
}

fn ruby_private_branch_child_signature(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    condition_kind: &str,
    condition_text: &str,
    index: usize,
) -> Option<(String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby branch_child temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby branch_child temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          condition_kind = ARGV.fetch(3)
          condition_text = ARGV.fetch(4)
          index = Integer(ARGV.fetch(5))
          target = nil
          condition = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              condition ||= node if node.kind == condition_kind && node.text.to_s == condition_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          abort "condition node not found" unless condition
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:branch_child, target, condition, index)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(condition_kind)
        .arg(condition_text)
        .arg(index.to_string())
        .output()
        .expect("run ruby private branch_child helper");
    assert!(
        output.status.success(),
        "ruby branch_child helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value =
        serde_json::from_slice(&output.stdout).expect("ruby branch_child output should be json");
    if value.is_null() {
        return None;
    }
    let pair = value
        .as_array()
        .expect("ruby branch_child output should be an array");
    Some((
        pair[0]
            .as_str()
            .expect("branch_child kind should be string")
            .to_string(),
        pair[1]
            .as_str()
            .expect("branch_child text should be string")
            .to_string(),
    ))
}

fn ruby_private_wrap_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    normalized_source: bool,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby wrap temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby wrap temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          normalized_source = ARGV.fetch(3) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          source = if normalized_source
            normalizer.send(:wrap, :INNER, children: [], source: target)
          else
            target
          end
          result = normalizer.send(:wrap, :OUTER, children: [:child], source: source)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(if normalized_source { "true" } else { "false" })
        .output()
        .expect("run ruby private wrap helper");
    assert!(
        output.status.success(),
        "ruby wrap helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby wrap output should be json")
}

fn ruby_private_normalize_method_value(
    source: &str,
    language: Language,
    suffix: &str,
    method: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby normalize method temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby normalize method temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          method = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(method, target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(method)
        .output()
        .expect("run ruby private normalize method helper");
    assert!(
        output.status.success(),
        "ruby normalize method helper failed for {method}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby normalize method output should be json")
}

fn ruby_private_normalize_return_node_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    elide_symbol: bool,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby normalize return node temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby normalize return node temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          elide_symbol = ARGV.fetch(3) == "true"
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:normalize_return_node, target, elide_symbol: elide_symbol)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            elsif node.is_a?(Array)
              node.map { |child| value(child) }
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(if elide_symbol { "true" } else { "false" })
        .output()
        .expect("run ruby private normalize_return_node helper");
    assert!(
        output.status.success(),
        "ruby normalize_return_node helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby normalize_return_node output should be json")
}

fn ruby_private_normalize_body_nodes_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby normalize body nodes temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby normalize body nodes temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          if target_kind == "__root__"
            target = document.root
          else
            walk = lambda do |node|
              if node.respond_to?(:kind)
                target ||= node if node.kind == target_kind && node.text.to_s == target_text
                node.named_children.each { |child| walk.call(child) }
              end
            end
            walk.call(document.root)
          end
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:normalize_body_nodes, target.named_children, source: target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private normalize_body_nodes helper");
    assert!(
        output.status.success(),
        "ruby normalize_body_nodes helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby normalize_body_nodes output should be json")
}

fn ruby_private_inline_def_from_argument_list_nil_value(
    source: &str,
    language: Language,
    suffix: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby inline def argument nil temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby inline def argument nil temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:inline_def_from_argument_list, nil)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .output()
        .expect("run ruby private inline def argument nil helper");
    assert!(
        output.status.success(),
        "ruby inline def argument nil helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby inline def argument nil output should be json")
}

fn ruby_private_assignment_target_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby assignment target temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby assignment target temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          source = normalizer.send(:parent_node, target) || target
          right_raw = normalizer.send(:assignment_right, source)
          right = right_raw ? normalizer.send(:normalize_node, right_raw) : nil
          result = normalizer.send(:assignment_target, target, right, source: source)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private assignment target helper");
    assert!(
        output.status.success(),
        "ruby assignment target helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby assignment target output should be json")
}

fn ruby_private_normalize_multiple_assignment_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby multiple assignment temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby multiple assignment temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          left = normalizer.send(:assignment_left, target)
          right_raw = normalizer.send(:assignment_right, target)
          right = right_raw ? normalizer.send(:normalize_node, right_raw) : nil
          result = normalizer.send(:normalize_multiple_assignment, left, right, target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private multiple assignment helper");
    assert!(
        output.status.success(),
        "ruby multiple assignment helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby multiple assignment output should be json")
}

fn ruby_private_augmented_assignment_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    operator: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby augmented assignment value temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby augmented assignment value temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          operator = ARGV.fetch(3).to_sym
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          source = normalizer.send(:parent_node, target) || target
          right_raw = normalizer.send(:assignment_right, source)
          result = normalizer.send(:augmented_assignment_value, target, operator, right_raw, source)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(operator)
        .output()
        .expect("run ruby private augmented assignment value helper");
    assert!(
        output.status.success(),
        "ruby augmented assignment value helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby augmented assignment value output should be json")
}

fn ruby_private_logical_operator_assignment_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby logical operator assignment temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby logical operator assignment temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          left = normalizer.send(:assignment_left, target)
          right_raw = normalizer.send(:assignment_right, target)
          right = normalizer.send(:normalize_node, right_raw)
          operator = normalizer.send(:operator_assignment_operator, target)
          result = normalizer.send(:normalize_logical_operator_assignment, left, operator, right, source: target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private logical operator assignment helper");
    assert!(
        output.status.success(),
        "ruby logical operator assignment helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby logical operator assignment output should be json")
}

fn ruby_private_call_arguments_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    function_mode: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby call arguments temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby call arguments temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          function_mode = ARGV.fetch(3)
          target = nil
          fallback_target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              fallback_target ||= node if node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          target ||= fallback_target
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          function =
            case function_mode
            when "auto"
              normalizer.send(:named_field, target, "function") ||
                normalizer.send(:named_field, target, "call") ||
                target.named_children.first
            when "none"
              nil
            else
              abort "unknown function mode: #{function_mode.inspect}"
            end
          result = normalizer.send(:call_arguments, target, function)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(result.map { |node| value(node) })
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(function_mode)
        .output()
        .expect("run ruby private call arguments helper");
    assert!(
        output.status.success(),
        "ruby call arguments helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby call arguments output should be json")
}

fn ruby_private_normalize_call_without_block_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    block_mode: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby normalize_call_without_block temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby normalize_call_without_block temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          block_mode = ARGV.fetch(3)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          block =
            case block_mode
            when "auto"
              normalizer.send(:call_block, target)
            when "none"
              nil
            else
              abort "unknown block mode: #{block_mode.inspect}"
            end
          result = normalizer.send(:normalize_call_without_block, target, block)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(block_mode)
        .output()
        .expect("run ruby private normalize_call_without_block helper");
    assert!(
        output.status.success(),
        "ruby normalize_call_without_block helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby normalize_call_without_block output should be json")
}

fn ruby_private_normalize_patterns_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby normalize_patterns temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby normalize_patterns temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:normalize_patterns, target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(result.map { |node| value(node) })
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private normalize_patterns helper");
    assert!(
        output.status.success(),
        "ruby normalize_patterns helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby normalize_patterns output should be json")
}

fn ruby_private_command_arguments_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby command arguments temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby command arguments temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          fallback_target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              fallback_target ||= node if node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          target ||= fallback_target
          abort "target node not found: #{target_kind} #{target_text.inspect}" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:command_arguments, target)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(result.map { |node| value(node) })
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private command arguments helper");
    assert!(
        output.status.success(),
        "ruby command arguments helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby command arguments output should be json")
}

fn ruby_private_const_for_nil_value(source: &str, language: Language, suffix: &str) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby const_for nil temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby const_for nil temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:const_for, nil)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .output()
        .expect("run ruby private const_for nil helper");
    assert!(
        output.status.success(),
        "ruby const_for nil helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby const_for nil output should be json")
}

fn ruby_private_source_before_child_wrap_value(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    child_kind: &str,
    child_text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby source_before_child temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby source_before_child temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          child_kind = ARGV.fetch(3)
          child_text = ARGV.fetch(4)
          target = nil
          child = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              child ||= node if node.kind == child_kind && node.text.to_s == child_text
              node.named_children.each { |next_child| walk.call(next_child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          abort "child node not found" unless child
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          source = normalizer.send(:source_before_child, target, child)
          result = normalizer.send(:wrap, :OUTER, children: [], source: source)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(child_kind)
        .arg(child_text)
        .output()
        .expect("run ruby private source_before_child helper");
    assert!(
        output.status.success(),
        "ruby source_before_child helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby source_before_child output should be json")
}

fn ruby_private_source_from_nodes_value(
    source: &str,
    language: Language,
    suffix: &str,
    first_kind: &str,
    first_text: &str,
    last_kind: &str,
    last_text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby source_from_nodes temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby source_from_nodes temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          first_kind = ARGV.fetch(1)
          first_text = ARGV.fetch(2)
          last_kind = ARGV.fetch(3)
          last_text = ARGV.fetch(4)
          first_node = nil
          last_node = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              first_node ||= node if node.kind == first_kind && node.text.to_s == first_text
              last_node = node if node.kind == last_kind && node.text.to_s == last_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "first node not found: #{first_kind} #{first_text.inspect}" unless first_node
          abort "last node not found: #{last_kind} #{last_text.inspect}" unless last_node
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          result = normalizer.send(:source_from_nodes, first_node, last_node)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(first_kind)
        .arg(first_text)
        .arg(last_kind)
        .arg(last_text)
        .output()
        .expect("run ruby private source_from_nodes helper");
    assert!(
        output.status.success(),
        "ruby source_from_nodes helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby source_from_nodes output should be json")
}

fn ruby_private_source_from_normalized_nodes_value(
    source: &str,
    language: Language,
    suffix: &str,
    first_kind: &str,
    first_text: &str,
    last_kind: &str,
    last_text: &str,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby source_from_normalized_nodes temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby source_from_normalized_nodes temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          first_kind = ARGV.fetch(1)
          first_text = ARGV.fetch(2)
          last_kind = ARGV.fetch(3)
          last_text = ARGV.fetch(4)
          first_raw = nil
          last_raw = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              first_raw ||= node if node.kind == first_kind && node.text.to_s == first_text
              last_raw ||= node if node.kind == last_kind && node.text.to_s == last_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "first node not found" unless first_raw
          abort "last node not found" unless last_raw
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          first_node = normalizer.send(:wrap, :FIRST, children: [], source: first_raw)
          last_node = normalizer.send(:wrap, :LAST, children: [], source: last_raw)
          result = normalizer.send(:source_from_normalized_nodes, first_node, last_node)

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(first_kind)
        .arg(first_text)
        .arg(last_kind)
        .arg(last_text)
        .output()
        .expect("run ruby private source_from_normalized_nodes helper");
    assert!(
        output.status.success(),
        "ruby source_from_normalized_nodes helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby source_from_normalized_nodes output should be json")
}

fn ruby_private_dynamic_string_source_signature(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Option<(String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby dynamic_string_source temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby dynamic_string_source temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          normalized = target.named_children.map { |child| [child, normalizer.send(:normalize_node, child)] }
          result = normalizer.send(:dynamic_string_source, normalized)
          if result
            puts JSON.generate([result.kind, result.text.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private dynamic_string_source helper");
    assert!(
        output.status.success(),
        "ruby dynamic_string_source helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value = serde_json::from_slice(&output.stdout)
        .expect("ruby dynamic_string_source output should be json");
    if value.is_null() {
        return None;
    }
    let pair = value
        .as_array()
        .expect("ruby dynamic_string_source output should be an array");
    Some((
        pair[0]
            .as_str()
            .expect("dynamic_string_source kind should be string")
            .to_string(),
        pair[1]
            .as_str()
            .expect("dynamic_string_source text should be string")
            .to_string(),
    ))
}

fn ruby_private_operator_assignment_statement_parts_signature(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Option<(String, String, String, String, String)> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby operator_assignment_statement_parts temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby operator_assignment_statement_parts temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          left, operator, right = normalizer.send(:operator_assignment_statement_parts, target)
          if left && operator && right
            puts JSON.generate([left.kind, left.text.to_s, operator.to_s, right.kind, right.text.to_s])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private operator_assignment_statement_parts helper");
    assert!(
            output.status.success(),
            "ruby operator_assignment_statement_parts helper failed for {language:?} {kind:?} {text:?}: stdout={} stderr={}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    let value: Value = serde_json::from_slice(&output.stdout)
        .expect("ruby operator_assignment_statement_parts output should be json");
    if value.is_null() {
        return None;
    }
    let parts = value
        .as_array()
        .expect("ruby operator_assignment_statement_parts output should be an array");
    Some((
        parts[0]
            .as_str()
            .expect("operator_assignment left kind should be string")
            .to_string(),
        parts[1]
            .as_str()
            .expect("operator_assignment left text should be string")
            .to_string(),
        parts[2]
            .as_str()
            .expect("operator_assignment operator should be string")
            .to_string(),
        parts[3]
            .as_str()
            .expect("operator_assignment right kind should be string")
            .to_string(),
        parts[4]
            .as_str()
            .expect("operator_assignment right text should be string")
            .to_string(),
    ))
}

fn ruby_private_modifier_parts_signature(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> Option<((String, String), (String, String))> {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby modifier_parts temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby modifier_parts temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          action, condition = normalizer.send(:modifier_parts, target)
          if action && condition
            puts JSON.generate([[action.kind, action.text.to_s], [condition.kind, condition.text.to_s]])
          else
            puts "null"
          end
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private modifier_parts helper");
    assert!(
        output.status.success(),
        "ruby modifier_parts helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value =
        serde_json::from_slice(&output.stdout).expect("ruby modifier_parts output should be json");
    if value.is_null() {
        return None;
    }
    let pairs = value
        .as_array()
        .expect("ruby modifier_parts output should be an array");
    let action = pairs[0]
        .as_array()
        .expect("modifier_parts action should be an array");
    let condition = pairs[1]
        .as_array()
        .expect("modifier_parts condition should be an array");
    Some((
        (
            action[0]
                .as_str()
                .expect("modifier_parts action kind should be string")
                .to_string(),
            action[1]
                .as_str()
                .expect("modifier_parts action text should be string")
                .to_string(),
        ),
        (
            condition[0]
                .as_str()
                .expect("modifier_parts condition kind should be string")
                .to_string(),
            condition[1]
                .as_str()
                .expect("modifier_parts condition text should be string")
                .to_string(),
        ),
    ))
}

fn ruby_private_visibility_inline_def_statement_predicate(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
) -> bool {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby visibility_inline_def_statement temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby visibility_inline_def_statement temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target = nil
          walk = lambda do |node|
            if node.respond_to?(:kind)
              target ||= node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          abort "target node not found" unless target
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(:visibility_inline_def_statement?, target, target.named_children.first)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .output()
        .expect("run ruby private visibility_inline_def_statement helper");
    assert!(
        output.status.success(),
        "ruby visibility_inline_def_statement helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby visibility_inline_def_statement output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_drop_trailing_nil_statement_value(input: &Value) -> Value {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            FactMine::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          adapter = FactMine::Ast::RubyTreeSitterNormalizationAdapter.new(nil)
          result = adapter.send(:drop_trailing_nil_statement, node(JSON.parse(ARGV.fetch(0))))
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(input.to_string())
        .output()
        .expect("run ruby private drop_trailing_nil_statement helper");
    assert!(
        output.status.success(),
        "ruby drop_trailing_nil_statement helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby drop_trailing_nil_statement output should be json")
}

fn ruby_private_elide_tail_returns_value(input: &Value, ruby: bool) -> Value {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            FactMine::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          adapter = if ARGV.fetch(1) == "ruby"
                    FactMine::Ast::RubyTreeSitterNormalizationAdapter.new(nil)
                    else
                    FactMine::Ast::TreeSitterNormalizationAdapter.new(nil)
                    end
          normalizer.instance_variable_set(:@normalization_adapter, adapter)
          result = normalizer.send(:elide_tail_returns, node(JSON.parse(ARGV.fetch(0))))
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(input.to_string())
        .arg(if ruby { "ruby" } else { "other" })
        .output()
        .expect("run ruby private elide_tail_returns helper");
    assert!(
        output.status.success(),
        "ruby elide_tail_returns helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout).expect("ruby elide_tail_returns output should be json")
}

fn ruby_private_elide_implicit_nil_body_value(input: &Value, ruby: bool) -> Value {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            FactMine::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          adapter = if ARGV.fetch(1) == "ruby"
                    FactMine::Ast::RubyTreeSitterNormalizationAdapter.new(nil)
                    else
                    FactMine::Ast::TreeSitterNormalizationAdapter.new(nil)
                    end
          normalizer.instance_variable_set(:@normalization_adapter, adapter)
          result = normalizer.send(:elide_implicit_nil_body, node(JSON.parse(ARGV.fetch(0))))
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(input.to_string())
        .arg(if ruby { "ruby" } else { "other" })
        .output()
        .expect("run ruby private elide_implicit_nil_body helper");
    assert!(
        output.status.success(),
        "ruby elide_implicit_nil_body helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby elide_implicit_nil_body output should be json")
}

fn ruby_private_prepend_rescue_exception_assignment_value(
    source: &str,
    body: &Value,
    assignment: &Value,
) -> Value {
    let mut file = tempfile::Builder::new()
        .suffix(".rb")
        .tempfile()
        .expect("create ruby prepend rescue temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby prepend rescue temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          def node(value)
            return nil if value.nil?
            return value unless value.is_a?(Hash)

            FactMine::Ast::Node.new(
              type: value.fetch("type").to_sym,
              children: value.fetch("children").map { |child| node(child) },
              first_lineno: value.fetch("first_lineno"),
              first_column: value.fetch("first_column"),
              last_lineno: value.fetch("last_lineno"),
              last_column: value.fetch("last_column"),
              text: value.fetch("text")
            )
          end

          def value(node)
            if node.is_a?(FactMine::Ast::Node)
              {
                "type" => node.type.to_s,
                "children" => node.children.map { |child| value(child) },
                "first_lineno" => node.first_lineno,
                "first_column" => node.first_column,
                "last_lineno" => node.last_lineno,
                "last_column" => node.last_column,
                "text" => node.text.to_s,
              }
            elsif node.is_a?(Symbol)
              node.to_s
            else
              node
            end
          end

          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          body = node(JSON.parse(ARGV.fetch(1)))
          assignment = node(JSON.parse(ARGV.fetch(2)))
          result = normalizer.send(:prepend_rescue_exception_assignment, body, assignment)
          puts JSON.generate(value(result))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", "ruby")
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(body.to_string())
        .arg(assignment.to_string())
        .output()
        .expect("run ruby private prepend_rescue_exception_assignment helper");
    assert!(
        output.status.success(),
        "ruby prepend_rescue_exception_assignment helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    serde_json::from_slice(&output.stdout)
        .expect("ruby prepend_rescue_exception_assignment output should be json")
}

fn ruby_private_symbol_literal_node_predicate(
    node_type: Option<&str>,
    child_kind: Option<&str>,
) -> bool {
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          def child(kind)
            case kind
            when "symbol"
              :value
            when "string"
              "value"
            when "node"
              FactMine::Ast::Node.new(
                type: :NIL,
                children: [],
                first_lineno: 1,
                first_column: 0,
                last_lineno: 1,
                last_column: 1,
                text: "NIL"
              )
            when "nil"
              nil
            else
              nil
            end
          end

          node_type = ARGV.fetch(0)
          child_kind = ARGV.fetch(1)
          target = if node_type == "none"
                     nil
                   else
                     children = child_kind == "none" ? [] : [child(child_kind)]
                     FactMine::Ast::Node.new(
                       type: node_type.to_sym,
                       children: children,
                       first_lineno: 1,
                       first_column: 0,
                       last_lineno: 1,
                       last_column: 1,
                       text: node_type
                     )
                   end
          normalizer = FactMine::Ast::TreeSitterNormalizer.allocate
          puts normalizer.send(:symbol_literal_node?, target)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .args(["-I", "lib", "-r", "fact_mine/ast", "-e", script])
        .arg(node_type.unwrap_or("none"))
        .arg(child_kind.unwrap_or("none"))
        .output()
        .expect("run ruby private symbol_literal_node? helper");
    assert!(
        output.status.success(),
        "ruby symbol_literal_node? helper failed: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby symbol_literal_node? output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_same_ts_node_predicate(
    source: &str,
    language: Language,
    suffix: &str,
    left_kind: &str,
    left_text: &str,
    left_index: usize,
    right_kind: &str,
    right_text: &str,
    right_index: usize,
) -> bool {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby same_ts_node temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby same_ts_node temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          left_kind = ARGV.fetch(1)
          left_text = ARGV.fetch(2)
          left_index = ARGV.fetch(3).to_i
          right_kind = ARGV.fetch(4)
          right_text = ARGV.fetch(5)
          right_index = ARGV.fetch(6).to_i

          def matches(root, kind, text)
            found = []
            walk = lambda do |node|
              if node.respond_to?(:kind)
                found << node if node.kind == kind && node.text.to_s == text
                node.named_children.each { |child| walk.call(child) }
              end
            end
            walk.call(root)
            found
          end

          left = matches(document.root, left_kind, left_text).fetch(left_index)
          right = matches(document.root, right_kind, right_text).fetch(right_index)
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(:same_ts_node?, left, right)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(left_kind)
        .arg(left_text)
        .arg(left_index.to_string())
        .arg(right_kind)
        .arg(right_text)
        .arg(right_index.to_string())
        .output()
        .expect("run ruby private same_ts_node? helper");
    assert!(
        output.status.success(),
        "ruby same_ts_node? helper failed for {language:?}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby same_ts_node? output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_parent_named_child_predicate(
    source: &str,
    language: Language,
    suffix: &str,
    parent_kind: &str,
    parent_text: &str,
    parent_index: usize,
    child_kind: &str,
    child_text: &str,
    child_index: usize,
) -> bool {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby parent_named_child temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby parent_named_child temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          parent_kind = ARGV.fetch(1)
          parent_text = ARGV.fetch(2)
          parent_index = ARGV.fetch(3).to_i
          child_kind = ARGV.fetch(4)
          child_text = ARGV.fetch(5)
          child_index = ARGV.fetch(6).to_i

          def matches(root, kind, text)
            found = []
            walk = lambda do |node|
              if node.respond_to?(:kind)
                found << node if node.kind == kind && node.text.to_s == text
                node.named_children.each { |child| walk.call(child) }
              end
            end
            walk.call(root)
            found
          end

          parent = matches(document.root, parent_kind, parent_text).fetch(parent_index)
          child = matches(document.root, child_kind, child_text).fetch(child_index)
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          puts normalizer.send(:parent_named_child?, parent, child)
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(parent_kind)
        .arg(parent_text)
        .arg(parent_index.to_string())
        .arg(child_kind)
        .arg(child_text)
        .arg(child_index.to_string())
        .output()
        .expect("run ruby private parent_named_child? helper");
    assert!(
        output.status.success(),
        "ruby parent_named_child? helper failed for {language:?}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout)
        .expect("ruby parent_named_child? output should be utf8")
        .trim()
        == "true"
}

fn ruby_private_node_key_signature(
    source: &str,
    language: Language,
    suffix: &str,
    kind: &str,
    text: &str,
    index: usize,
) -> (String, usize, usize) {
    let mut file = tempfile::Builder::new()
        .suffix(suffix)
        .tempfile()
        .expect("create ruby node_key temp source file");
    file.write_all(source.as_bytes())
        .expect("write ruby node_key temp source file");
    let fact_mine_dir = Path::new(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .expect("fact-mine rust dir should have gem parent");
    let script = r#"
          document = FactMine::Syntax.parse_raw(ARGV.fetch(0), parser: "tree_sitter")
          target_kind = ARGV.fetch(1)
          target_text = ARGV.fetch(2)
          target_index = ARGV.fetch(3).to_i
          found = []
          walk = lambda do |node|
            if node.respond_to?(:kind)
              found << node if node.kind == target_kind && node.text.to_s == target_text
              node.named_children.each { |child| walk.call(child) }
            end
          end
          walk.call(document.root)
          target = found.fetch(target_index)
          normalizer = FactMine::Ast::TreeSitterNormalizer.new(document)
          puts JSON.generate(normalizer.send(:node_key, target))
        "#;
    let output = Command::new("ruby")
        .current_dir(fact_mine_dir)
        .env("DECOMPLEX_FORCE_LANGUAGE", ruby_language_name(language))
        .args([
            "-I",
            "lib",
            "-r",
            "fact_mine/ast",
            "-r",
            "fact_mine/syntax",
            "-r",
            "json",
            "-e",
            script,
        ])
        .arg(file.path())
        .arg(kind)
        .arg(text)
        .arg(index.to_string())
        .output()
        .expect("run ruby private node_key helper");
    assert!(
        output.status.success(),
        "ruby node_key helper failed for {language:?}: stdout={} stderr={}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    let value: Value =
        serde_json::from_slice(&output.stdout).expect("ruby node_key output should be json");
    let key = value
        .as_array()
        .expect("ruby node_key output should be an array");
    (
        key[0]
            .as_str()
            .expect("node_key kind should be string")
            .to_string(),
        key[1]
            .as_u64()
            .expect("node_key start byte should be integer") as usize,
        key[2]
            .as_u64()
            .expect("node_key end byte should be integer") as usize,
    )
}

#[test]
fn tree_normalizer_new_initializes_empty_state() {
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

    assert_eq!(normalizer.source, "");
    assert_eq!(normalizer.language, Language::Ruby);
    assert!(normalizer.local_stack.is_empty());
    assert_eq!(normalizer.root_span, None);
}

#[test]
fn normalize_root_matches_ruby_across_tree_normalizer_languages() {
    for (source, language, suffix) in [
            (
                "class C\n  def each(value)\n    yield value\n    case value\n    when 1 then :one\n    else :other\n    end\n  end\nend\n",
                Language::Ruby,
                ".rb",
            ),
            (
                "def gen(value):\n    yield value\n    other()\n",
                Language::Python,
                ".py",
            ),
            (
                "function f(value: number) { switch (value) { case 1: one(); break; default: other(); } return value ? one() : other(); }\n",
                Language::TypeScript,
                ".ts",
            ),
            (
                "function f(value)\n  if value then\n    one()\n  else\n    other()\n  end\n  return value\nend\n",
                Language::Lua,
                ".lua",
            ),
        ] {
            assert_ruby_parity(source, language, suffix);
        }
}

#[test]
fn tree_normalizer_yield_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield :item\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield :item",
        ),
        (
            "def each\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value",
        ),
        (
            "def gen():\n    yield item\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield item",
        ),
        (
            "def gen():\n    yield from items\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield from items",
        ),
        (
            "def gen():\n    yield item\n    other()\n",
            Language::Python,
            ".py",
            "block",
            "yield item\n    other()",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.yield_statement(node),
            ruby_private_predicate(source, language, suffix, "yield_statement?", kind, text),
            "yield_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn yield_argument_list_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield(:item)\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "(:item)",
        ),
        (
            "def each\n  yield :item\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            ":item",
        ),
        (
            "def call\n  foo(:item)\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "(:item)",
        ),
        (
            "yield_value(value)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(value)",
        ),
        (
            "yield(value);\n",
            Language::TypeScript,
            ".ts",
            "parenthesized_expression",
            "(value)",
        ),
        (
            "coroutine.yield(value)\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.yield_argument_list(node),
            ruby_private_predicate(source, language, suffix, "yield_argument_list?", kind, text),
            "yield_argument_list? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn yield_argument_nodes_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield(:item)\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "(:item)",
        ),
        (
            "def each\n  yield nil\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "nil",
        ),
        (
            "def each\n  yield item, other\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "item, other",
        ),
        (
            "yield_value(value)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(value)",
        ),
        (
            "yield(value);\n",
            Language::TypeScript,
            ".ts",
            "parenthesized_expression",
            "(value)",
        ),
        (
            "coroutine.yield(value)\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = Value::Array(
            normalizer
                .yield_argument_nodes(node)
                .iter()
                .map(node_value)
                .collect(),
        );

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "yield_argument_nodes",
                kind,
                text
            ),
            "yield_argument_nodes mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn yield_inline_arguments_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield",
        ),
        (
            "def gen():\n    yield item\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield item",
        ),
        (
            "function* gen() { yield item; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "yield item;",
        ),
        (
            "coroutine.yield(item)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "coroutine.yield(item)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = Value::Array(
            normalizer
                .yield_inline_arguments(node)
                .iter()
                .map(node_value)
                .collect(),
        );

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "yield_inline_arguments",
                kind,
                text
            ),
            "yield_inline_arguments mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_yield_argument_list_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield(:item)\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "(:item)",
        ),
        (
            "def each\n  yield :item\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            ":item",
        ),
        (
            "def each\n  yield nil\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "nil",
        ),
        (
            "yield_value(value)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = node_value(&normalizer.normalize_yield_argument_list(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_yield_argument_list",
                kind,
                text
            ),
            "normalize_yield_argument_list mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_yield_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield",
        ),
        (
            "def each\n  yield item\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield item",
        ),
        (
            "def each\n  yield nil\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield nil",
        ),
        (
            "def gen():\n    yield item\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield item",
        ),
        (
            "function* gen() { yield item; }\n",
            Language::TypeScript,
            ".ts",
            "yield_expression",
            "yield item",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = node_value(&normalizer.normalize_yield(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_yield",
                kind,
                text
            ),
            "normalize_yield mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_yield_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield",
        ),
        (
            "def each\n  yield item\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield item",
        ),
        (
            "def each\n  yield nil\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield nil",
        ),
        (
            "def gen():\n    yield item\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield item",
        ),
        (
            "def gen():\n    yield from items\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield from items",
        ),
        (
            "function* gen() { yield item; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "yield item;",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = node_value(&normalizer.normalize_yield_statement(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_yield_statement",
                kind,
                text
            ),
            "normalize_yield_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_node_dispatch_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def each\n  yield item\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "yield item",
        ),
        (
            "def check\n  !flag\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "!flag",
        ),
        (
            "def gen():\n    yield item\n    other()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "yield item",
        ),
        (
            "switch (value) { case 1: one(); default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (value) { case 1: one(); default: other(); }",
        ),
        (
            "if value then one() else other() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value then one() else other() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_node(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_node",
                kind,
                text
            ),
            "normalize_node mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn python_yield_statement_in_multi_statement_block_matches_ruby_ast() {
    let source = "def gen():\n    yield item\n    other()\n";
    assert_ruby_parity(source, Language::Python, ".py");

    let root = parse_language_source(source, Language::Python, ".py");
    let defn = first_node(&root, "DEFN", "def gen():\n    yield item\n    other()");
    let scope = child_node(defn, 1);
    let body = child_node(scope, 2);

    assert_eq!(body.r#type, "BLOCK");
    assert_eq!(child_types(body), vec!["YIELD", "VCALL"]);
}

#[test]
fn tree_normalizer_super_statement_matches_ruby_private_predicate() {
    for (source, kind, text) in [
        (
            "class Child < Parent\n  def call\n    super\n  end\nend\n",
            "body_statement",
            "super",
        ),
        (
            "class Child < Parent\n  def call\n    super :item\n  end\nend\n",
            "body_statement",
            "super :item",
        ),
        (
            "class Child < Parent\n  def call\n    value\n  end\nend\n",
            "body_statement",
            "value",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

        assert_eq!(
            normalizer.super_statement(node),
            ruby_private_predicate(
                source,
                Language::Ruby,
                ".rb",
                "super_statement?",
                kind,
                text
            ),
            "super_statement? mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_super_statement_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "class Child < Parent\n  def call\n    super\n  end\nend\n",
            "body_statement",
            "super",
        ),
        (
            "class Child < Parent\n  def call\n    super :item\n  end\nend\n",
            "body_statement",
            "super :item",
        ),
        (
            "class Child < Parent\n  def call\n    super value\n  end\nend\n",
            "body_statement",
            "super value",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = node_value(&normalizer.normalize_super_statement(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_super_statement",
                kind,
                text
            ),
            "normalize_super_statement mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_super_statement_normalization_matches_ruby_ast() {
    let source = "class Child < Parent\n  def bare\n    super\n  end\n  def with_arg\n    super :item\n  end\nend\n";
    assert_ruby_parity(source, Language::Ruby, ".rb");

    let root = parse_language_source(source, Language::Ruby, ".rb");
    let bare = first_node(&root, "SUPER", "super");
    let with_arg = first_node(&root, "SUPER", "super :item");

    assert_eq!(bare.children, vec![Child::Nil]);
    assert_eq!(child_types(with_arg), vec!["LIST"]);
    assert_eq!(child_types(child_node(with_arg, 0)), vec!["LIT"]);
}

#[test]
fn tree_normalizer_argument_list_element_reference_matches_ruby_private_predicate() {
    for (source, text) in [
        ("def indexed\n  return items[0]\nend\n", "items[0]"),
        ("def indexed\n  return obj.foo[0]\nend\n", "obj.foo[0]"),
        ("def indexed\n  return [0]\nend\n", "[0]"),
        (
            "def indexed\n  return items[0], other\nend\n",
            "items[0], other",
        ),
        ("def indexed\n  return items[]\nend\n", "items[]"),
        (
            "def indexed\n  return items[0] { nope }\nend\n",
            "items[0] { nope }",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, "argument_list", text);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

        assert_eq!(
            normalizer.argument_list_element_reference(node),
            ruby_private_predicate(
                source,
                Language::Ruby,
                ".rb",
                "argument_list_element_reference?",
                "argument_list",
                text
            ),
            "argument_list_element_reference? mismatch for {text:?}"
        );
    }
}

#[test]
fn normalize_argument_list_element_reference_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def indexed\n  return items[0]\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "items[0]",
        ),
        (
            "def indexed\n  return obj.foo[0]\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "obj.foo[0]",
        ),
        (
            "def indexed\n  return [0]\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "[0]",
        ),
        (
            "def indexed\n  return items[0], other\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "items[0], other",
        ),
        (
            "def indexed\n  return items[0] { nope }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "items[0] { nope }",
        ),
        (
            "def indexed():\n    return foo(items[0])\n",
            Language::Python,
            ".py",
            "argument_list",
            "(items[0])",
        ),
        (
            "function indexed(){ return foo(items[0]); }\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(items[0])",
        ),
        (
            "function indexed() return foo(items[0]) end\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(items[0])",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_argument_list_element_reference(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_argument_list_element_reference",
                kind,
                text
            ),
            "normalize_argument_list_element_reference mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn dynamic_scope_rewrites_locals_without_crossing_scope_boundaries() {
    let inner_assignment = test_node("LASGN", vec![Child::Symbol("inner".to_string())]);
    let node = test_node(
        "BLOCK",
        vec![
            Child::Node(Box::new(test_node(
                "LASGN",
                vec![Child::Symbol("value".to_string())],
            ))),
            Child::Node(Box::new(test_node(
                "LVAR",
                vec![Child::Symbol("value".to_string())],
            ))),
            Child::Node(Box::new(test_node(
                "DEFN",
                vec![
                    Child::Symbol("nested".to_string()),
                    Child::Node(Box::new(test_node(
                        "SCOPE",
                        vec![
                            Child::Nil,
                            Child::Nil,
                            Child::Node(Box::new(inner_assignment)),
                        ],
                    ))),
                ],
            ))),
        ],
    );

    let result = super::dynamic_scope(node);

    assert_eq!(child_node(&result, 0).r#type, "DASGN");
    assert_eq!(child_node(&result, 1).r#type, "DVAR");
    let nested = child_node(&result, 2);
    assert_eq!(nested.r#type, "DEFN");
    let nested_scope = child_node(nested, 1);
    assert_eq!(nested_scope.r#type, "SCOPE");
    assert_eq!(child_node(nested_scope, 2).r#type, "LASGN");
}

#[test]
fn link_when_chain_sets_next_arm_and_pads_short_when_nodes() {
    let fallback = test_node("ELSE", Vec::new());
    let first = test_node(
        "WHEN",
        vec![
            Child::Symbol("patterns".to_string()),
            Child::Nil,
            Child::Nil,
        ],
    );
    let second = test_node(
        "WHEN",
        vec![
            Child::Symbol("patterns".to_string()),
            Child::Nil,
            Child::Nil,
        ],
    );
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

    let result = normalizer
        .link_when_chain(vec![first, second], Some(fallback))
        .expect("expected linked when chain");

    assert_eq!(result.r#type, "WHEN");
    let next = child_node(&result, 2);
    assert_eq!(next.r#type, "WHEN");
    assert_eq!(child_node(next, 2).r#type, "ELSE");

    let short = test_node("WHEN", vec![Child::Symbol("patterns".to_string())]);
    let fallback = test_node("ELSE", Vec::new());
    let result = normalizer
        .link_when_chain(vec![short], Some(fallback))
        .expect("expected padded when chain");

    assert_eq!(result.children.len(), 3);
    assert_eq!(result.children[1], Child::Nil);
    assert_eq!(child_node(&result, 2).r#type, "ELSE");
}

#[test]
fn link_rescue_chain_sets_next_rescue_and_pads_short_resbody_nodes() {
    let first = test_node(
        "RESBODY",
        vec![
            Child::Symbol("exceptions".to_string()),
            Child::Nil,
            Child::Nil,
        ],
    );
    let second = test_node(
        "RESBODY",
        vec![
            Child::Symbol("exceptions".to_string()),
            Child::Nil,
            Child::Nil,
        ],
    );
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

    let result = normalizer
        .link_rescue_chain(vec![first, second])
        .expect("expected linked rescue chain");

    assert_eq!(result.r#type, "RESBODY");
    let next = child_node(&result, 2);
    assert_eq!(next.r#type, "RESBODY");
    assert_eq!(next.children[2], Child::Nil);

    let short = test_node("RESBODY", vec![Child::Symbol("exceptions".to_string())]);
    let result = normalizer
        .link_rescue_chain(vec![short])
        .expect("expected padded rescue chain");

    assert_eq!(result.children.len(), 3);
    assert_eq!(result.children[1], Child::Nil);
    assert_eq!(result.children[2], Child::Nil);
}

#[test]
fn infix_statement_parts_extracts_allowed_wrapper_parts() {
    let source = "def calc\n  left + right\nend\n";
    let tree = raw_tree(source, Language::Ruby);
    let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
    let body = first_raw_node(tree.root_node(), source, "body_statement", "left + right");
    let binary = first_raw_node(tree.root_node(), source, "binary", "left + right");

    assert_eq!(
        infix_parts_text(&normalizer, body, source),
        Some(("left".to_string(), "+".to_string(), "right".to_string()))
    );
    assert_eq!(infix_parts_text(&normalizer, binary, source), None);

    let source = "def calc\n  return left + right\nend\n";
    let tree = raw_tree(source, Language::Ruby);
    let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
    let args = first_raw_node(tree.root_node(), source, "argument_list", "left + right");
    assert_eq!(
        infix_parts_text(&normalizer, args, source),
        Some(("left".to_string(), "+".to_string(), "right".to_string()))
    );

    let source = "def calc\n  left && right\nend\n";
    let tree = raw_tree(source, Language::Ruby);
    let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
    let boolean = first_raw_node(tree.root_node(), source, "body_statement", "left && right");
    assert_eq!(infix_parts_text(&normalizer, boolean, source), None);
}

#[test]
fn infix_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left + right",
        ),
        (
            "def calc\n  return left + right\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "left + right",
        ),
        (
            "def calc\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left && right",
        ),
        (
            "const value = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "value = left + right\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "local value = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.infix_statement(node),
            ruby_private_predicate(source, language, suffix, "infix_statement?", kind, text),
            "infix_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_infix_statement_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def calc\n  left + right\nend\n",
            "body_statement",
            "left + right",
        ),
        (
            "def calc\n  return left + right\nend\n",
            "argument_list",
            "left + right",
        ),
        (
            "def match\n  value =~ /left/\nend\n",
            "body_statement",
            "value =~ /left/",
        ),
        (
            "def match\n  value =~ pattern\nend\n",
            "body_statement",
            "value =~ pattern",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_infix_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_infix_statement",
                kind,
                text
            ),
            "normalize_infix_statement mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn regex_literal_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "value =~ /left/\n",
            Language::Ruby,
            ".rb",
            "regex",
            "/left/",
        ),
        (
            "value = \"left\"\n",
            Language::Ruby,
            ".rb",
            "string",
            "\"left\"",
        ),
        (
            "const pattern = /left/;\n",
            Language::TypeScript,
            ".ts",
            "regex",
            "/left/",
        ),
        (
            "pattern = r\"left\"\n",
            Language::Python,
            ".py",
            "string",
            "r\"left\"",
        ),
        (
            "local pattern = \"left\"\n",
            Language::Lua,
            ".lua",
            "string_content",
            "left",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.regex_literal(Some(node)),
            ruby_private_predicate(source, language, suffix, "regex_literal?", kind, text),
            "regex_literal? mismatch for {language:?} {kind} {text:?}"
        );
    }

    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    assert_eq!(
        normalizer.regex_literal(None),
        ruby_private_regex_literal_value("nil")
    );
    assert!(!ruby_private_regex_literal_value("string"));
    assert!(!ruby_private_regex_literal_value("normalized_node"));
}

#[test]
fn argument_list_unary_not_matches_ruby_private_predicate() {
    for (line, text) in [
        ("return !flag", "!flag"),
        ("return !!flag", "!!flag"),
        ("return flag", "flag"),
        ("return !flag, other", "!flag, other"),
        ("return (!flag)", "(!flag)"),
        ("return not flag", "not flag"),
    ] {
        let source = format!("def check\n  {line}\nend\n");
        let tree = raw_tree(&source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), &source, "argument_list", text);
        let normalizer = super::TreeSitterNormalizer::new(&source, Language::Ruby);

        assert_eq!(
            normalizer.argument_list_unary_not(node),
            ruby_private_predicate(
                &source,
                Language::Ruby,
                ".rb",
                "argument_list_unary_not?",
                "argument_list",
                text
            ),
            "argument_list_unary_not? mismatch for {line:?}"
        );
    }
}

#[test]
fn normalize_argument_list_unary_not_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  return !flag\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "!flag",
        ),
        (
            "def check\n  return !!flag\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "!!flag",
        ),
        (
            "def check\n  return flag\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "flag",
        ),
        (
            "def check\n  return !flag, other\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "!flag, other",
        ),
        (
            "def check():\n    return foo(not flag)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(not flag)",
        ),
        (
            "function check(){ return foo(!flag); }\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(!flag)",
        ),
        (
            "function check() return foo(not flag) end\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(not flag)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_argument_list_unary_not(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_argument_list_unary_not",
                kind,
                text
            ),
            "normalize_argument_list_unary_not mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn unary_not_statement_matches_ruby_private_predicate() {
    for (line, text) in [
        ("!flag", "!flag"),
        ("!!flag", "!!flag"),
        ("flag", "flag"),
        ("!flag; other", "!flag; other"),
        ("(!flag)", "(!flag)"),
        ("not flag", "not flag"),
    ] {
        let source = format!("def check\n  {line}\nend\n");
        let tree = raw_tree(&source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), &source, "body_statement", text);
        let normalizer = super::TreeSitterNormalizer::new(&source, Language::Ruby);

        assert_eq!(
            normalizer.unary_not_statement(node),
            ruby_private_predicate(
                &source,
                Language::Ruby,
                ".rb",
                "unary_not_statement?",
                "body_statement",
                text
            ),
            "unary_not_statement? mismatch for {line:?}"
        );
    }
}

#[test]
fn unary_not_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "!flag",
        ),
        (
            "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "!!flag",
        ),
        (
            "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "-flag",
        ),
        (
            "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "not flag",
        ),
        (
            "function check(flag: boolean) { return !flag; }\n",
            Language::TypeScript,
            ".ts",
            "unary_expression",
            "!flag",
        ),
        (
            "if not flag:\n    pass\n",
            Language::Python,
            ".py",
            "not_operator",
            "not flag",
        ),
        (
            "if not flag then end\n",
            Language::Lua,
            ".lua",
            "unary_expression",
            "not flag",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.unary_not_expression(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "unary_not_expression?",
                kind,
                text
            ),
            "unary_not_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_unary_not_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "!flag",
        ),
        (
            "def check\n  !flag\n  !!flag\n  -flag\n  not flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "!!flag",
        ),
        (
            "function check(flag: boolean) { return !flag; }\n",
            Language::TypeScript,
            ".ts",
            "unary_expression",
            "!flag",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_unary_not(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_unary_not",
                kind,
                text
            ),
            "normalize_unary_not mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_unary_not_statement_matches_ruby_private_method() {
    for (line, text) in [("!flag", "!flag"), ("!!flag", "!!flag")] {
        let source = format!("def check\n  {line}\nend\n");
        let tree = raw_tree(&source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), &source, "body_statement", text);
        let mut normalizer = super::TreeSitterNormalizer::new(&source, Language::Ruby);
        let rust = normalizer
            .normalize_unary_not_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                &source,
                Language::Ruby,
                ".rb",
                "normalize_unary_not_statement",
                "body_statement",
                text
            ),
            "normalize_unary_not_statement mismatch for {text:?}"
        );
    }
}

#[test]
fn unary_minus_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  -flag\n  !flag\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "-flag",
        ),
        (
            "def check\n  -flag\n  !flag\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "!flag",
        ),
        (
            "function check(value: number) { return -value; }\n",
            Language::TypeScript,
            ".ts",
            "unary_expression",
            "-value",
        ),
        (
            "x = -value\n",
            Language::Python,
            ".py",
            "unary_operator",
            "-value",
        ),
        (
            "local x = -value\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "-value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.unary_minus_expression(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "unary_minus_expression?",
                kind,
                text
            ),
            "unary_minus_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_unary_minus_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  -1\n  -flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "-1",
        ),
        (
            "def check\n  -1\n  -flag\nend\n",
            Language::Ruby,
            ".rb",
            "unary",
            "-flag",
        ),
        (
            "function check(value: number) { return -value; }\n",
            Language::TypeScript,
            ".ts",
            "unary_expression",
            "-value",
        ),
        (
            "x = -value\n",
            Language::Python,
            ".py",
            "unary_operator",
            "-value",
        ),
        (
            "local x = -value\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "-value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_unary_minus(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_unary_minus",
                kind,
                text
            ),
            "normalize_unary_minus mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn binary_operator_matches_ruby_private_helper() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left + right\n  left && right\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left + right",
        ),
        (
            "def calc\n  left + right\n  left && right\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left && right",
        ),
        (
            "def calc\n  left + right\n  left && right\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left + right\n  left && right\n  value",
        ),
        (
            "const value = left + right && other;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right && other",
        ),
        (
            "const value = left + right && other;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "value = left + right and other\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left + right and other",
        ),
        (
            "value = left + right and other\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "local value = left + right and other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right and other",
        ),
        (
            "local value = left + right and other\n",
            Language::Lua,
            ".lua",
            "binary_expression",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.binary_operator(node).unwrap_or_default(),
            ruby_private_string(source, language, suffix, "binary_operator", kind, text),
            "binary_operator mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn boolean_operator_matches_ruby_private_helper() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left && right\n  left || right\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left && right",
        ),
        (
            "def calc\n  left && right\n  left || right\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left || right",
        ),
        (
            "def calc\n  left && right\n  left || right\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left + right",
        ),
        (
            "const value = left && right || other;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left && right",
        ),
        (
            "const value = left && right || other;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left && right || other",
        ),
        (
            "value = left and right or other\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left and right",
        ),
        (
            "value = left and right or other\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left and right or other",
        ),
        (
            "local value = left and right or other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left and right or other",
        ),
        (
            "local value = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.boolean_operator(node).unwrap_or_default(),
            ruby_private_string(source, language, suffix, "boolean_operator", kind, text),
            "boolean_operator mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn comparison_operator_matches_ruby_private_helper() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left == right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left == right",
        ),
        (
            "def calc\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left + right",
        ),
        (
            "const value = left === right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left === right",
        ),
        (
            "const value = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "value = left == right\n",
            Language::Python,
            ".py",
            "comparison_operator",
            "left == right",
        ),
        (
            "value = left + right\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "local value = left == right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left == right",
        ),
        (
            "local value = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.comparison_operator(node).unwrap_or_default(),
            ruby_private_string(source, language, suffix, "comparison_operator", kind, text),
            "comparison_operator mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn comparison_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left == right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left == right",
        ),
        (
            "const value = left === right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left === right",
        ),
        (
            "const value = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "value = left == right\n",
            Language::Python,
            ".py",
            "comparison_operator",
            "left == right",
        ),
        (
            "value = left + right\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "local value = left == right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left == right",
        ),
        (
            "local value = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.comparison_expression(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "comparison_expression?",
                kind,
                text
            ),
            "comparison_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn comparison_expression_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("value = left == right\n", Language::Python, ".py"),
        (
            "const value = left === right;\n",
            Language::TypeScript,
            ".ts",
        ),
        ("local value = left == right\n", Language::Lua, ".lua"),
    ] {
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn normalize_comparison_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left == right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left == right",
        ),
        (
            "value = left == right\n",
            Language::Python,
            ".py",
            "comparison_operator",
            "left == right",
        ),
        (
            "const value = left === right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left === right",
        ),
        (
            "local value = left == right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left == right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_comparison(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_comparison",
                kind,
                text
            ),
            "normalize_comparison mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn boolean_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left && right",
        ),
        (
            "def calc\n  left or right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left or right",
        ),
        (
            "def calc\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left + right",
        ),
        (
            "foo(left && right)\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "(left && right)",
        ),
        (
            "value = left and right\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left and right",
        ),
        (
            "local value = left and right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left and right",
        ),
        (
            "const value = left && right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left && right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.boolean_statement(node),
            ruby_private_predicate(source, language, suffix, "boolean_statement?", kind, text),
            "boolean_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn boolean_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left && right",
        ),
        (
            "def calc\n  left && right\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left && right",
        ),
        (
            "def calc\n  left && right\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left + right",
        ),
        (
            "const value = left && right;\nconst other = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left && right",
        ),
        (
            "const value = left && right;\nconst other = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "value = left and right\nother = left + right\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left and right",
        ),
        (
            "value = left and right\nother = left + right\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "local value = left and right\nlocal other = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left and right",
        ),
        (
            "local value = left and right\nlocal other = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.boolean_expression(node),
            ruby_private_predicate(source, language, suffix, "boolean_expression?", kind, text),
            "boolean_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_boolean_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left && right",
        ),
        (
            "def calc\n  left || right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left || right",
        ),
        (
            "def calc\n  left && middle && right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left && middle && right",
        ),
        (
            "value = left and right\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left and right",
        ),
        (
            "value = left or right\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left or right",
        ),
        (
            "local value = left and right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left and right",
        ),
        (
            "local value = left or right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left or right",
        ),
        (
            "const value = left && right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left && right",
        ),
        (
            "const value = left || right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left || right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_boolean(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_boolean",
                kind,
                text
            ),
            "normalize_boolean mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn boolean_expression_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def calc\n  left && right\nend\n", Language::Ruby, ".rb"),
        ("value = left and right\n", Language::Python, ".py"),
        ("local value = left and right\n", Language::Lua, ".lua"),
        (
            "const value = left && right;\n",
            Language::TypeScript,
            ".ts",
        ),
    ] {
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn operator_call_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left + right\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left + right",
        ),
        (
            "def calc\n  left + right\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "binary",
            "left && right",
        ),
        (
            "const value = left + right && other;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "const value = left + right && other;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right && other",
        ),
        (
            "value = left + right and other\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "value = left + right and other\n",
            Language::Python,
            ".py",
            "boolean_operator",
            "left + right and other",
        ),
        (
            "local value = left + right\nlocal other = left and right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
        (
            "local value = left + right\nlocal other = left and right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left and right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.operator_call_expression(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "operator_call_expression?",
                kind,
                text
            ),
            "operator_call_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_operator_call_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left + right",
        ),
        (
            "def calc\n  left =~ /right/\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left =~ /right/",
        ),
        (
            "def calc\n  left =~ pattern\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left =~ pattern",
        ),
        (
            "value = left + right\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "const value = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "local value = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_operator_call(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_operator_call",
                kind,
                text
            ),
            "normalize_operator_call mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn operator_call_expression_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("value = left + right\n", Language::Python, ".py"),
        ("local value = left + right\n", Language::Lua, ".lua"),
        ("const value = left + right;\n", Language::TypeScript, ".ts"),
    ] {
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn spaced_text_matches_ruby_private_helper() {
    for (source, language, suffix, kind, text) in [
        (
            "def calc\n  left + right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left + right",
        ),
        (
            "const value = left + right;\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "left + right",
        ),
        (
            "value = left + right\n",
            Language::Python,
            ".py",
            "binary_operator",
            "left + right",
        ),
        (
            "local value = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.spaced_text(node),
            ruby_private_string(source, language, suffix, "spaced_text", kind, text),
            "spaced_text mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn class_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "class Thing; end\n",
            Language::Ruby,
            ".rb",
            "class",
            "class Thing; end",
        ),
        (
            "class Thing:\n    pass\n",
            Language::Python,
            ".py",
            "class_definition",
            "class Thing:\n    pass",
        ),
        (
            "class Thing {}\n",
            Language::TypeScript,
            ".ts",
            "class_declaration",
            "class Thing {}",
        ),
        (
            "local Thing = {}\n",
            Language::Lua,
            ".lua",
            "variable_declaration",
            "local Thing = {}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.class_node(node),
            ruby_private_predicate(source, language, suffix, "class_node?", kind, text),
            "class_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn module_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "module Thing\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "module",
            "module Thing\n  value\nend",
        ),
        (
            "class Thing; end\n",
            Language::Ruby,
            ".rb",
            "class",
            "class Thing; end",
        ),
        (
            "value = 1\n",
            Language::Python,
            ".py",
            "module",
            "value = 1\n",
        ),
        (
            "namespace Thing { const value = 1; }\n",
            Language::TypeScript,
            ".ts",
            "program",
            "namespace Thing { const value = 1; }\n",
        ),
        (
            "local Thing = {}\n",
            Language::Lua,
            ".lua",
            "chunk",
            "local Thing = {}\n",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.module_node(node),
            ruby_private_predicate(source, language, suffix, "module_node?", kind, text),
            "module_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_module_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "module Thing\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "module",
            "module Thing\n  value\nend",
        ),
        (
            "module Empty\nend\n",
            Language::Ruby,
            ".rb",
            "module",
            "module Empty\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_module(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_module",
                kind,
                text
            ),
            "normalize_module mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_singleton_class_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class << self\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "singleton_class",
            "class << self\n  value\nend",
        ),
        (
            "class << object\nend\n",
            Language::Ruby,
            ".rb",
            "singleton_class",
            "class << object\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_singleton_class(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_singleton_class",
                kind,
                text
            ),
            "normalize_singleton_class mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_definition_identifier_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def helper(arg)\n  arg\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "helper",
        ),
        (
            "def helper(arg)\n  arg\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "arg",
        ),
        (
            "items.each { |item| item }\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "item",
        ),
        (
            "def helper\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value",
        ),
        (
            "def helper(arg):\n    return arg\n",
            Language::Python,
            ".py",
            "identifier",
            "arg",
        ),
        (
            "function helper(arg) { return arg; }\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "arg",
        ),
        (
            "function helper(arg)\n  return arg\nend\n",
            Language::Lua,
            ".lua",
            "identifier",
            "arg",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.ruby_definition_identifier(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "ruby_definition_identifier?",
                kind,
                text
            ),
            "ruby_definition_identifier? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn literal_fragment_assignment_context_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "value = \"left = right\"\n",
            Language::Ruby,
            ".rb",
            "string_content",
            "left = right",
        ),
        ("value = 1\n", Language::Ruby, ".rb", "identifier", "value"),
        (
            "value = \"left = right\"\n",
            Language::Python,
            ".py",
            "string_content",
            "left = right",
        ),
        (
            "const value = \"left = right\";\n",
            Language::TypeScript,
            ".ts",
            "string_fragment",
            "left = right",
        ),
        (
            "local value = \"left = right\"\n",
            Language::Lua,
            ".lua",
            "string_content",
            "left = right",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.literal_fragment_assignment_context(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "literal_fragment_assignment_context?",
                kind,
                text
            ),
            "literal_fragment_assignment_context? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_lhs_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "other",
        ),
        (
            "{ key: value }\n",
            Language::Ruby,
            ".rb",
            "hash_key_symbol",
            "key",
        ),
        (
            "{ key: value }\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "identifier",
            "other",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "other",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "variable_declarator",
            "value = other",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.assignment_lhs(node),
            ruby_private_predicate(source, language, suffix, "assignment_lhs?", kind, text),
            "assignment_lhs? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_rhs_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "other",
        ),
        (
            "{ key: value }\n",
            Language::Ruby,
            ".rb",
            "hash_key_symbol",
            "key",
        ),
        (
            "{ key: value }\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "identifier",
            "other",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "other",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "variable_declarator",
            "value = other",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.assignment_rhs(node),
            ruby_private_predicate(source, language, suffix, "assignment_rhs?", kind, text),
            "assignment_rhs? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_assignment_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "value = 1\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "value = 1",
        ),
        (
            "value += 1\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value += 1",
        ),
        (
            "def helper\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value",
        ),
        (
            "[1].each { |item| local = item }\n",
            Language::Ruby,
            ".rb",
            "block_body",
            "local = item",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.ruby_assignment_node(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "ruby_assignment_node?",
                kind,
                text
            ),
            "ruby_assignment_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn collect_assignment_target_names_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "left, *rest = values\n",
            Language::Ruby,
            ".rb",
            "left_assignment_list",
            "left, *rest",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let mut names = BTreeSet::new();
        normalizer.collect_assignment_target_names(node, &mut names);

        assert_eq!(
            names,
            ruby_private_collected_names(
                source,
                language,
                suffix,
                "collect_assignment_target_names",
                kind,
                text
            ),
            "collect_assignment_target_names mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn collect_identifier_names_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "left, *rest = values\n",
            Language::Ruby,
            ".rb",
            "left_assignment_list",
            "left, *rest",
        ),
        (
            "receiver.call(argument)\n",
            Language::Ruby,
            ".rb",
            "call",
            "receiver.call(argument)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let mut names = BTreeSet::new();
        normalizer.collect_identifier_names(node, &mut names);

        assert_eq!(
            names,
            ruby_private_collected_names(
                source,
                language,
                suffix,
                "collect_identifier_names",
                kind,
                text
            ),
            "collect_identifier_names mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn member_name_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("user.name\n", Language::Ruby, ".rb", "identifier", "name"),
        ("user&.name\n", Language::Ruby, ".rb", "identifier", "name"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "identifier",
            "name",
        ),
        (
            "user?.name;\n",
            Language::TypeScript,
            ".ts",
            "property_identifier",
            "name",
        ),
        ("user.name()\n", Language::Lua, ".lua", "identifier", "name"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.member_name(node),
            ruby_private_string(source, language, suffix, "member_name", kind, text),
            "member_name mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn member_parts_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user.name(thing)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user.name(thing)",
        ),
        (
            "user.name();\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name(thing);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "user.name(thing)",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.member_parts(node).map(|(receiver, method)| {
            (
                receiver.kind().to_string(),
                super::node_text(receiver, source).to_string(),
                method,
            )
        });

        assert_eq!(
            rust,
            ruby_private_member_parts(source, language, suffix, kind, text),
            "member_parts mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn member_read_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        ("foo()\n", Language::Ruby, ".rb", "call", "foo()"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user.name(thing)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user.name(thing)",
        ),
        (
            "user.name();\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name(thing);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "user.name(thing)",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.member_read_node(node),
            ruby_private_predicate(source, language, suffix, "member_read_node?", kind, text),
            "member_read_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_member_read_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user.name;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
        ("value\n", Language::Ruby, ".rb", "identifier", "value"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_member_read(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_member_read",
                kind,
                text
            ),
            "normalize_member_read mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_left_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "value = other",
        ),
        (
            "left, right = values\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "left, right = values",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value = other",
        ),
        (
            "value = other;\n",
            Language::TypeScript,
            ".ts",
            "assignment_expression",
            "value = other",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "assignment_statement",
            "value = other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.assignment_left(node).map(|left| {
            (
                left.kind().to_string(),
                super::node_text(left, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(source, language, suffix, "assignment_left", kind, text),
            "assignment_left mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_right_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "value = other",
        ),
        (
            "left, right = values\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "left, right = values",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value = other",
        ),
        (
            "value = other;\n",
            Language::TypeScript,
            ".ts",
            "assignment_expression",
            "value = other",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "assignment_statement",
            "value = other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.assignment_right(node).map(|right| {
            (
                right.kind().to_string(),
                super::node_text(right, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(source, language, suffix, "assignment_right", kind, text),
            "assignment_right mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn singleton_receiver_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def self.foo\nend\n",
            "singleton_method",
            "def self.foo\nend",
        ),
        (
            "def User.foo\nend\n",
            "singleton_method",
            "def User.foo\nend",
        ),
        (
            "def object.foo\nend\n",
            "singleton_method",
            "def object.foo\nend",
        ),
        (
            "def self.foo(value)\n  value\nend\n",
            "singleton_method",
            "def self.foo(value)\n  value\nend",
        ),
        (
            "def object.foo\n  value\nend\n",
            "singleton_method",
            "def object.foo\n  value\nend",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer.singleton_receiver(node).map(|receiver| {
            (
                receiver.kind().to_string(),
                super::node_text(receiver, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(
                source,
                Language::Ruby,
                ".rb",
                "singleton_receiver",
                kind,
                text
            ),
            "singleton_receiver mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn singleton_name_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def self.foo\nend\n",
            "singleton_method",
            "def self.foo\nend",
        ),
        (
            "def User.foo\nend\n",
            "singleton_method",
            "def User.foo\nend",
        ),
        (
            "def object.foo\nend\n",
            "singleton_method",
            "def object.foo\nend",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

        assert_eq!(
            normalizer.singleton_name(node),
            ruby_private_string(source, Language::Ruby, ".rb", "singleton_name", kind, text),
            "singleton_name mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_singleton_function_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def self.hidden(value)\n  return value\nend\n",
            "singleton_method",
            "def self.hidden(value)\n  return value\nend",
        ),
        (
            "def User.hidden\nend\n",
            "singleton_method",
            "def User.hidden\nend",
        ),
        (
            "def object.hidden\n  value\nend\n",
            "singleton_method",
            "def object.hidden\n  value\nend",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_singleton_function(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_singleton_function",
                kind,
                text
            ),
            "normalize_singleton_function mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_function_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def check(value)\n  return value\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def check(value)\n  return value\nend",
        ),
        (
            "def empty\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def empty\nend",
        ),
        (
            "def object.hidden\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "singleton_method",
            "def object.hidden\n  value\nend",
        ),
        (
            "def check(value):\n    return value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def check(value):\n    return value",
        ),
        (
            "function check(value) { return value; }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function check(value) { return value; }",
        ),
        (
            "class Box { check(value) { return value; } }\n",
            Language::TypeScript,
            ".ts",
            "method_definition",
            "check(value) { return value; }",
        ),
        (
            "function check(value)\n  return value\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function check(value)\n  return value\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_function(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_function",
                kind,
                text
            ),
            "normalize_function mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn lambda_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "fn = ->(x) { x + 1 }\n",
            Language::Ruby,
            ".rb",
            "lambda",
            "->(x) { x + 1 }",
        ),
        (
            "fn = lambda x: x + 1\n",
            Language::Python,
            ".py",
            "lambda",
            "lambda x: x + 1",
        ),
        (
            "const fn = (x) => x + 1;\n",
            Language::TypeScript,
            ".ts",
            "arrow_function",
            "(x) => x + 1",
        ),
        (
            "const fn = function(x) { return x + 1; };\n",
            Language::TypeScript,
            ".ts",
            "function_expression",
            "function(x) { return x + 1; }",
        ),
        (
            "local fn = function(x) return x + 1 end\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "function(x) return x + 1 end",
        ),
        (
            "function f(x) return x + 1 end\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f(x) return x + 1 end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.lambda_expression(node),
            ruby_private_predicate(source, language, suffix, "lambda_expression?", kind, text),
            "lambda_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_lambda_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "fn = ->(x) { x + 1 }\n",
            Language::Ruby,
            ".rb",
            "lambda",
            "->(x) { x + 1 }",
        ),
        (
            "fn = lambda x: x + 1\n",
            Language::Python,
            ".py",
            "lambda",
            "lambda x: x + 1",
        ),
        (
            "const fn = (x) => x + 1;\n",
            Language::TypeScript,
            ".ts",
            "arrow_function",
            "(x) => x + 1",
        ),
        (
            "const fn = function(x) { return x + 1; };\n",
            Language::TypeScript,
            ".ts",
            "function_expression",
            "function(x) { return x + 1; }",
        ),
        (
            "local fn = function(x) return x + 1 end\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "function(x) return x + 1 end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_lambda(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_lambda",
                kind,
                text
            ),
            "normalize_lambda mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn lambda_expression_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("fn = ->(x) { x + 1 }\n", Language::Ruby, ".rb"),
        ("fn = lambda x: x + 1\n", Language::Python, ".py"),
        ("const fn = (x) => x + 1;\n", Language::TypeScript, ".ts"),
        (
            "const fn = function(x) { return x + 1; };\n",
            Language::TypeScript,
            ".ts",
        ),
        (
            "local fn = function(x) return x + 1 end\n",
            Language::Lua,
            ".lua",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut lambdas = Vec::new();
        nodes_of_type(&root, "LAMBDA", &mut lambdas);
        assert!(
            !lambdas.is_empty(),
            "expected LAMBDA for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn function_name_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def run\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def run\nend",
        ),
        (
            "def self.run\nend\n",
            Language::Ruby,
            ".rb",
            "singleton_method",
            "def self.run\nend",
        ),
        (
            "def run():\n    pass\n",
            Language::Python,
            ".py",
            "function_definition",
            "def run():\n    pass",
        ),
        (
            "function run() {}\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function run() {}",
        ),
        (
            "class Box { run() {} }\n",
            Language::TypeScript,
            ".ts",
            "method_definition",
            "run() {}",
        ),
        (
            "function run()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function run()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.function_name(node).unwrap_or_default(),
            ruby_private_string(source, language, suffix, "function_name", kind, text),
            "function_name mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn collect_destructured_parameter_targets_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "items.each { |(left, right)| left }\n",
            "destructured_parameter",
            "(left, right)",
        ),
        (
            "items.each do |(left, (middle, right))| left end\n",
            "destructured_parameter",
            "(left, (middle, right))",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let mut targets = Vec::new();
        normalizer.collect_destructured_parameter_targets(node, &mut targets);
        let rust = Value::Array(targets.iter().map(node_value).collect());

        assert_eq!(
            rust,
            ruby_private_destructured_parameter_targets_value(source, kind, text),
            "collect_destructured_parameter_targets mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_block_parameters_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "items.each { |(left, right)| left }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ |(left, right)| left }",
        ),
        (
            "items.each { |item, (left, right)| item }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ |item, (left, right)| item }",
        ),
        (
            "items.each { |item| item }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ |item| item }",
        ),
        (
            "def f(x):\n    pass\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f(x):\n    pass",
        ),
        (
            "items.forEach((item) => item);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "items.forEach((item) => item);",
        ),
        (
            "function f(x)\n  return x\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f(x)\n  return x\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_block_parameters(Some(node))
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_block_parameters",
                kind,
                text
            ),
            "normalize_block_parameters mismatch for {language:?} {kind} {text:?}"
        );
    }

    let mut normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    assert!(normalizer.normalize_block_parameters(None).is_none());
}

#[test]
fn normalize_parameters_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(value = 1)\nend\n",
            Language::Ruby,
            ".rb",
            "method_parameters",
            "(value = 1)",
        ),
        (
            "def f(value)\nend\n",
            Language::Ruby,
            ".rb",
            "method_parameters",
            "(value)",
        ),
        (
            "def f(value=1):\n    pass\n",
            Language::Python,
            ".py",
            "parameters",
            "(value=1)",
        ),
        (
            "function f(value = 1) {}\n",
            Language::TypeScript,
            ".ts",
            "formal_parameters",
            "(value = 1)",
        ),
        (
            "function f(value)\nend\n",
            Language::Lua,
            ".lua",
            "parameters",
            "(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_parameters(Some(node))
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_parameters",
                kind,
                text
            ),
            "normalize_parameters mismatch for {language:?} {kind} {text:?}"
        );
    }

    let mut normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    assert!(normalizer.normalize_parameters(None).is_none());
}

#[test]
fn normalize_destructured_block_parameter_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "items.each { |(left, right)| left }\n",
            "destructured_parameter",
            "(left, right)",
        ),
        (
            "items.each do |(left, (middle, right))| left end\n",
            "destructured_parameter",
            "(left, (middle, right))",
        ),
        ("items.each { |item| item }\n", "identifier", "item"),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_destructured_block_parameter(node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_destructured_block_parameter",
                kind,
                text
            ),
            "normalize_destructured_block_parameter mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn scope_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, mode) in [
        ("1\n", Language::Ruby, ".rb", "integer", "1", "body"),
        (
            "1\n",
            Language::Python,
            ".py",
            "expression_statement",
            "1",
            "body",
        ),
        (
            "value;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
            "args",
        ),
        (
            "return value\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "value",
            "empty",
        ),
    ] {
        let tree = raw_tree(source, language);
        let root = tree.root_node();
        let node = first_raw_node(root, source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        normalizer.root_span = Some(super::span(root));
        let body = if mode == "body" {
            Some(normalizer.wrap("BODY", Vec::new(), node))
        } else {
            None
        };
        let args = if mode == "args" {
            Some(normalizer.wrap("ARGS", Vec::new(), node))
        } else {
            None
        };
        let rust = node_value(&normalizer.scope(body, args, node));

        assert_eq!(
            rust,
            ruby_private_scope_value(source, language, suffix, kind, text, mode),
            "scope mismatch for {language:?} {kind} {text:?} mode {mode}"
        );
    }
}

#[test]
fn list_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, mode) in [
        (
            "value\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
            "one",
        ),
        (
            "value\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value",
            "empty",
        ),
        (
            "value;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
            "nil",
        ),
        (
            "return value\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "value",
            "one",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let item = normalizer.wrap("ITEM", Vec::new(), node);
        let children = match mode {
            "nil" => None,
            "empty" => Some(Vec::new()),
            "one" => Some(vec![item]),
            _ => panic!("unknown list mode: {mode}"),
        };
        let rust = normalizer
            .list(children, node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_list_value(source, language, suffix, kind, text, mode),
            "list mismatch for {language:?} {kind} {text:?} mode {mode}"
        );
    }
}

#[test]
fn unwrap_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  (value)\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "parenthesized_statements",
            "(value)",
        ),
        (
            "value\n(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value",
        ),
        (
            "value\n(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "(value)",
        ),
        (
            "const value = (other);\n",
            Language::TypeScript,
            ".ts",
            "parenthesized_expression",
            "(other)",
        ),
        (
            "local first = (other)\nlocal second = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "(other)",
        ),
        (
            "local first = (other)\nlocal second = left + right\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "left + right",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.unwrap_node(node),
            ruby_private_predicate(source, language, suffix, "unwrap_node?", kind, text),
            "unwrap_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn statement_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  return value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "return value",
        ),
        (
            "def check\n  return value\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "check",
        ),
        (
            "value\n(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "(value)",
        ),
        (
            "value\n(value)\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "function check() { return value + other; }\n",
            Language::TypeScript,
            ".ts",
            "return_statement",
            "return value + other;",
        ),
        (
            "function check() { return value + other; }\n",
            Language::TypeScript,
            ".ts",
            "binary_expression",
            "value + other",
        ),
        (
            "function check() { return value + other; }\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "return value\n",
            Language::Lua,
            ".lua",
            "return_statement",
            "return value",
        ),
        (
            "return value\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.statement_node(node.kind()),
            ruby_private_predicate(source, language, suffix, "statement_node?", kind, text),
            "statement_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn local_identifier_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\nend\nclass Thing; end\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "check",
        ),
        (
            "def check\nend\nclass Thing; end\n",
            Language::Ruby,
            ".rb",
            "constant",
            "Thing",
        ),
        (
            "def check(value):\n    pass\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "def check(value):\n    pass\n",
            Language::Python,
            ".py",
            "parameters",
            "(value)",
        ),
        (
            "const value = object.field;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "const value = object.field;\n",
            Language::TypeScript,
            ".ts",
            "property_identifier",
            "field",
        ),
        (
            "const value = object.field;\n",
            Language::TypeScript,
            ".ts",
            "lexical_declaration",
            "const value = object.field;",
        ),
        (
            "local value = other\nprint(value)\n",
            Language::Lua,
            ".lua",
            "identifier",
            "value",
        ),
        (
            "local value = other\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.identifier_kind(node.kind()),
            ruby_private_predicate(source, language, suffix, "local_identifier?", kind, text),
            "local_identifier? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_local_name_matches_scope_stack_lookup() {
    let mut normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    normalizer.local_stack = vec![
        BTreeSet::from(["outer".to_string(), "shared".to_string()]),
        BTreeSet::from(["inner".to_string()]),
    ];

    assert!(normalizer.ruby_local_name("outer"));
    assert!(normalizer.ruby_local_name("inner"));
    assert!(normalizer.ruby_local_name("shared"));
    assert!(!normalizer.ruby_local_name("missing"));
}

#[test]
fn ruby_vcall_identifier_matches_ruby_private_predicate() {
    let cases = vec![
        (
            "ruby_vcall",
            "foo\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "ruby_local",
            "foo\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            vec!["foo"],
        ),
        (
            "assignment_lhs",
            "foo = 1\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "method_name",
            "def foo\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "parameter",
            "def f(foo)\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "non_identifier",
            "Thing\n",
            Language::Ruby,
            ".rb",
            "constant",
            "Thing",
            Vec::<&str>::new(),
        ),
        (
            "non_ruby",
            "foo\n",
            Language::Python,
            ".py",
            "expression_statement",
            "foo",
            Vec::<&str>::new(),
        ),
    ];

    for (label, source, language, suffix, kind, text, locals) in cases {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        if !locals.is_empty() {
            normalizer
                .local_stack
                .push(locals.iter().map(|name| name.to_string()).collect());
        }

        assert_eq!(
            normalizer.ruby_vcall_identifier(node, super::node_text(node, source)),
            ruby_private_ruby_vcall_identifier_predicate(
                source, language, suffix, kind, text, &locals,
            ),
            "ruby_vcall_identifier? mismatch for {label}"
        );
    }
}

#[test]
fn vcall_identifier_matches_ruby_private_predicate() {
    let cases = vec![
        (
            "ruby_modifier_action",
            "foo if cond\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "ruby_local",
            "foo if cond\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            vec!["foo"],
        ),
        (
            "method_name",
            "def foo\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "argument",
            "call(foo)\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "member_read",
            "def f\n  user.name\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "name",
            Vec::<&str>::new(),
        ),
        (
            "assignment_lhs",
            "foo = bar\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "python_identifier",
            "foo\n",
            Language::Python,
            ".py",
            "expression_statement",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "typescript_identifier",
            "foo;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "lua_identifier",
            "foo()\n",
            Language::Lua,
            ".lua",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
    ];

    for (label, source, language, suffix, kind, text, locals) in cases {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        if !locals.is_empty() {
            normalizer
                .local_stack
                .push(locals.iter().map(|name| name.to_string()).collect());
        }

        assert_eq!(
            normalizer.vcall_identifier(node, super::node_text(node, source)),
            ruby_private_vcall_identifier_predicate(source, language, suffix, kind, text, &locals,),
            "vcall_identifier? mismatch for {label}"
        );
    }

    let source = "def f\n  Thing\nend\n";
    let tree = raw_tree(source, Language::Ruby);
    let node = first_raw_node(tree.root_node(), source, "constant", "Thing");
    let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
    assert!(
        !normalizer.vcall_identifier(node, super::node_text(node, source)),
        "vcall_identifier? must reject non-local identifiers in statement wrappers"
    );

    let source = "foo\n";
    let tree = raw_tree(source, Language::Python);
    let node = first_raw_node(tree.root_node(), source, "identifier", "foo");
    let normalizer = super::TreeSitterNormalizer::new(source, Language::Python);
    assert!(
        !normalizer.vcall_identifier(node, super::node_text(node, source)),
        "vcall_identifier? must reject Python bare identifiers"
    );
}

#[test]
fn collect_ruby_parameter_locals_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def f(a, b = 1, *rest, key:, **opts, &block)\nend\n",
            "method_parameters",
            "(a, b = 1, *rest, key:, **opts, &block)",
        ),
        (
            "[1].each { |item, (left, right)| item }\n",
            "block_parameters",
            "|item, (left, right)|",
        ),
        ("fn = ->(x, y:) { x }\n", "lambda_parameters", "(x, y:)"),
        ("value = other\n", "assignment", "value = other"),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let mut locals = BTreeSet::new();
        normalizer.collect_ruby_parameter_locals(node, &mut locals);

        assert_eq!(
            locals,
            ruby_private_collected_names(
                source,
                Language::Ruby,
                ".rb",
                "collect_ruby_parameter_locals",
                kind,
                text
            ),
            "collect_ruby_parameter_locals mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn collect_ruby_assignment_locals_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "value = other",
        ),
        (
            "left, *rest = values\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "left, *rest = values",
        ),
        (
            "value += 1\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value += 1",
        ),
        (
            "begin\n  work\nrescue => error\n  error\nend\n",
            Language::Ruby,
            ".rb",
            "exception_variable",
            "=> error",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let mut locals = BTreeSet::new();
        normalizer.collect_ruby_assignment_locals(node, &mut locals);

        assert_eq!(
            locals,
            ruby_private_collected_names(
                source,
                language,
                suffix,
                "collect_ruby_assignment_locals",
                kind,
                text
            ),
            "collect_ruby_assignment_locals mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn collect_ruby_scope_locals_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, root) in [
            (
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend",
                true,
            ),
            (
                "def outer(a)\n  local = 1\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def outer(a)\n  local = 1\nend",
                false,
            ),
            (
                "[1].each { |item| local = item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| local = item }",
                true,
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);
            let mut locals = BTreeSet::new();
            normalizer.collect_ruby_scope_locals(node, &mut locals, root);

            assert_eq!(
                locals,
                ruby_private_scope_collected_names(source, language, suffix, kind, text, root),
                "collect_ruby_scope_locals mismatch for {language:?} {kind} {text:?} root={root}"
            );
        }
}

#[test]
fn ruby_scope_locals_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
            (
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend\n",
                Language::Ruby,
                ".rb",
                "method",
                "def outer(a)\n  local = 1\n  items.each { |item| nested = item }\n  def inner(inner_arg)\n    inner_local = 1\n  end\nend",
            ),
            (
                "[1].each { |item| local = item }\n",
                Language::Ruby,
                ".rb",
                "block",
                "{ |item| local = item }",
            ),
        ] {
            let tree = raw_tree(source, language);
            let node = first_raw_node(tree.root_node(), source, kind, text);
            let normalizer = super::TreeSitterNormalizer::new(source, language);

            assert_eq!(
                normalizer.ruby_scope_locals(node),
                ruby_private_ruby_scope_locals(source, language, suffix, kind, text),
                "ruby_scope_locals mismatch for {language:?} {kind} {text:?}"
            );
        }
}

#[test]
fn with_ruby_scope_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, reset, initial_stack) in [
        (
            "def f(a)\n  local = 1\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a)\n  local = 1\nend",
            false,
            vec![vec!["outer"]],
        ),
        (
            "def f(a)\n  local = 1\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a)\n  local = 1\nend",
            true,
            vec![vec!["outer"]],
        ),
        (
            "[1].each { |item| local = item }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ |item| local = item }",
            false,
            vec![],
        ),
        (
            "def f(value):\n    local = value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f(value):\n    local = value",
            true,
            vec![vec!["outer"]],
        ),
        (
            "function f(value) { let local = value; }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function f(value) { let local = value; }",
            true,
            vec![vec!["outer"]],
        ),
        (
            "function f(value)\n  local local_value = value\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f(value)\n  local local_value = value\nend",
            true,
            vec![vec!["outer"]],
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        normalizer.local_stack = local_stack_from(&initial_stack);
        let before = local_stack_value(&normalizer.local_stack);
        let inside = normalizer.with_ruby_scope(node, reset, |normalizer| {
            local_stack_value(&normalizer.local_stack)
        });
        let after = local_stack_value(&normalizer.local_stack);
        let rust = json!({
            "before": before,
            "inside": inside,
            "after": after,
            "result": "block-result",
        });

        assert_eq!(
            rust,
            ruby_private_with_ruby_scope_trace(
                source,
                language,
                suffix,
                kind,
                text,
                reset,
                &initial_stack,
            ),
            "with_ruby_scope mismatch for {language:?} {kind} {text:?} reset={reset}"
        );
    }
}

#[test]
fn ruby_scope_boundary_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f\n  value\nend",
        ),
        (
            "class Box\nend\n",
            Language::Ruby,
            ".rb",
            "class",
            "class Box\nend",
        ),
        (
            "module Admin\nend\n",
            Language::Ruby,
            ".rb",
            "module",
            "module Admin\nend",
        ),
        (
            "items.each { |item| item }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ |item| item }",
        ),
        (
            "handler = -> { value }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ value }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.ruby_scope_boundary(node),
            ruby_private_predicate(source, language, suffix, "ruby_scope_boundary?", kind, text),
            "ruby_scope_boundary? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_scope_child_boundary_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f\n  value\nend",
        ),
        (
            "class Box\nend\n",
            Language::Ruby,
            ".rb",
            "class",
            "class Box\nend",
        ),
        (
            "module Admin\nend\n",
            Language::Ruby,
            ".rb",
            "module",
            "module Admin\nend",
        ),
        (
            "items.each { |item| item }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ |item| item }",
        ),
        (
            "handler = -> { value }\n",
            Language::Ruby,
            ".rb",
            "block",
            "{ value }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.ruby_scope_child_boundary(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "ruby_scope_child_boundary?",
                kind,
                text
            ),
            "ruby_scope_child_boundary? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_predicate_uses_normalization_adapter() {
    for (language, expected) in [
        (Language::Ruby, true),
        (Language::Python, false),
        (Language::Lua, false),
        (Language::TypeScript, false),
    ] {
        let normalizer = super::TreeSitterNormalizer::new("", language);

        assert_eq!(
            normalizer.ruby(),
            expected,
            "ruby? mismatch for {language:?}"
        );
    }
}

#[test]
fn interpolated_string_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "name = \"hi #{user}\"\nplain = \"hi\"\n",
            Language::Ruby,
            ".rb",
            "string",
            "\"hi #{user}\"",
        ),
        (
            "name = \"hi #{user}\"\nplain = \"hi\"\n",
            Language::Ruby,
            ".rb",
            "string",
            "\"hi\"",
        ),
        (
            "name = f\"hi {user}\"\nplain = \"hi\"\n",
            Language::Python,
            ".py",
            "string",
            "f\"hi {user}\"",
        ),
        (
            "name = f\"hi {user}\"\nplain = \"hi\"\n",
            Language::Python,
            ".py",
            "string",
            "\"hi\"",
        ),
        (
            "const name = `hi ${user}`;\nconst plain = `hi`;\n",
            Language::TypeScript,
            ".ts",
            "template_string",
            "`hi ${user}`",
        ),
        (
            "const name = `hi ${user}`;\nconst plain = `hi`;\n",
            Language::TypeScript,
            ".ts",
            "template_string",
            "`hi`",
        ),
        (
            "local name = \"hi\"\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "\"hi\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.interpolated_string(node),
            ruby_private_predicate(source, language, suffix, "interpolated_string?", kind, text),
            "interpolated_string? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_interpolated_string_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "name = \"hi #{user}\"\n",
            Language::Ruby,
            ".rb",
            "string",
            "\"hi #{user}\"",
        ),
        (
            "name = f\"hi {user}\"\n",
            Language::Python,
            ".py",
            "string",
            "f\"hi {user}\"",
        ),
        (
            "const name = `hi ${user}`;\n",
            Language::TypeScript,
            ".ts",
            "template_string",
            "`hi ${user}`",
        ),
        (
            "local name = \"hi\"\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "\"hi\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = node_value(&normalizer.normalize_interpolated_string(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_interpolated_string",
                kind,
                text
            ),
            "normalize_interpolated_string mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_subshell_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = `echo hi`\n",
            Language::Ruby,
            ".rb",
            "subshell",
            "`echo hi`",
        ),
        (
            "value = `echo #{name}`\n",
            Language::Ruby,
            ".rb",
            "subshell",
            "`echo #{name}`",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = node_value(&normalizer.normalize_subshell(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_subshell",
                kind,
                text
            ),
            "normalize_subshell mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn const_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "class Thing; end\ndef check; end\n",
            Language::Ruby,
            ".rb",
            "constant",
            "Thing",
        ),
        (
            "class Thing; end\ndef check; end\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "check",
        ),
        (
            "class Thing:\n    pass\n",
            Language::Python,
            ".py",
            "identifier",
            "Thing",
        ),
        (
            "type Thing = Other;\nconst value = Thing;\n",
            Language::TypeScript,
            ".ts",
            "type_identifier",
            "Thing",
        ),
        (
            "type Thing = Other;\nconst value = Thing;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "local Thing = {}\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "Thing",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.const_kind(node.kind()),
            ruby_private_predicate(source, language, suffix, "const_node?", kind, text),
            "const_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn self_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        ("self\nother\n", Language::Ruby, ".rb", "self", "self"),
        (
            "self\nother\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "other",
        ),
        (
            "self.value\nother.value\n",
            Language::Python,
            ".py",
            "identifier",
            "self",
        ),
        (
            "self.value\nother.value\n",
            Language::Python,
            ".py",
            "identifier",
            "other",
        ),
        (
            "this.value;\nother;\n",
            Language::TypeScript,
            ".ts",
            "this",
            "this",
        ),
        (
            "this.value;\nother;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "other",
        ),
        (
            "print(self.value)\nprint(other.value)\n",
            Language::Lua,
            ".lua",
            "identifier",
            "self",
        ),
        (
            "print(self.value)\nprint(other.value)\n",
            Language::Lua,
            ".lua",
            "identifier",
            "other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.self_node(node),
            ruby_private_predicate(source, language, suffix, "self_node?", kind, text),
            "self_node? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn instance_variable_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "@value\nname\n",
            Language::Ruby,
            ".rb",
            "instance_variable",
            "@value",
        ),
        (
            "@value\nname\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "name",
        ),
        (
            "@decorator\ndef call():\n    pass\n",
            Language::Python,
            ".py",
            "decorator",
            "@decorator",
        ),
        (
            "@sealed\nclass Thing {}\n",
            Language::TypeScript,
            ".ts",
            "decorator",
            "@sealed",
        ),
        (
            "print(value)\n",
            Language::Lua,
            ".lua",
            "identifier",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.instance_variable(node),
            ruby_private_predicate(source, language, suffix, "instance_variable?", kind, text),
            "instance_variable? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn global_variable_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "$value\nname\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
        ),
        (
            "$value\nname\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "name",
        ),
        (
            "value = \"$name\"\n",
            Language::Python,
            ".py",
            "string_content",
            "$name",
        ),
        (
            "const $value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "$value",
        ),
        (
            "print(\"$name\")\n",
            Language::Lua,
            ".lua",
            "string_content",
            "$name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.global_variable(node),
            ruby_private_predicate(source, language, suffix, "global_variable?", kind, text),
            "global_variable? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_global_variable_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "$value\n$1\n$12\n$0\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
        ),
        (
            "$value\n$1\n$12\n$0\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$1",
        ),
        (
            "$value\n$1\n$12\n$0\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$12",
        ),
        (
            "$value\n$1\n$12\n$0\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$0",
        ),
        (
            "value = \"$name\"\n",
            Language::Python,
            ".py",
            "string_content",
            "$name",
        ),
        (
            "const $value = 1;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "$value",
        ),
        (
            "print(\"$name\")\n",
            Language::Lua,
            ".lua",
            "string_content",
            "$name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.normalize_global_variable(node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_global_variable",
                kind,
                text
            ),
            "normalize_global_variable mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_operator_matches_ruby_private_predicate() {
    for (language, text) in [
        (Language::Ruby, "="),
        (Language::Ruby, "**="),
        (Language::Ruby, "??="),
        (Language::Python, ":="),
        (Language::Python, "//="),
        (Language::Python, "&&="),
        (Language::TypeScript, "??="),
        (Language::TypeScript, ">>>="),
        (Language::TypeScript, ":="),
        (Language::Lua, "="),
        (Language::Lua, "+="),
    ] {
        let normalizer = super::TreeSitterNormalizer::new("", language);

        assert_eq!(
            normalizer.assignment_operator(text),
            ruby_private_text_predicate(language, "assignment_operator?", text),
            "assignment_operator? mismatch for {language:?} {text:?}"
        );
    }
}

#[test]
fn operator_assignment_operator_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value **= other\nflag ||= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value **= other",
        ),
        (
            "value **= other\nflag ||= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "flag ||= fallback",
        ),
        (
            "value //= other\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value //= other",
        ),
        (
            "value ??= other;\ncount >>>= 1;\n",
            Language::TypeScript,
            ".ts",
            "augmented_assignment_expression",
            "value ??= other",
        ),
        (
            "value ??= other;\ncount >>>= 1;\n",
            Language::TypeScript,
            ".ts",
            "augmented_assignment_expression",
            "count >>>= 1",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.operator_assignment_operator(node),
            ruby_private_string(
                source,
                language,
                suffix,
                "operator_assignment_operator",
                kind,
                text
            ),
            "operator_assignment_operator mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_logical_operator_assignment_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value ||= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value ||= fallback",
        ),
        (
            "value &&= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value &&= fallback",
        ),
        (
            "value += fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value += fallback",
        ),
        (
            "@value ||= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "@value ||= fallback",
        ),
        (
            "value //= fallback\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value //= fallback",
        ),
        (
            "value ||= fallback;\n",
            Language::TypeScript,
            ".ts",
            "augmented_assignment_expression",
            "value ||= fallback",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let left = normalizer
            .assignment_left(node)
            .expect("operator assignment should have left side");
        let right = normalizer
            .assignment_right(node)
            .and_then(|right| normalizer.normalize_node(right));
        let operator = normalizer.operator_assignment_operator(node);
        let rust = normalizer
            .normalize_logical_operator_assignment(left, &operator, right, node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_logical_operator_assignment_value(source, language, suffix, kind, text),
            "normalize_logical_operator_assignment mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_operator_assignment_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value += other\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "value += other",
        ),
        (
            "$value += 1\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "$value += 1",
        ),
        (
            "items[index] += value\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "items[index] += value",
        ),
        (
            "object.value += 1\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "object.value += 1",
        ),
        (
            "flag ||= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "flag ||= fallback",
        ),
        (
            "flag &&= fallback\n",
            Language::Ruby,
            ".rb",
            "operator_assignment",
            "flag &&= fallback",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_operator_assignment(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_operator_assignment",
                kind,
                text
            ),
            "normalize_operator_assignment mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn first_named_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class Thing; end\nname\n",
            Language::Ruby,
            ".rb",
            "class",
            "class Thing; end",
        ),
        (
            "class Thing; end\nname\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "name",
        ),
        (
            "def check(value):\n    return value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def check(value):\n    return value",
        ),
        (
            "function check(value) { return value; }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function check(value) { return value; }",
        ),
        (
            "print(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "print(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.first_named(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "first_named", kind, text),
            "first_named mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn block_child_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\n  call\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def check\n  call\nend",
        ),
        (
            "items.each do\n  call\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.each do\n  call\nend",
        ),
        (
            "def check():\n    call()\n",
            Language::Python,
            ".py",
            "function_definition",
            "def check():\n    call()",
        ),
        (
            "function check() { call(); }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function check() { call(); }",
        ),
        (
            "function check()\n  call()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function check()\n  call()\nend",
        ),
        ("name\n", Language::Ruby, ".rb", "identifier", "name"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.block_child(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "block_child", kind, text),
            "block_child mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn branch_child_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, condition_kind, condition_text, index) in [
        (
            "if ready\n  call\nelse\n  stop\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  call\nelse\n  stop\nend",
            "identifier",
            "ready",
            0,
        ),
        (
            "if ready\n  call\nelse\n  stop\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  call\nelse\n  stop\nend",
            "identifier",
            "ready",
            1,
        ),
        (
            "if ready\n  # note\n  call\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  # note\n  call\nend",
            "identifier",
            "ready",
            0,
        ),
        (
            "if ready:\n    call()\nelse:\n    stop()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()\nelse:\n    stop()",
            "identifier",
            "ready",
            1,
        ),
        (
            "if (ready) { call(); } else { stop(); }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (ready) { call(); } else { stop(); }",
            "parenthesized_expression",
            "(ready)",
            0,
        ),
        (
            "if ready then\n  call()\nelse\n  stop()\nend\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if ready then\n  call()\nelse\n  stop()\nend",
            "identifier",
            "ready",
            1,
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let condition = first_raw_node(tree.root_node(), source, condition_kind, condition_text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.branch_child(node, condition, index).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_branch_child_signature(
                source,
                language,
                suffix,
                kind,
                text,
                condition_kind,
                condition_text,
                index
            ),
            "branch_child mismatch for {language:?} {kind} {text:?} index {index}"
        );
    }
}

#[test]
fn explicit_alternative_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "if ready\n  call\nelsif other\n  stop\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  call\nelsif other\n  stop\nend",
        ),
        (
            "if ready\n  call\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  call\nend",
        ),
        (
            "if ready:\n    call()\nelif other:\n    stop()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()\nelif other:\n    stop()",
        ),
        (
            "if (ready) { call(); } else { stop(); }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (ready) { call(); } else { stop(); }",
        ),
        (
            "if ready then\n  call()\nelseif other then\n  stop()\nend\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if ready then\n  call()\nelseif other then\n  stop()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.explicit_alternative(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(
                source,
                language,
                suffix,
                "explicit_alternative",
                kind,
                text
            ),
            "explicit_alternative mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn wrap_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "first\nsecond\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "second",
        ),
        (
            "first\nsecond\n",
            Language::Python,
            ".py",
            "expression_statement",
            "second",
        ),
        (
            "first;\nsecond;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "second",
        ),
        (
            "print(first)\nprint(second)\n",
            Language::Lua,
            ".lua",
            "identifier",
            "second",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        let raw_wrapped = normalizer.wrap("OUTER", vec![Child::Symbol("child".to_string())], node);
        assert_eq!(
            node_value(&raw_wrapped),
            ruby_private_wrap_value(source, language, suffix, kind, text, false),
            "wrap raw-source mismatch for {language:?} {kind} {text:?}"
        );

        let inner = normalizer.wrap("INNER", Vec::new(), node);
        let node_wrapped = normalizer.wrap_from_source_node(
            "OUTER",
            vec![Child::Symbol("child".to_string())],
            &inner,
        );
        assert_eq!(
            node_value(&node_wrapped),
            ruby_private_wrap_value(source, language, suffix, kind, text, true),
            "wrap normalized-source mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn source_before_child_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, child_kind, child_text) in [
        (
            "if ready\n  call\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  call\nend",
            "then",
            "\n  call",
        ),
        (
            "if ready:\n    call()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()",
            "block",
            "call()",
        ),
        (
            "if (ready) { call(); }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (ready) { call(); }",
            "statement_block",
            "{ call(); }",
        ),
        (
            "if ready then\n  call()\nend\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if ready then\n  call()\nend",
            "block",
            "call()",
        ),
        (
            "puts value\n",
            Language::Ruby,
            ".rb",
            "call",
            "puts value",
            "identifier",
            "puts",
        ),
        (
            "call()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "call()",
            "identifier",
            "call",
        ),
        (
            "call();\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "call();",
            "identifier",
            "call",
        ),
        (
            "call()\n",
            Language::Lua,
            ".lua",
            "function_call",
            "call()",
            "identifier",
            "call",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let child = first_raw_node(tree.root_node(), source, child_kind, child_text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let source_node = normalizer.source_before_child(node, child);
        let wrapped = normalizer.wrap_from_source_node("OUTER", Vec::new(), &source_node);

        assert_eq!(
                node_value(&wrapped),
                ruby_private_source_before_child_wrap_value(
                    source, language, suffix, kind, text, child_kind, child_text
                ),
                "source_before_child mismatch for {language:?} {kind} {text:?} before {child_kind} {child_text:?}"
            );
    }
}

#[test]
fn source_from_nodes_matches_ruby_private_method() {
    for (source, language, suffix, first_kind, first_text, last_kind, last_text) in [
        (
            "left + right\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "left",
            "identifier",
            "right",
        ),
        (
            "left = one\nright = two\n",
            Language::Python,
            ".py",
            "identifier",
            "one",
            "identifier",
            "two",
        ),
        (
            "const left = one;\nconst right = two;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "one",
            "identifier",
            "two",
        ),
        (
            "local left = one\nlocal right = two\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "one",
            "expression_list",
            "two",
        ),
    ] {
        let tree = raw_tree(source, language);
        let first_raw = first_raw_node(tree.root_node(), source, first_kind, first_text);
        let last_raw = first_raw_node(tree.root_node(), source, last_kind, last_text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let source_node = normalizer.source_from_nodes(first_raw, last_raw);

        assert_eq!(
                node_value(&source_node),
                ruby_private_source_from_nodes_value(
                    source, language, suffix, first_kind, first_text, last_kind, last_text
                ),
                "source_from_nodes mismatch for {language:?} {first_kind} {first_text:?} through {last_kind} {last_text:?}"
            );
    }
}

#[test]
fn source_from_normalized_nodes_matches_ruby_private_method() {
    for (source, language, suffix, first_kind, first_text, last_kind, last_text) in [
        (
            "first\nsecond\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "first",
            "identifier",
            "second",
        ),
        (
            "first\nsecond\n",
            Language::Python,
            ".py",
            "expression_statement",
            "first",
            "expression_statement",
            "second",
        ),
        (
            "first;\nsecond;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "first;",
            "expression_statement",
            "second;",
        ),
        (
            "print(first)\nprint(second)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "print(first)",
            "function_call",
            "print(second)",
        ),
        (
            "first + second\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "first",
            "identifier",
            "second",
        ),
    ] {
        let tree = raw_tree(source, language);
        let first_raw = first_raw_node(tree.root_node(), source, first_kind, first_text);
        let last_raw = first_raw_node(tree.root_node(), source, last_kind, last_text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let first_node = normalizer.wrap("FIRST", Vec::new(), first_raw);
        let last_node = normalizer.wrap("LAST", Vec::new(), last_raw);
        let source_node = normalizer.source_from_normalized_nodes(&first_node, &last_node);

        assert_eq!(
                node_value(&source_node),
                ruby_private_source_from_normalized_nodes_value(
                    source, language, suffix, first_kind, first_text, last_kind, last_text
                ),
                "source_from_normalized_nodes mismatch for {language:?} {first_kind} {first_text:?} through {last_kind} {last_text:?}"
            );
    }
}

#[test]
fn named_field_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, field) in [
        (
            "def check(value)\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def check(value)\n  value\nend",
            "name",
        ),
        (
            "def check(value)\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def check(value)\n  value\nend",
            "missing",
        ),
        (
            "if ready:\n    call()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()",
            "body",
        ),
        (
            "if ready:\n    call()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()",
            "condition",
        ),
        (
            "function check(value) { return value; }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function check(value) { return value; }",
            "body",
        ),
        (
            "function check(value)\n  return value\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function check(value)\n  return value\nend",
            "body",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.named_field(node, field).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_named_field_signature(source, language, suffix, kind, text, field),
            "named_field mismatch for {language:?} {kind} {text:?} field {field}"
        );
    }
}

#[test]
fn parent_node_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def check\nend\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "check",
        ),
        ("value\n", Language::Ruby, ".rb", "program", "value\n"),
        (
            "if ready:\n    call()\n",
            Language::Python,
            ".py",
            "identifier",
            "ready",
        ),
        (
            "call(value);\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "call(value)\n",
            Language::Lua,
            ".lua",
            "identifier",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.parent_node(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "parent_node", kind, text),
            "parent_node mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn next_sibling_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("a + b\n", Language::Ruby, ".rb", "identifier", "a"),
        ("a + b\n", Language::Python, ".py", "identifier", "a"),
        ("a + b;\n", Language::TypeScript, ".ts", "identifier", "a"),
        ("print(a, b)\n", Language::Lua, ".lua", "identifier", "a"),
        ("a\n", Language::Ruby, ".rb", "identifier", "a"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.next_sibling(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "next_sibling", kind, text),
            "next_sibling mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn prev_sibling_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("a + b\n", Language::Ruby, ".rb", "identifier", "b"),
        ("a + b\n", Language::Python, ".py", "identifier", "b"),
        ("a + b;\n", Language::TypeScript, ".ts", "identifier", "b"),
        ("print(a, b)\n", Language::Lua, ".lua", "identifier", "b"),
        ("a\n", Language::Ruby, ".rb", "identifier", "a"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.prev_sibling(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "prev_sibling", kind, text),
            "prev_sibling mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn next_named_sibling_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("a + b\n", Language::Ruby, ".rb", "identifier", "a"),
        ("a + b\n", Language::Python, ".py", "identifier", "a"),
        ("a + b;\n", Language::TypeScript, ".ts", "identifier", "a"),
        ("print(a, b)\n", Language::Lua, ".lua", "identifier", "a"),
        ("a\n", Language::Ruby, ".rb", "identifier", "a"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.next_named_sibling(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "next_named_sibling", kind, text),
            "next_named_sibling mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ternary_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(cond, a, b)\n  cond ? a : b\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "cond ? a : b",
        ),
        (
            "value = a if cond else b\n",
            Language::Python,
            ".py",
            "conditional_expression",
            "a if cond else b",
        ),
        (
            "const value = cond ? a : b;\n",
            Language::TypeScript,
            ".ts",
            "ternary_expression",
            "cond ? a : b",
        ),
        (
            "local value = cond and a or b\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "cond and a or b",
        ),
        (
            "def f(cond)\n  cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "cond",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.ternary_statement(node),
            ruby_private_predicate(source, language, suffix, "ternary_statement?", kind, text),
            "ternary_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_ternary_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(cond, a, b)\n  cond ? a : b\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "cond ? a : b",
        ),
        (
            "value = a if cond else b\n",
            Language::Python,
            ".py",
            "conditional_expression",
            "a if cond else b",
        ),
        (
            "const value = cond ? a : b;\n",
            Language::TypeScript,
            ".ts",
            "ternary_expression",
            "cond ? a : b",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_ternary_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_ternary_statement",
                kind,
                text
            ),
            "normalize_ternary_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ternary_statement_normalization_matches_ruby() {
    for (source, language, suffix, if_text) in [
        (
            "def f(cond, a, b)\n  cond ? a : b\nend\n",
            Language::Ruby,
            ".rb",
            "cond ? a : b",
        ),
        (
            "def f(cond, a, b):\n    return a if cond else b\n",
            Language::Python,
            ".py",
            "a if cond else b",
        ),
        (
            "function f(cond: boolean, a: number, b: number) { return cond ? a : b; }\n",
            Language::TypeScript,
            ".ts",
            "cond ? a : b",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let if_node = first_node(&root, "IF", if_text);
        assert_eq!(child_node(if_node, 0).text, "cond");
        assert_eq!(child_node(if_node, 1).text, "a");
        assert_eq!(child_node(if_node, 2).text, "b");
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn case_argument_list_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(x)\n  return case x\n  when 1 then :one\n  else :other\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "case x\n  when 1 then :one\n  else :other\n  end",
        ),
        (
            "case x\nwhen 1 then :one\nelse :other\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case x\nwhen 1 then :one\nelse :other\nend",
        ),
        (
            "match value:\n    case 1:\n        one()\n",
            Language::Python,
            ".py",
            "case_clause",
            "case 1:\n        one()",
        ),
        (
            "switch (value) { case 1: one(); break; }\n",
            Language::TypeScript,
            ".ts",
            "switch_case",
            "case 1: one(); break;",
        ),
        (
            "if value == 1 then one() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.case_argument_list(node),
            ruby_private_predicate(source, language, suffix, "case_argument_list?", kind, text),
            "case_argument_list? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn leading_function_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def outer\n  def inner\n    x\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "def inner\n    x\n  end",
        ),
        (
            "def outer():\n    def inner():\n        x\n",
            Language::Python,
            ".py",
            "block",
            "def inner():\n        x",
        ),
        (
            "function outer()\n  function inner()\n    x()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "function inner()\n    x()\n  end",
        ),
        (
            "function outer() { function inner() { x; } }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function inner() { x; }",
        ),
        (
            "def outer\n  x\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.leading_function_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "leading_function_statement?",
                kind,
                text
            ),
            "leading_function_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_leading_function_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def outer\n  def inner\n    x\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "def inner\n    x\n  end",
        ),
        (
            "def outer():\n    def inner():\n        x\n",
            Language::Python,
            ".py",
            "block",
            "def inner():\n        x",
        ),
        (
            "function outer()\n  function inner()\n    x()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "function inner()\n    x()\n  end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_leading_function_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_leading_function_statement",
                kind,
                text
            ),
            "normalize_leading_function_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn leading_function_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        (
            "def outer\n  def inner\n    x\n  end\nend\n",
            Language::Ruby,
            ".rb",
        ),
        (
            "def outer():\n    def inner():\n        x\n",
            Language::Python,
            ".py",
        ),
        (
            "function outer()\n  function inner()\n    x()\n  end\nend\n",
            Language::Lua,
            ".lua",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut defns = Vec::new();
        nodes_of_type(&root, "DEFN", &mut defns);
        assert!(
            defns.iter().any(
                |node| matches!(node.children.first(), Some(Child::Symbol(name)) if name == "inner")
            ),
            "expected nested DEFN inner for {language:?} in {root:#?}"
        );
        let mut iters = Vec::new();
        nodes_of_type(&root, "ITER", &mut iters);
        assert!(
            iters.iter().all(|node| !node.text.contains("inner")),
            "nested function must not normalize as ITER for {language:?}: {iters:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn leading_owner_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def outer\n  class Inner\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "class Inner\n    value\n  end",
        ),
        (
            "def outer\n  module Inner\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "module Inner\n    value\n  end",
        ),
        (
            "def outer():\n    class Inner:\n        pass\n",
            Language::Python,
            ".py",
            "block",
            "class Inner:\n        pass",
        ),
        (
            "function outer() { class Inner {} }\n",
            Language::TypeScript,
            ".ts",
            "class_declaration",
            "class Inner {}",
        ),
        (
            "function outer()\n  Inner = {}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "Inner = {}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.leading_owner_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "leading_owner_statement?",
                kind,
                text
            ),
            "leading_owner_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_leading_owner_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def outer\n  class Inner\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "class Inner\n    value\n  end",
        ),
        (
            "def outer\n  module Inner\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "module Inner\n    value\n  end",
        ),
        (
            "def outer():\n    class Inner:\n        pass\n",
            Language::Python,
            ".py",
            "block",
            "class Inner:\n        pass",
        ),
        (
            "function outer() { class Inner {} }\n",
            Language::TypeScript,
            ".ts",
            "class_declaration",
            "class Inner {}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_leading_owner_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_leading_owner_statement",
                kind,
                text
            ),
            "normalize_leading_owner_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn modifier_keyword_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value if cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value if cond",
        ),
        (
            "def f\n  value unless cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value unless cond",
        ),
        (
            "def f\n  value while cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value while cond",
        ),
        (
            "def f\n  value until cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value until cond",
        ),
        (
            "def f\n  if cond\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "if cond\n    value\n  end",
        ),
        (
            "def f():\n    if cond:\n        value()\n",
            Language::Python,
            ".py",
            "block",
            "if cond:\n        value()",
        ),
        (
            "function f() { if (cond) { value(); } }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (cond) { value(); }",
        ),
        (
            "function f()\n  if cond then\n    value()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "if cond then\n    value()\n  end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.modifier_keyword(node).unwrap_or_default();

        assert_eq!(
            rust,
            ruby_private_string(source, language, suffix, "modifier_keyword", kind, text),
            "modifier_keyword mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn modifier_parts_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value if cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value if cond",
        ),
        (
            "def f\n  value unless cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value unless cond",
        ),
        (
            "def f\n  if cond\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "if cond\n    value\n  end",
        ),
        (
            "def f():\n    if cond:\n        value()\n",
            Language::Python,
            ".py",
            "block",
            "if cond:\n        value()",
        ),
        (
            "function f() { if (cond) { value(); } }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (cond) { value(); }",
        ),
        (
            "function f()\n  if cond then\n    value()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "if cond then\n    value()\n  end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.modifier_parts(node).map(|(action, condition)| {
            (
                (
                    action.kind().to_string(),
                    super::node_text(action, source).to_string(),
                ),
                (
                    condition.kind().to_string(),
                    super::node_text(condition, source).to_string(),
                ),
            )
        });

        assert_eq!(
            rust,
            ruby_private_modifier_parts_signature(source, language, suffix, kind, text),
            "modifier_parts mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn modifier_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value if cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value if cond",
        ),
        (
            "def f\n  return value if cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "return value if cond",
        ),
        (
            "def f\n  if cond\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "if cond\n    value\n  end",
        ),
        (
            "def f():\n    if cond:\n        value()\n",
            Language::Python,
            ".py",
            "block",
            "if cond:\n        value()",
        ),
        (
            "function f() { if (cond) { value(); } }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (cond) { value(); }",
        ),
        (
            "function f()\n  if cond then\n    value()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "if cond then\n    value()\n  end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.modifier_statement(node),
            ruby_private_predicate(source, language, suffix, "modifier_statement?", kind, text),
            "modifier_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_modifier_action_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "return value if cond\n",
            Language::Ruby,
            ".rb",
            "return",
            "return value",
        ),
        ("break if done\n", Language::Ruby, ".rb", "break", "break"),
        (
            "value if cond\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_modifier_action(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_modifier_action",
                kind,
                text
            ),
            "normalize_modifier_action mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_modifier_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value if cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value if cond",
        ),
        (
            "def f\n  value unless cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value unless cond",
        ),
        (
            "def f\n  value while cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value while cond",
        ),
        (
            "def f\n  value until cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value until cond",
        ),
        (
            "def f\n  return value if cond\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "return value if cond",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_modifier_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_modifier_statement",
                kind,
                text
            ),
            "normalize_modifier_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn modifier_return_action_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "return value if ready\n",
            Language::Ruby,
            ".rb",
            "return",
            "return value",
        ),
        ("break if done\n", Language::Ruby, ".rb", "break", "break"),
        ("next if skip\n", Language::Ruby, ".rb", "next", "next"),
        (
            "return value if ready\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "ready",
        ),
        (
            "def f():\n    return value\n    break\n    continue\n",
            Language::Python,
            ".py",
            "return_statement",
            "return value",
        ),
        (
            "def f():\n    return value\n    break\n    continue\n",
            Language::Python,
            ".py",
            "break_statement",
            "break",
        ),
        (
            "def f():\n    return value\n    break\n    continue\n",
            Language::Python,
            ".py",
            "continue_statement",
            "continue",
        ),
        (
            "def f():\n    return value\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "function f() { return value; break; continue; }\n",
            Language::TypeScript,
            ".ts",
            "return_statement",
            "return value;",
        ),
        (
            "function f() { return value; break; continue; }\n",
            Language::TypeScript,
            ".ts",
            "break_statement",
            "break;",
        ),
        (
            "function f() { return value; break; continue; }\n",
            Language::TypeScript,
            ".ts",
            "continue_statement",
            "continue;",
        ),
        (
            "function f() { return value; }\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "return value\n",
            Language::Lua,
            ".lua",
            "return_statement",
            "return value",
        ),
        (
            "return value\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.modifier_return_action(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "modifier_return_action?",
                kind,
                text
            ),
            "modifier_return_action? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn call_block_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "items.each do |item|\n  item\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.each do |item|\n  item\nend",
        ),
        (
            "items.map { |item| item }\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.map { |item| item }",
        ),
        (
            "def f\n  items.map { |item| item }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items.map { |item| item }",
        ),
        ("items.each\n", Language::Ruby, ".rb", "call", "items.each"),
        (
            "def f():\n    value()\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f():\n    value()",
        ),
        (
            "function f()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f()\n  value()\nend",
        ),
        (
            "function f() { value(); }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function f() { value(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.call_block(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(source, language, suffix, "call_block", kind, text),
            "call_block mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn statement_block_call_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  items.map { |item| item }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items.map { |item| item }",
        ),
        (
            "items.map { |item| item }\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.map { |item| item }",
        ),
        (
            "def f\n  foo(bar) { baz }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo(bar) { baz }",
        ),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "def f():\n    value()\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f():\n    value()",
        ),
        (
            "user.name();\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "function f() { value(); }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function f() { value(); }",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
        (
            "function f()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f()\n  value()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let found = normalizer.statement_block_call(node).map(|node| {
            (
                node.kind().to_string(),
                super::node_text(node, source).to_string(),
            )
        });

        assert_eq!(
            found,
            ruby_private_node_signature(
                source,
                language,
                suffix,
                "statement_block_call",
                kind,
                text
            ),
            "statement_block_call mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn statement_call_with_block_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  items.map { |item| item }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items.map { |item| item }",
        ),
        (
            "items.map { |item| item }\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.map { |item| item }",
        ),
        (
            "def f\n  foo(bar) { baz }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo(bar) { baz }",
        ),
        (
            "def f\n  items.map\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items.map",
        ),
        (
            "def f():\n    value(lambda item: item)\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f():\n    value(lambda item: item)",
        ),
        (
            "items.map(item => item);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "items.map(item => item);",
        ),
        (
            "items:map(function(item) return item end)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "items:map(function(item) return item end)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.statement_call_with_block(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "statement_call_with_block?",
                kind,
                text
            ),
            "statement_call_with_block? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_statement_call_with_block_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [(
        "def f\n  items.map { |item| item }\nend\n",
        Language::Ruby,
        ".rb",
        "body_statement",
        "items.map { |item| item }",
    )] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_statement_call_with_block(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_statement_call_with_block",
                kind,
                text
            ),
            "normalize_statement_call_with_block mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn visibility_inline_def_call_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "private def hidden; value; end\n",
            Language::Ruby,
            ".rb",
            "call",
            "private def hidden; value; end",
        ),
        (
            "public def visible\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "public def visible\n  value\nend",
        ),
        (
            "private :hidden\n",
            Language::Ruby,
            ".rb",
            "call",
            "private :hidden",
        ),
        (
            "private(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "private(value)",
        ),
        (
            "private(value);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "private(value)",
        ),
        (
            "private(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "private(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.visibility_inline_def_call(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "visibility_inline_def_call?",
                kind,
                text
            ),
            "visibility_inline_def_call? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn visibility_inline_def_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "private def hidden\n    value\n  end",
        ),
        (
            "class C\n  module_function def helper\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "module_function def helper\n    value\n  end",
        ),
        (
            "class C\n  private :hidden\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "private :hidden",
        ),
        (
            "private(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "private(value)",
        ),
        (
            "private(value);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "private(value);",
        ),
        (
            "private(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "private(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let function =
            normalizer.named_children(node).into_iter().next().expect(
                "visibility_inline_def_statement test target should have a first named child",
            );

        assert_eq!(
            normalizer.visibility_inline_def_statement(node, function),
            ruby_private_visibility_inline_def_statement_predicate(
                source, language, suffix, kind, text
            ),
            "visibility_inline_def_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_visibility_inline_def_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "private def hidden\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "private def hidden\n  value\nend",
        ),
        (
            "public def visible\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "public def visible\n  value\nend",
        ),
        (
            "module_function def self.helper\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "module_function def self.helper\n  value\nend",
        ),
        (
            "private(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "private(value)",
        ),
        (
            "private(value);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "private(value)",
        ),
        (
            "private(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "private(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_visibility_inline_def(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_visibility_inline_def",
                kind,
                text
            ),
            "normalize_visibility_inline_def mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn inline_def_from_argument_list_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def hidden\n    value\n  end",
        ),
        (
            "class C\n  private def self.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def self.hidden\n    value\n  end",
        ),
        (
            "class C\n  private :hidden\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            ":hidden",
        ),
        (
            "private(value)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(value)",
        ),
        (
            "private(value);\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(value)",
        ),
        (
            "private(value)\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .inline_def_from_argument_list(Some(node))
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "inline_def_from_argument_list",
                kind,
                text
            ),
            "inline_def_from_argument_list mismatch for {language:?} {kind} {text:?}"
        );
    }

    for (source, language, suffix) in [
        ("private def hidden\n  value\nend\n", Language::Ruby, ".rb"),
        ("private(value)\n", Language::Python, ".py"),
        ("private(value);\n", Language::TypeScript, ".ts"),
        ("private(value)\n", Language::Lua, ".lua"),
    ] {
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .inline_def_from_argument_list(None)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_inline_def_from_argument_list_nil_value(source, language, suffix),
            "inline_def_from_argument_list nil mismatch for {language:?}"
        );
    }
}

#[test]
fn inline_def_from_source_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def hidden\n    value\n  end",
        ),
        (
            "class C\n  private def self.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def self.hidden\n    value\n  end",
        ),
        (
            "def hidden\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def hidden\n  value\nend",
        ),
        (
            "def self.hidden\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "singleton_method",
            "def self.hidden\n  value\nend",
        ),
        (
            "class C\n  private :hidden\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            ":hidden",
        ),
        (
            "def hidden():\n    value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def hidden():\n    value",
        ),
        (
            "function hidden() {\n  value;\n}\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function hidden() {\n  value;\n}",
        ),
        (
            "function hidden()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function hidden()\n  value()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .inline_def_from_source(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "inline_def_from_source",
                kind,
                text
            ),
            "inline_def_from_source mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn inline_def_from_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "private def hidden\n    value\n  end",
        ),
        (
            "class C\n  module_function def self.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "module_function def self.hidden\n    value\n  end",
        ),
        (
            "private def hidden\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "private def hidden\n  value\nend",
        ),
        (
            "class C\n  private :hidden\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "private :hidden",
        ),
        (
            "private(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "private(value)",
        ),
        (
            "private(value);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "private(value);",
        ),
        (
            "private(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "private(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .inline_def_from_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "inline_def_from_statement",
                kind,
                text
            ),
            "inline_def_from_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn inline_def_body_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def hidden\n    value\n  end",
        ),
        (
            "class C\n  private def self.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def self.hidden\n    value\n  end",
        ),
        (
            "class C\n  private def empty\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def empty\n  end",
        ),
        (
            "def hidden():\n    value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def hidden():\n    value",
        ),
        (
            "function hidden() {\n  value;\n}\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function hidden() {\n  value;\n}",
        ),
        (
            "function hidden()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function hidden()\n  value()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.inline_def_body(node).map(|body| {
            (
                body.kind().to_string(),
                super::node_text(body, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(source, language, suffix, "inline_def_body", kind, text),
            "inline_def_body mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn inline_def_receiver_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def hidden\n    value\n  end",
        ),
        (
            "class C\n  private def self.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def self.hidden\n    value\n  end",
        ),
        (
            "class C\n  private def Owner.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def Owner.hidden\n    value\n  end",
        ),
        (
            "class C\n  private def Owner::Nested.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def Owner::Nested.hidden\n    value\n  end",
        ),
        (
            "def hidden():\n    value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def hidden():\n    value",
        ),
        (
            "function hidden() {\n  value;\n}\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function hidden() {\n  value;\n}",
        ),
        (
            "function hidden()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function hidden()\n  value()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.inline_def_receiver(node).map(|receiver| {
            (
                receiver.kind().to_string(),
                super::node_text(receiver, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(
                source,
                language,
                suffix,
                "inline_def_receiver",
                kind,
                text
            ),
            "inline_def_receiver mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn inline_def_name_after_receiver_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class C\n  private def self.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def self.hidden\n    value\n  end",
        ),
        (
            "class C\n  private def Owner.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def Owner.hidden\n    value\n  end",
        ),
        (
            "class C\n  private def Owner::Nested.hidden\n    value\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "def Owner::Nested.hidden\n    value\n  end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let receiver = normalizer
            .inline_def_receiver(node)
            .expect("inline def receiver should exist for name-after-receiver case");
        let rust = normalizer
            .inline_def_name_after_receiver(node, receiver)
            .unwrap_or_default();

        assert_eq!(
            rust,
            ruby_private_inline_def_name_after_receiver(source, language, suffix, kind, text),
            "inline_def_name_after_receiver mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn inline_parameter_begin_marker_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(a); a; end\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a); a; end",
        ),
        (
            "def f a; a; end\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f a; a; end",
        ),
        (
            "def f(a)\n  a\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a)\n  a\nend",
        ),
        (
            "def f(a):\n    return a\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f(a):\n    return a",
        ),
        (
            "function f(a) { return a; }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function f(a) { return a; }",
        ),
        (
            "function f(a)\n  return a\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f(a)\n  return a\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .inline_parameter_begin_marker(node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_inline_parameter_begin_marker_value(source, language, suffix, kind, text),
            "inline_parameter_begin_marker mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn prepend_inline_parameter_begin_matches_ruby_private_method() {
    let scalar = test_node("VCALL", Vec::new());
    let block = test_node(
        "BLOCK",
        vec![Child::Node(Box::new(scalar.clone())), Child::Nil],
    );
    let empty_block = test_node("BLOCK", vec![Child::Nil]);

    let cases = vec![
        (
            "no_marker",
            "def f(a)\n  a\nend\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a)\n  a\nend",
            Some(scalar.clone()),
        ),
        (
            "marker_nil_body",
            "def f(a); a; end\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a); a; end",
            None,
        ),
        (
            "marker_scalar_body",
            "def f(a); a; end\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a); a; end",
            Some(scalar.clone()),
        ),
        (
            "marker_block_body",
            "def f(a); a; end\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a); a; end",
            Some(block),
        ),
        (
            "marker_empty_block",
            "def f(a); a; end\n",
            Language::Ruby,
            ".rb",
            "method",
            "def f(a); a; end",
            Some(empty_block),
        ),
        (
            "non_ruby",
            "def f(a):\n    return a\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f(a):\n    return a",
            Some(scalar),
        ),
    ];

    for (label, source, language, suffix, kind, text, body) in cases {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .prepend_inline_parameter_begin(node, body.clone())
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);
        let body_value = body.as_ref().map(node_value).unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_prepend_inline_parameter_begin_value(
                source,
                language,
                suffix,
                kind,
                text,
                &body_value,
            ),
            "prepend_inline_parameter_begin mismatch for {label}"
        );
    }
}

#[test]
fn scalar_argument_list_value_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  return yield\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "yield",
        ),
        (
            "def f\n  return nil\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "nil",
        ),
        (
            "def f\n  return true\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "true",
        ),
        (
            "def f\n  return false\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "false",
        ),
        (
            "def f\n  return :ok?\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            ":ok?",
        ),
        (
            "def f\n  return 12\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "12",
        ),
        (
            "def f\n  return -12\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "-12",
        ),
        (
            "def f\n  return name\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "name",
        ),
        (
            "def f():\n    return value\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "function f() { return value; }\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "function f()\n  return value\nend\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "value",
        ),
        (
            "function f() { return yield; }\n",
            Language::TypeScript,
            ".ts",
            "yield_expression",
            "yield",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .scalar_argument_list_value(node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "scalar_argument_list_value",
                kind,
                text,
            ),
            "scalar_argument_list_value mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn local_or_call_for_name_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, name, local) in [
        (
            "def f\n  {name:}\nend\n",
            Language::Ruby,
            ".rb",
            "hash_key_symbol",
            "name",
            "name",
            false,
        ),
        (
            "def f\n  {name:}\nend\n",
            Language::Ruby,
            ".rb",
            "hash_key_symbol",
            "name",
            "name",
            true,
        ),
        (
            "def f():\n    value\n",
            Language::Python,
            ".py",
            "identifier",
            "f",
            "f",
            false,
        ),
        (
            "function f() { value; }\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
            "value",
            false,
        ),
        (
            "function f()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "identifier",
            "value",
            "value",
            false,
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        if local {
            normalizer
                .local_stack
                .push(BTreeSet::from([name.to_string()]));
        }
        let rust = node_value(&normalizer.local_or_call_for_name(name, node));

        assert_eq!(
            rust,
            ruby_private_local_or_call_for_name_value(
                source, language, suffix, kind, text, name, local
            ),
            "local_or_call_for_name mismatch for {language:?} {name:?} local={local}"
        );
    }
}

#[test]
fn literal_arguments_from_text_normalization_matches_ruby() {
    let symbol_source = "puts :ok\n";
    let root = parse_language_source(symbol_source, Language::Ruby, ".rb");
    let fcall = first_node(&root, "FCALL", "puts :ok");
    assert_eq!(
        fcall.children.first(),
        Some(&Child::Symbol("puts".to_string()))
    );
    let args = child_node(fcall, 1);
    assert_eq!(args.r#type, "LIST");
    let lit = child_node(args, 0);
    assert_eq!(lit.r#type, "LIT");
    assert_eq!(lit.children.first(), Some(&Child::Symbol("ok".to_string())));
    assert_ruby_parity(symbol_source, Language::Ruby, ".rb");

    let heredoc_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
    let root = parse_language_source(heredoc_source, Language::Ruby, ".rb");
    let fcall = first_node(&root, "FCALL", "puts <<~TXT");
    let args = child_node(fcall, 1);
    assert_eq!(args.r#type, "LIST");
    let dstr = child_node(args, 0);
    assert_eq!(dstr.r#type, "DSTR");
    assert_eq!(child_types(dstr), vec!["STR"]);
    let body = child_node(dstr, 0);
    assert_eq!(
        body.children.first(),
        Some(&Child::String("\n    hi\n  ".to_string()))
    );
    assert_ruby_parity(heredoc_source, Language::Ruby, ".rb");
}

#[test]
fn literal_symbol_arguments_matches_ruby_scan_contract() {
    assert_eq!(
        super::literal_symbol_arguments(":one, :two?, :three!, :four=, :1, ::Name"),
        vec![
            "one".to_string(),
            "two?".to_string(),
            "three!".to_string(),
            "four=".to_string(),
            "Name".to_string(),
        ]
    );
}

#[test]
fn elide_tail_returns_matches_ruby_private_method() {
    let leaf = |node_type: &str| test_node(node_type, vec![Child::String("value".to_string())]);
    let return_leaf = || test_node("RETURN", vec![Child::Node(Box::new(leaf("LVAR")))]);
    let protected_def = test_node(
        "DEFN",
        vec![
            Child::Symbol("kept".to_string()),
            Child::Node(Box::new(test_node(
                "SCOPE",
                vec![Child::Nil, Child::Nil, Child::Node(Box::new(return_leaf()))],
            ))),
        ],
    );
    let cases = vec![
        None,
        Some(return_leaf()),
        Some(test_node(
            "BLOCK",
            vec![
                Child::Node(Box::new(leaf("LVAR"))),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(test_node(
            "SCOPE",
            vec![Child::Nil, Child::Nil, Child::Node(Box::new(return_leaf()))],
        )),
        Some(test_node(
            "IF",
            vec![
                Child::Node(Box::new(leaf("COND"))),
                Child::Node(Box::new(return_leaf())),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(test_node(
            "UNLESS",
            vec![
                Child::Node(Box::new(leaf("COND"))),
                Child::Node(Box::new(return_leaf())),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(test_node(
            "CASE",
            vec![
                Child::Node(Box::new(leaf("LVAR"))),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(test_node(
            "CASE2",
            vec![Child::Node(Box::new(return_leaf()))],
        )),
        Some(test_node(
            "WHEN",
            vec![
                Child::Node(Box::new(leaf("LIST"))),
                Child::Node(Box::new(return_leaf())),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(test_node(
            "RESCUE",
            vec![
                Child::Node(Box::new(return_leaf())),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(test_node(
            "RESBODY",
            vec![
                Child::Node(Box::new(leaf("LIST"))),
                Child::Node(Box::new(return_leaf())),
                Child::Node(Box::new(return_leaf())),
            ],
        )),
        Some(protected_def),
    ];
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);

    for node in cases {
        let input = node.as_ref().map(node_value).unwrap_or(Value::Null);
        let rust = normalizer
            .elide_tail_returns(node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_elide_tail_returns_value(&input, true),
            "elide_tail_returns mismatch for input {input}"
        );
    }

    let non_ruby = Some(return_leaf());
    let input = non_ruby.as_ref().map(node_value).unwrap_or(Value::Null);
    let normalizer = super::TreeSitterNormalizer::new("", Language::Python);
    let rust = normalizer
        .elide_tail_returns(non_ruby)
        .as_ref()
        .map(node_value)
        .unwrap_or(Value::Null);

    assert_eq!(rust, input);
    assert_eq!(ruby_private_elide_tail_returns_value(&input, false), input);
}

#[test]
fn elide_implicit_nil_body_matches_ruby_private_method() {
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    let leaf = || test_node("LVAR", vec![Child::String("value".to_string())]);
    let nil_node = || test_node("NIL", Vec::new());
    let cases = vec![
        None,
        Some(nil_node()),
        Some(leaf()),
        Some(test_node(
            "BLOCK",
            vec![
                Child::Node(Box::new(leaf())),
                Child::Node(Box::new(nil_node())),
                Child::Node(Box::new(nil_node())),
            ],
        )),
        Some(test_node(
            "BLOCK",
            vec![Child::Nil, Child::Node(Box::new(nil_node()))],
        )),
        Some(test_node(
            "BLOCK",
            vec![
                Child::Node(Box::new(leaf())),
                Child::Node(Box::new(leaf())),
                Child::Node(Box::new(nil_node())),
            ],
        )),
    ];

    for node in cases {
        let input = node.as_ref().map(node_value).unwrap_or(Value::Null);
        let rust = normalizer
            .elide_implicit_nil_body(node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_elide_implicit_nil_body_value(&input, true),
            "elide_implicit_nil_body mismatch for input {input}"
        );
    }

    let non_ruby = Some(nil_node());
    let input = non_ruby.as_ref().map(node_value).unwrap_or(Value::Null);
    let normalizer = super::TreeSitterNormalizer::new("", Language::Python);
    let rust = normalizer
        .elide_implicit_nil_body(non_ruby)
        .as_ref()
        .map(node_value)
        .unwrap_or(Value::Null);

    assert_eq!(rust, input);
    assert_eq!(
        ruby_private_elide_implicit_nil_body_value(&input, false),
        input
    );
}

#[test]
fn drop_trailing_nil_statement_matches_ruby_private_method() {
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    let leaf = |node_type: &str| test_node(node_type, vec![Child::Symbol("value".to_string())]);
    let nil_node = || test_node("NIL", Vec::new());
    let block = |children| test_node("BLOCK", children);

    for node in [
        None,
        Some(nil_node()),
        Some(block(vec![
            Child::Node(Box::new(leaf("LASGN"))),
            Child::Node(Box::new(nil_node())),
        ])),
        Some(block(vec![
            Child::Node(Box::new(leaf("LASGN"))),
            Child::Node(Box::new(nil_node())),
            Child::Node(Box::new(nil_node())),
        ])),
        Some(block(vec![
            Child::Node(Box::new(leaf("LASGN"))),
            Child::Nil,
            Child::Node(Box::new(nil_node())),
        ])),
        Some(block(vec![Child::Nil, Child::Node(Box::new(nil_node()))])),
        Some(block(vec![
            Child::Node(Box::new(leaf("LASGN"))),
            Child::Nil,
            Child::Node(Box::new(leaf("VCALL"))),
        ])),
        Some(block(vec![
            Child::Node(Box::new(leaf("LASGN"))),
            Child::Nil,
            Child::Node(Box::new(leaf("VCALL"))),
            Child::Node(Box::new(nil_node())),
        ])),
    ] {
        let input = node.as_ref().map(node_value).unwrap_or(Value::Null);
        let rust = normalizer
            .drop_trailing_nil_statement(node)
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_drop_trailing_nil_statement_value(&input),
            "drop_trailing_nil_statement mismatch for input {input}"
        );
    }
}

#[test]
fn symbol_literal_node_matches_ruby_private_predicate() {
    let normalizer = super::TreeSitterNormalizer::new("", Language::Ruby);
    for (node, node_type, child_kind) in [
        (None, None, None),
        (
            Some(test_node("LIT", vec![Child::Symbol("value".to_string())])),
            Some("LIT"),
            Some("symbol"),
        ),
        (
            Some(test_node("LIT", vec![Child::String("value".to_string())])),
            Some("LIT"),
            Some("string"),
        ),
        (Some(test_node("LIT", Vec::new())), Some("LIT"), None),
        (
            Some(test_node("STR", vec![Child::Symbol("value".to_string())])),
            Some("STR"),
            Some("symbol"),
        ),
        (
            Some(test_node(
                "LIT",
                vec![Child::Node(Box::new(test_node("NIL", Vec::new())))],
            )),
            Some("LIT"),
            Some("node"),
        ),
        (
            Some(test_node("LIT", vec![Child::Nil])),
            Some("LIT"),
            Some("nil"),
        ),
    ] {
        assert_eq!(
            normalizer.symbol_literal_node(node.as_ref()),
            ruby_private_symbol_literal_node_predicate(node_type, child_kind),
            "symbol_literal_node? mismatch for node_type={node_type:?} child_kind={child_kind:?}"
        );
    }
}

#[test]
fn same_ts_node_matches_ruby_private_predicate() {
    for (
        source,
        language,
        suffix,
        left_kind,
        left_text,
        left_index,
        right_kind,
        right_text,
        right_index,
    ) in [
        (
            "value\nvalue\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
            0,
            "identifier",
            "value",
            0,
        ),
        (
            "value\nvalue\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
            0,
            "identifier",
            "value",
            1,
        ),
        (
            "value\nvalue\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value",
            0,
            "expression_statement",
            "value",
            0,
        ),
        (
            "value\nvalue\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value",
            0,
            "expression_statement",
            "value",
            1,
        ),
        (
            "value;\nvalue;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "value;",
            0,
            "expression_statement",
            "value;",
            1,
        ),
        (
            "value()\nvalue()\n",
            Language::Lua,
            ".lua",
            "function_call",
            "value()",
            0,
            "function_call",
            "value()",
            0,
        ),
        (
            "value()\nvalue()\n",
            Language::Lua,
            ".lua",
            "function_call",
            "value()",
            0,
            "function_call",
            "value()",
            1,
        ),
    ] {
        let tree = raw_tree(source, language);
        let left = nth_raw_node(tree.root_node(), source, left_kind, left_text, left_index);
        let right = nth_raw_node(
            tree.root_node(),
            source,
            right_kind,
            right_text,
            right_index,
        );
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
                normalizer.same_ts_node(left, right),
                ruby_private_same_ts_node_predicate(
                    source,
                    language,
                    suffix,
                    left_kind,
                    left_text,
                    left_index,
                    right_kind,
                    right_text,
                    right_index
                ),
                "same_ts_node? mismatch for {language:?} {left_kind}:{left_text:?}[{left_index}] vs {right_kind}:{right_text:?}[{right_index}]"
            );
    }
}

#[test]
fn parent_named_child_matches_ruby_private_predicate() {
    for (
        source,
        language,
        suffix,
        parent_kind,
        parent_text,
        parent_index,
        child_kind,
        child_text,
        child_index,
    ) in [
        (
            "def f\n  {name:}\nend\n",
            Language::Ruby,
            ".rb",
            "pair",
            "name:",
            0,
            "hash_key_symbol",
            "name",
            0,
        ),
        (
            "def f\n  {name:}\nend\n",
            Language::Ruby,
            ".rb",
            "pair",
            "name:",
            0,
            "identifier",
            "f",
            0,
        ),
        (
            "def f():\n    value\n",
            Language::Python,
            ".py",
            "function_definition",
            "def f():\n    value",
            0,
            "identifier",
            "f",
            0,
        ),
        (
            "def f():\n    value\n",
            Language::Python,
            ".py",
            "block",
            "value",
            0,
            "identifier",
            "f",
            0,
        ),
        (
            "function f() { value; }\n",
            Language::TypeScript,
            ".ts",
            "function_declaration",
            "function f() { value; }",
            0,
            "identifier",
            "f",
            0,
        ),
        (
            "function f() { value; }\n",
            Language::TypeScript,
            ".ts",
            "statement_block",
            "{ value; }",
            0,
            "identifier",
            "f",
            0,
        ),
        (
            "function f()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "function_declaration",
            "function f()\n  value()\nend",
            0,
            "identifier",
            "f",
            0,
        ),
        (
            "function f()\n  value()\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "value()",
            0,
            "identifier",
            "f",
            0,
        ),
    ] {
        let tree = raw_tree(source, language);
        let parent = nth_raw_node(
            tree.root_node(),
            source,
            parent_kind,
            parent_text,
            parent_index,
        );
        let child = nth_raw_node(
            tree.root_node(),
            source,
            child_kind,
            child_text,
            child_index,
        );
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
                normalizer.parent_named_child(parent, child),
                ruby_private_parent_named_child_predicate(
                    source,
                    language,
                    suffix,
                    parent_kind,
                    parent_text,
                    parent_index,
                    child_kind,
                    child_text,
                    child_index
                ),
                "parent_named_child? mismatch for {language:?} {parent_kind}:{parent_text:?}[{parent_index}] -> {child_kind}:{child_text:?}[{child_index}]"
            );
    }
}

#[test]
fn node_key_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, index) in [
        (
            "value\nvalue\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
            0,
        ),
        (
            "value\nvalue\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
            1,
        ),
        (
            "value\nvalue\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value",
            1,
        ),
        (
            "value;\nvalue;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "value;",
            0,
        ),
        (
            "value()\nvalue()\n",
            Language::Lua,
            ".lua",
            "function_call",
            "value()",
            1,
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = nth_raw_node(tree.root_node(), source, kind, text, index);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.node_key(node),
            ruby_private_node_key_signature(source, language, suffix, kind, text, index),
            "node_key mismatch for {language:?} {kind}:{text:?}[{index}]"
        );
    }
}

#[test]
fn bare_identifier_text_matches_ruby_private_predicate() {
    for text in [
        "value",
        "_value",
        "value1",
        "value?",
        "value!",
        "value=",
        " value? ",
        "",
        "1value",
        "value-name",
        "value?name",
        "value??",
        "value!=",
        "value =",
    ] {
        assert_eq!(
            super::bare_identifier_text(text),
            ruby_private_text_predicate(Language::Ruby, "bare_identifier_text?", text),
            "bare_identifier_text? mismatch for {text:?}"
        );
    }
}

#[test]
fn hidden_match_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "match(value)\n",
            Language::Ruby,
            ".rb",
            "call",
            "match(value)",
        ),
        (
            "match value:\n    case 1:\n        result\n",
            Language::Python,
            ".py",
            "match_statement",
            "match value:\n    case 1:\n        result",
        ),
        (
            "match(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "match(value)",
        ),
        (
            "match(value);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "match(value);",
        ),
        (
            "match(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "match(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.hidden_match(node),
            ruby_private_predicate(source, language, suffix, "hidden_match?", kind, text),
            "hidden_match? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn kind_type_matches_ruby_private_method() {
    for kind in [
        "",
        "body_statement",
        "block_body",
        "block",
        "statements",
        "expression_statement",
        "alreadyCAPS",
        "argument-list??",
        "foo__bar",
        "123kind",
        "é_node",
    ] {
        assert_eq!(
            super::kind_type(kind),
            ruby_private_text_string(Language::Ruby, "kind_type", kind),
            "kind_type mismatch for {kind:?}"
        );
    }
}

#[test]
fn ts_node_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        ("ready?\n", Language::Ruby, ".rb", "call", "ready?"),
        (
            "value\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value",
        ),
        (
            "let value = 1;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "value = 1\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);

        assert_eq!(
            super::ts_node(Some(node)),
            ruby_private_predicate(source, language, suffix, "ts_node?", kind, text),
            "ts_node? raw-node mismatch for {language:?} {kind}:{text:?}"
        );
    }

    assert_eq!(super::ts_node(None), ruby_private_ts_node_value("nil"));
    assert!(!ruby_private_ts_node_value("string"));
    assert!(!ruby_private_ts_node_value("normalized_node"));
}

#[test]
fn command_call_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  puts value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "puts value",
        ),
        (
            "def f\n  foo { value }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { value }",
        ),
        (
            "def f\n  foo\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo",
        ),
        (
            "def f\n  user.name value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name value",
        ),
        (
            "print(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "print(value)",
        ),
        (
            "console.log(value);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "console.log(value);",
        ),
        (
            "print(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "print(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.command_call_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "command_call_statement?",
                kind,
                text
            ),
            "command_call_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_command_call_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  puts value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "puts value",
        ),
        (
            "def f\n  foo { value }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { value }",
        ),
        (
            "print(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "print(value)",
        ),
        (
            "console.log(value);\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "console.log(value);",
        ),
        (
            "print(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "print(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_command_call_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_command_call_statement",
                kind,
                text
            ),
            "normalize_command_call_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn zero_child_identifier_call_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        ("foo?\n", Language::Ruby, ".rb", "call", "foo?"),
        ("foo!\n", Language::Ruby, ".rb", "call", "foo!"),
        ("foo()\n", Language::Ruby, ".rb", "call", "foo()"),
        (
            "foo()\n",
            Language::Python,
            ".py",
            "expression_statement",
            "foo()",
        ),
        (
            "foo();\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "foo()",
        ),
        ("foo()\n", Language::Lua, ".lua", "function_call", "foo()"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.zero_child_identifier_call(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "zero_child_identifier_call?",
                kind,
                text
            ),
            "zero_child_identifier_call? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn zero_child_identifier_call_normalization_matches_ruby() {
    for source in ["foo?\n", "foo!\n"] {
        let root = parse_language_source(source, Language::Ruby, ".rb");
        let text = source.trim();
        let vcall = first_node(&root, "VCALL", text);
        assert_eq!(
            vcall.children.first(),
            Some(&Child::Symbol(text.to_string()))
        );
        assert_ruby_parity(source, Language::Ruby, ".rb");
    }
}

#[test]
fn normalize_zero_child_call_matches_ruby_private_method() {
    for source in ["foo?\n", "foo!\n", "foo()\n"] {
        let text = source.trim();
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, "call", text);
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer.normalize_zero_child_call(node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_zero_child_call",
                "call",
                text
            ),
            "normalize_zero_child_call mismatch for {text:?}"
        );
    }
}

#[test]
fn normalize_const_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("Foo\n", Language::Ruby, ".rb", "constant", "Foo"),
        (
            "Foo::Bar\n",
            Language::Ruby,
            ".rb",
            "scope_resolution",
            "Foo::Bar",
        ),
        (
            "class Foo::Bar::Baz\nend\n",
            Language::Ruby,
            ".rb",
            "scope_resolution",
            "Foo::Bar::Baz",
        ),
        (
            "type Alias = Foo;\n",
            Language::TypeScript,
            ".ts",
            "type_identifier",
            "Foo",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.normalize_const(node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_const",
                kind,
                text
            ),
            "normalize_const mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_receiver_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("value += 1\n", Language::Ruby, ".rb", "identifier", "value"),
        (
            "@value += 1\n",
            Language::Ruby,
            ".rb",
            "instance_variable",
            "@value",
        ),
        (
            "$value += 1\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
        ),
        ("VALUE += 1\n", Language::Ruby, ".rb", "constant", "VALUE"),
        (
            "user.value += 1\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.value",
        ),
        (
            "value += 1\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "user.value += 1\n",
            Language::Python,
            ".py",
            "attribute",
            "user.value",
        ),
        (
            "value += 1;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "user.value += 1;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.value",
        ),
        (
            "value = 1\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
        (
            "user.value = 1\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "user.value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .assignment_receiver(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "assignment_receiver",
                kind,
                text
            ),
            "assignment_receiver mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn assignment_target_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "@value = 1\n",
            Language::Ruby,
            ".rb",
            "instance_variable",
            "@value",
        ),
        (
            "$value = 1\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
        ),
        (
            "items[index] = value\n",
            Language::Ruby,
            ".rb",
            "element_reference",
            "items[index]",
        ),
        (
            "user.value = 1\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.value",
        ),
        (
            "user.value = 1\n",
            Language::Python,
            ".py",
            "attribute",
            "user.value",
        ),
        (
            "user.value = 1;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.value",
        ),
        (
            "user.value = 1\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "user.value",
        ),
        (
            "value = 1\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let source_node = normalizer.parent_node(node).unwrap_or(node);
        let right = normalizer
            .assignment_right(source_node)
            .and_then(|right| normalizer.normalize_node(right));
        let rust = normalizer
            .assignment_target(node, right, source_node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_assignment_target_value(source, language, suffix, kind, text),
            "assignment_target mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn augmented_assignment_value_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, operator) in [
        (
            "value += 1\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
            "+",
        ),
        (
            "@value *= 2\n",
            Language::Ruby,
            ".rb",
            "instance_variable",
            "@value",
            "*",
        ),
        (
            "$value += 1\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
            "+",
        ),
        (
            "VALUE -= 1\n",
            Language::Ruby,
            ".rb",
            "constant",
            "VALUE",
            "-",
        ),
        (
            "user.value += 1\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.value",
            "+",
        ),
        (
            "value += 1\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
            "+",
        ),
        (
            "user.value += 1\n",
            Language::Python,
            ".py",
            "attribute",
            "user.value",
            "+",
        ),
        (
            "value += 1;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
            "+",
        ),
        (
            "user.value += 1;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.value",
            "+",
        ),
        (
            "value = 1\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
            "+",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let source_node = normalizer.parent_node(node).unwrap_or(node);
        let right_raw = normalizer.assignment_right(source_node);
        let rust = normalizer.augmented_assignment_value(node, operator, right_raw, source_node);

        assert_eq!(
            node_value(&rust),
            ruby_private_augmented_assignment_value(source, language, suffix, kind, text, operator),
            "augmented_assignment_value mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn target_name_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "$value = other\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
        ),
        (
            "VALUE = other\n",
            Language::Ruby,
            ".rb",
            "constant",
            "VALUE",
        ),
        (
            "a, *rest = values\n",
            Language::Ruby,
            ".rb",
            "rest_assignment",
            "*rest",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "let value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            Value::String(normalizer.target_name(node)),
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "target_name",
                kind,
                text
            ),
            "target_name mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_multiple_assignment_matches_ruby_private_method() {
    for (source, kind, text) in [
        ("a, b = values\n", "assignment", "a, b = values"),
        ("$a, b = values\n", "assignment", "$a, b = values"),
        ("a, *rest = values\n", "assignment", "a, *rest = values"),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let left = normalizer
            .assignment_left(node)
            .expect("multiple assignment should have left side");
        let right = normalizer
            .assignment_right(node)
            .and_then(|right| normalizer.normalize_node(right));
        let rust = normalizer.normalize_multiple_assignment(left, right, node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_multiple_assignment_value(
                source,
                Language::Ruby,
                ".rb",
                kind,
                text
            ),
            "normalize_multiple_assignment mismatch for {text:?}"
        );
    }
}

#[test]
fn normalize_assignment_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "value = other",
        ),
        (
            "@value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "@value = other",
        ),
        (
            "$value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "$value = other",
        ),
        (
            "items[index] = value\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "items[index] = value",
        ),
        (
            "user.value = other\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "user.value = other",
        ),
        (
            "a, b = values\n",
            Language::Ruby,
            ".rb",
            "assignment",
            "a, b = values",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "expression_statement",
            "value = other",
        ),
        (
            "user.value = other\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user.value = other",
        ),
        (
            "value = other;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "value = other;",
        ),
        (
            "user.value = other;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "user.value = other;",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "assignment_statement",
            "value = other",
        ),
        (
            "user.value = other\n",
            Language::Lua,
            ".lua",
            "assignment_statement",
            "user.value = other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_assignment(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_assignment",
                kind,
                text
            ),
            "normalize_assignment mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_assignment_lhs_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "value = other\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "value",
        ),
        (
            "@value = other\n",
            Language::Ruby,
            ".rb",
            "instance_variable",
            "@value",
        ),
        (
            "$value = other\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "$value",
        ),
        (
            "items[index] = value\n",
            Language::Ruby,
            ".rb",
            "element_reference",
            "items[index]",
        ),
        (
            "user.value = other\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.value",
        ),
        (
            "value = other\n",
            Language::Python,
            ".py",
            "identifier",
            "value",
        ),
        (
            "user.value = other\n",
            Language::Python,
            ".py",
            "attribute",
            "user.value",
        ),
        (
            "value = other;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "value",
        ),
        (
            "user.value = other;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.value",
        ),
        (
            "value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "value",
        ),
        (
            "user.value = other\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "user.value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_assignment_lhs(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_assignment_lhs",
                kind,
                text
            ),
            "normalize_assignment_lhs mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_begin_matches_ruby_private_method() {
    for (source, text) in [
        ("begin\n  work\n  done\nend\n", "begin\n  work\n  done\nend"),
        (
            "begin\n  work\nensure\n  cleanup\nend\n",
            "begin\n  work\nensure\n  cleanup\nend",
        ),
        (
            "begin\n  work\nrescue Error => e\n  handle\nend\n",
            "begin\n  work\nrescue Error => e\n  handle\nend",
        ),
        (
            "begin\n  work\nrescue Error => e\n  handle\nensure\n  cleanup\nend\n",
            "begin\n  work\nrescue Error => e\n  handle\nensure\n  cleanup\nend",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, "begin", text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_begin(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_begin",
                "begin",
                text
            ),
            "normalize_begin mismatch for {text:?}"
        );
    }
}

#[test]
fn normalize_block_argument_matches_ruby_private_method() {
    for (source, text) in [
        ("foo(&block)\n", "&block"),
        ("foo(&:to_s)\n", "&:to_s"),
        ("foo(&method(:bar))\n", "&method(:bar)"),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, "block_argument", text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_block_argument(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_block_argument",
                "block_argument",
                text
            ),
            "normalize_block_argument mismatch for {text:?}"
        );
    }
}

#[test]
fn normalize_body_nodes_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("\n", Language::Ruby, ".rb", "__root__", ""),
        ("value\n", Language::Ruby, ".rb", "__root__", ""),
        ("first\nsecond\n", Language::Ruby, ".rb", "__root__", ""),
        (
            "first()\nsecond()\n",
            Language::Python,
            ".py",
            "__root__",
            "",
        ),
        (
            "first();\nsecond();\n",
            Language::TypeScript,
            ".ts",
            "__root__",
            "",
        ),
        ("first()\nsecond()\n", Language::Lua, ".lua", "__root__", ""),
    ] {
        let tree = raw_tree(source, language);
        let target = if kind == "__root__" {
            tree.root_node()
        } else {
            first_raw_node(tree.root_node(), source, kind, text)
        };
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let nodes = normalizer.named_children(target);
        let rust = normalizer
            .normalize_body_nodes(nodes, target)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_body_nodes_value(source, language, suffix, kind, text),
            "normalize_body_nodes mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_children_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  one\n  two\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "one\n  two",
        ),
        (
            "def f\n  value = other\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value = other",
        ),
        (
            "def f\n  x = <<~TXT\n    hi\n  TXT\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x = <<~TXT\n    hi\n  TXT",
        ),
        (
            "def f():\n    one()\n    two()\n",
            Language::Python,
            ".py",
            "block",
            "one()\n    two()",
        ),
        (
            "def f():\n    value = other\n",
            Language::Python,
            ".py",
            "block",
            "value = other",
        ),
        (
            "function f(){ one(); two(); }\n",
            Language::TypeScript,
            ".ts",
            "statement_block",
            "{ one(); two(); }",
        ),
        (
            "function f(){ value = other; }\n",
            Language::TypeScript,
            ".ts",
            "assignment_expression",
            "value = other",
        ),
        (
            "function f()\n  one()\n  two()\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "one()\n  two()",
        ),
        (
            "function f()\n  value = other\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "value = other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = children_value(&normalizer.normalize_children(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_children",
                kind,
                text
            ),
            "normalize_children mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_class_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "class Thing; end\n",
            Language::Ruby,
            ".rb",
            "class",
            "class Thing; end",
        ),
        (
            "class Thing:\n    pass\n",
            Language::Python,
            ".py",
            "class_definition",
            "class Thing:\n    pass",
        ),
        (
            "class Thing {}\n",
            Language::TypeScript,
            ".ts",
            "class_declaration",
            "class Thing {}",
        ),
        (
            "local Thing = {}\n",
            Language::Lua,
            ".lua",
            "variable_declaration",
            "local Thing = {}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_class(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_class",
                kind,
                text
            ),
            "normalize_class mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_class_like_owner_matches_ruby_private_impl_method() {
    for (source, kind, text) in [(
        "impl Thing {\n    fn call(&self) {\n        work();\n    }\n}\n",
        "impl_item",
        "impl Thing {\n    fn call(&self) {\n        work();\n    }\n}",
    )] {
        let tree = raw_tree(source, Language::Rust);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Rust);
        let rust = normalizer
            .normalize_class_like_owner(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Rust,
                ".rs",
                "normalize_impl",
                kind,
                text
            ),
            "normalize_impl mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn rust_impl_normalization_matches_ruby() {
    let source = "impl Thing {\n    fn call(&self) {\n        work();\n    }\n}\n";
    let root = parse_language_source(source, Language::Rust, ".rs");
    let class_node = first_node(&root, "CLASS", source.trim_end());

    assert_eq!(child_node(class_node, 0).r#type, "CONST");
    assert_ruby_parity(source, Language::Rust, ".rs");
}

#[test]
fn normalize_body_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value",
        ),
        (
            "def f\n  return value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "return value",
        ),
        (
            "def f\n  items[index]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items[index]",
        ),
        (
            "def f\n  [first, second]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "[first, second]",
        ),
        (
            "def f\n  value if ready?\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "value if ready?",
        ),
        (
            "def f\n  left && right\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "left && right",
        ),
        (
            "def f():\n    return value\n",
            Language::Python,
            ".py",
            "block",
            "return value",
        ),
        (
            "def f():\n    value = other\n",
            Language::Python,
            ".py",
            "block",
            "value = other",
        ),
        (
            "function f() {\n  return value;\n}\n",
            Language::TypeScript,
            ".ts",
            "return_statement",
            "return value;",
        ),
        (
            "function f() {\n  value = other;\n}\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "value = other;",
        ),
        (
            "function f()\n  return value\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "return value",
        ),
        (
            "function f()\n  value = other\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "value = other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_body(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_body",
                kind,
                text
            ),
            "normalize_body mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_return_value_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  return nil\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "nil",
        ),
        (
            "def f\n  return items[index]\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "items[index]",
        ),
        (
            "def f\n  return left && right\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "left && right",
        ),
        (
            "def f\n  return condition ? yes : no\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "condition ? yes : no",
        ),
        (
            "def f\n  return foo { value }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo { value }",
        ),
        (
            "def f\n  return user.name\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "user.name",
        ),
        (
            "def f\n  return !value\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "!value",
        ),
        (
            "def f\n  return left + right\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "left + right",
        ),
        (
            "def f\n  return foo(bar)\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo(bar)",
        ),
        (
            "def f():\n    return value + other\n",
            Language::Python,
            ".py",
            "binary_operator",
            "value + other",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_return_value(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_return_value",
                kind,
                text
            ),
            "normalize_return_value mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_return_node_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, elide_symbol) in [
        (
            "return :ok if cond\n",
            Language::Ruby,
            ".rb",
            "return",
            "return :ok",
            false,
        ),
        (
            "return :ok if cond\n",
            Language::Ruby,
            ".rb",
            "return",
            "return :ok",
            true,
        ),
        (
            "return value if cond\n",
            Language::Ruby,
            ".rb",
            "return",
            "return value",
            true,
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_return_node_with_elide_symbol(node, elide_symbol)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
                rust,
                ruby_private_normalize_return_node_value(
                    source,
                    language,
                    suffix,
                    kind,
                    text,
                    elide_symbol
                ),
                "normalize_return_node mismatch for {language:?} {kind} {text:?} elide_symbol={elide_symbol}"
            );
    }
}

#[test]
fn normalize_return_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "return :ok if cond\n",
            Language::Ruby,
            ".rb",
            "return",
            "return :ok",
        ),
        ("break if done\n", Language::Ruby, ".rb", "break", "break"),
        (
            "next value if done\n",
            Language::Ruby,
            ".rb",
            "next",
            "next value",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_return(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_return",
                kind,
                text
            ),
            "normalize_return mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn call_arguments_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, function_mode) in [
        (
            "foo(value)\n",
            Language::Ruby,
            ".rb",
            "call",
            "foo(value)",
            "auto",
        ),
        (
            "foo(left + right)\n",
            Language::Ruby,
            ".rb",
            "call",
            "foo(left + right)",
            "auto",
        ),
        (
            "foo(user.name)\n",
            Language::Ruby,
            ".rb",
            "call",
            "foo(user.name)",
            "auto",
        ),
        (
            "user.name(value)\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.name(value)",
            "none",
        ),
        (
            "foo(value)\n",
            Language::Python,
            ".py",
            "call",
            "foo(value)",
            "auto",
        ),
        (
            "foo(value);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "foo(value)",
            "auto",
        ),
        (
            "foo(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "foo(value)",
            "auto",
        ),
        (
            "user.name(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "user.name(value)",
            "none",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let function = match function_mode {
            "auto" => normalizer
                .named_field(node, "function")
                .or_else(|| normalizer.named_field(node, "call"))
                .or_else(|| normalizer.named_children(node).into_iter().next()),
            "none" => None,
            other => panic!("unknown function mode {other:?}"),
        };
        let rust = Value::Array(
            normalizer
                .call_arguments(node, function)
                .iter()
                .map(node_value)
                .collect(),
        );

        assert_eq!(
            rust,
            ruby_private_call_arguments_value(source, language, suffix, kind, text, function_mode),
            "call_arguments mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_call_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("ready?\n", Language::Ruby, ".rb", "call", "ready?"),
        ("foo(value)\n", Language::Ruby, ".rb", "call", "foo(value)"),
        (
            "user.name(value)\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.name(value)",
        ),
        (
            "def f\n  foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { bar }",
        ),
        (
            "foo(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "foo(value)",
        ),
        (
            "foo(value);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "foo(value)",
        ),
        (
            "foo(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "foo(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_call(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_call",
                kind,
                text
            ),
            "normalize_call mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_call_with_block_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "items.map { |item| item }\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.map { |item| item }",
        ),
        (
            "items.each do |item|\n  item\nend\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.each do |item|\n  item\nend",
        ),
        (
            "foo(1) { bar }\n",
            Language::Ruby,
            ".rb",
            "call",
            "foo(1) { bar }",
        ),
        (
            "def f\n  foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { bar }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_call_with_block(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_call_with_block",
                kind,
                text
            ),
            "normalize_call_with_block mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_call_without_block_matches_ruby_private_method() {
    for (source, language, suffix, kind, text, block_mode) in [
        (
            "foo(value)\n",
            Language::Ruby,
            ".rb",
            "call",
            "foo(value)",
            "none",
        ),
        (
            "user.name(value)\n",
            Language::Ruby,
            ".rb",
            "call",
            "user.name(value)",
            "none",
        ),
        (
            "foo(1) { bar }\n",
            Language::Ruby,
            ".rb",
            "call",
            "foo(1) { bar }",
            "auto",
        ),
        (
            "items.map(1) { |item| item }\n",
            Language::Ruby,
            ".rb",
            "call",
            "items.map(1) { |item| item }",
            "auto",
        ),
        (
            "Foo { bar }\n",
            Language::Ruby,
            ".rb",
            "call",
            "Foo { bar }",
            "auto",
        ),
        (
            "foo(value)\n",
            Language::Python,
            ".py",
            "expression_statement",
            "foo(value)",
            "none",
        ),
        (
            "foo(value);\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "foo(value)",
            "none",
        ),
        (
            "foo(value)\n",
            Language::Lua,
            ".lua",
            "function_call",
            "foo(value)",
            "none",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let block = match block_mode {
            "auto" => normalizer.call_block(node),
            "none" => None,
            other => panic!("unknown block mode {other:?}"),
        };
        let rust = normalizer
            .normalize_call_without_block(node, block)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
                rust,
                ruby_private_normalize_call_without_block_value(
                    source, language, suffix, kind, text, block_mode
                ),
                "normalize_call_without_block mismatch for {language:?} {kind} {text:?} with block mode {block_mode:?}"
            );
    }
}

#[test]
fn command_arguments_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "foo value\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "value",
        ),
        (
            "foo :name\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            ":name",
        ),
        (
            "foo left + right\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "left + right",
        ),
        (
            "foo user.name\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "user.name",
        ),
        (
            "foo(value)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(value)",
        ),
        (
            "foo(left + right)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(left + right)",
        ),
        (
            "foo(value);\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(value)",
        ),
        (
            "foo(value)\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(value)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = Value::Array(
            normalizer
                .command_arguments(node)
                .iter()
                .map(node_value)
                .collect(),
        );

        assert_eq!(
            rust,
            ruby_private_command_arguments_value(source, language, suffix, kind, text),
            "command_arguments mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn const_for_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("Foo\n", Language::Ruby, ".rb", "constant", "Foo"),
        ("foo\n", Language::Ruby, ".rb", "identifier", "foo"),
        (
            "class Foo:\n    pass\n",
            Language::Python,
            ".py",
            "identifier",
            "Foo",
        ),
        (
            "type Alias = Foo;\n",
            Language::TypeScript,
            ".ts",
            "type_identifier",
            "Foo",
        ),
        (
            "local Foo = {}\n",
            Language::Lua,
            ".lua",
            "variable_list",
            "Foo",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.const_for(Some(node), node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_method_value(source, language, suffix, "const_for", kind, text),
            "const_for mismatch for {language:?} {kind} {text:?}"
        );
    }

    for (source, language, suffix) in [
        ("class Foo\nend\n", Language::Ruby, ".rb"),
        ("class Foo:\n    pass\n", Language::Python, ".py"),
        ("class Foo {}\n", Language::TypeScript, ".ts"),
        ("local Foo = {}\n", Language::Lua, ".lua"),
    ] {
        let tree = raw_tree(source, language);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.const_for(None, tree.root_node());

        assert_eq!(
            node_value(&rust),
            ruby_private_const_for_nil_value(source, language, suffix),
            "const_for nil mismatch for {language:?}"
        );
    }
}

#[test]
fn normalize_patterns_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when 1\n  one",
        ),
        (
            "case\nwhen ready\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when ready\n  one",
        ),
        (
            "case value\nwhen Foo::Bar\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when Foo::Bar\n  one",
        ),
        (
            "case value\nwhen Foo\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when Foo\n  one",
        ),
        (
            "match value:\n    case 1:\n        one()\n",
            Language::Python,
            ".py",
            "case_clause",
            "case 1:\n        one()",
        ),
        (
            "switch (value) { case 1: one(); default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_case",
            "case 1: one();",
        ),
        ("return 1\n", Language::Lua, ".lua", "expression_list", "1"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = Value::Array(
            normalizer
                .normalize_patterns(node)
                .iter()
                .map(node_value)
                .collect(),
        );

        assert_eq!(
            rust,
            ruby_private_normalize_patterns_value(source, language, suffix, kind, text),
            "normalize_patterns mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn case_value_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case value\nwhen 1\n  one\nend",
        ),
        (
            "case\nwhen ready\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case\nwhen ready\n  one\nend",
        ),
        (
            "match value:\n    case 1:\n        one()\n",
            Language::Python,
            ".py",
            "match_statement",
            "match value:\n    case 1:\n        one()",
        ),
        (
            "switch (value) { case 1: one(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (value) { case 1: one(); }",
        ),
        (
            "if value == 1 then one() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.case_value(node).map(|value| {
            (
                value.kind().to_string(),
                super::node_text(value, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(source, language, suffix, "case_value", kind, text),
            "case_value mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn case_arms_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend",
        ),
        (
            "match value:\n    case 1:\n        one()\n    case _:\n        other()\n",
            Language::Python,
            ".py",
            "match_statement",
            "match value:\n    case 1:\n        one()\n    case _:\n        other()",
        ),
        (
            "switch (value) { case 1: one(); default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (value) { case 1: one(); default: other(); }",
        ),
        (
            "if value == 1 then one() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .case_arms(node)
            .into_iter()
            .map(|arm| {
                (
                    arm.kind().to_string(),
                    super::node_text(arm, source).to_string(),
                )
            })
            .collect::<Vec<_>>();

        assert_eq!(
            rust,
            ruby_private_node_list_signature(source, language, suffix, "case_arms", kind, text),
            "case_arms mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn when_body_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when 1\n  one",
        ),
        (
            "match value:\n    case 1:\n        one()\n",
            Language::Python,
            ".py",
            "case_clause",
            "case 1:\n        one()",
        ),
        (
            "switch (value) { case 1: one(); default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_case",
            "case 1: one();",
        ),
        (
            "switch (value) { case 1: one(); default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_default",
            "default: other();",
        ),
        (
            "if value == 1 then one() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.when_body(node).map(|body| {
            (
                body.kind().to_string(),
                super::node_text(body, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(source, language, suffix, "when_body", kind, text),
            "when_body mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_when_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when 1\n  one",
        ),
        (
            "case value\nwhen Foo::Bar\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "when",
            "when Foo::Bar\n  one",
        ),
        (
            "match value:\n    case 1:\n        one()\n",
            Language::Python,
            ".py",
            "case_clause",
            "case 1:\n        one()",
        ),
        (
            "switch (value) { case 1: one(); break; default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_case",
            "case 1: one(); break;",
        ),
        (
            "if value == 1 then one() else other() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() else other() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_when(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_when",
                kind,
                text
            ),
            "normalize_when mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn case_else_body_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nelse\n  other\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case value\nwhen 1\n  one\nelse\n  other\nend",
        ),
        (
            "case value\nwhen 1\n  one\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case value\nwhen 1\n  one\nend",
        ),
        (
            "match value:\n    case 1:\n        one()\n    case _:\n        other()\n",
            Language::Python,
            ".py",
            "match_statement",
            "match value:\n    case 1:\n        one()\n    case _:\n        other()",
        ),
        (
            "match value:\n    case 1:\n        one()\n",
            Language::Python,
            ".py",
            "match_statement",
            "match value:\n    case 1:\n        one()",
        ),
        (
            "switch (value) { case 1: one(); break; default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (value) { case 1: one(); break; default: other(); }",
        ),
        (
            "switch (value) { case 1: one(); break; }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (value) { case 1: one(); break; }",
        ),
        (
            "if value == 1 then one() else other() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() else other() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .case_else_body(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "case_else_body",
                kind,
                text
            ),
            "case_else_body mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_case_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case value\nwhen 1\n  one\nwhen 2\n  two\nelse\n  other\nend",
        ),
        (
            "case\nwhen ready\n  one\nelse\n  other\nend\n",
            Language::Ruby,
            ".rb",
            "case",
            "case\nwhen ready\n  one\nelse\n  other\nend",
        ),
        (
            "match value:\n    case 1:\n        one()\n    case _:\n        other()\n",
            Language::Python,
            ".py",
            "match_statement",
            "match value:\n    case 1:\n        one()\n    case _:\n        other()",
        ),
        (
            "switch (value) { case 1: one(); break; default: other(); }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (value) { case 1: one(); break; default: other(); }",
        ),
        (
            "if value == 1 then one() else other() end\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if value == 1 then one() else other() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_case(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_case",
                kind,
                text
            ),
            "normalize_case mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn dotted_call_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
        ("user\n", Language::Ruby, ".rb", "identifier", "user"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user",
        ),
        (
            "user.name();\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        ("user;\n", Language::TypeScript, ".ts", "identifier", "user"),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
        ("user()\n", Language::Lua, ".lua", "function_call", "user()"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.dotted_call(node),
            ruby_private_predicate(source, language, suffix, "dotted_call?", kind, text),
            "dotted_call? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn dotted_expression_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  user.name\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name",
        ),
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        (
            "user.name\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user.name",
        ),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user.name;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "user.name;",
        ),
        (
            "user.name;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.dotted_expression(node),
            ruby_private_predicate(source, language, suffix, "dotted_expression?", kind, text),
            "dotted_expression? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn dotted_expression_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def f\n  user.name\nend\n", Language::Ruby, ".rb"),
        ("user.name\n", Language::Python, ".py"),
    ] {
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn normalize_else_or_branch_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "if ready\n  call\nelse\n  stop\nend\n",
            Language::Ruby,
            ".rb",
            "else",
            "else\n  stop",
        ),
        (
            "if ready\n  call\nelse\n  user.name\nend\n",
            Language::Ruby,
            ".rb",
            "else",
            "else\n  user.name",
        ),
        (
            "if ready:\n    call()\nelse:\n    stop()\n",
            Language::Python,
            ".py",
            "else_clause",
            "else:\n    stop()",
        ),
        (
            "if ready:\n    call()\nelse:\n    if backup:\n        stop()\n",
            Language::Python,
            ".py",
            "else_clause",
            "else:\n    if backup:\n        stop()",
        ),
        (
            "if (ready) { call(); } else { stop(); }\n",
            Language::TypeScript,
            ".ts",
            "else_clause",
            "else { stop(); }",
        ),
        (
            "if ready then\n  call()\nelse\n  stop()\nend\n",
            Language::Lua,
            ".lua",
            "else_statement",
            "else\n  stop()",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_else_or_branch(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_else_or_branch",
                kind,
                text
            ),
            "normalize_else_or_branch mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_if_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "if ready\n  call\nelse\n  stop\nend\n",
            Language::Ruby,
            ".rb",
            "if",
            "if ready\n  call\nelse\n  stop\nend",
        ),
        (
            "call if ready\n",
            Language::Ruby,
            ".rb",
            "if_modifier",
            "call if ready",
        ),
        (
            "unless ready\n  call\nend\n",
            Language::Ruby,
            ".rb",
            "unless",
            "unless ready\n  call\nend",
        ),
        (
            "if ready:\n    call()\nelse:\n    stop()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()\nelse:\n    stop()",
        ),
        (
            "if ready:\n    call()\nelif other:\n    stop()\n",
            Language::Python,
            ".py",
            "if_statement",
            "if ready:\n    call()\nelif other:\n    stop()",
        ),
        (
            "if (ready) { call(); } else { stop(); }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (ready) { call(); } else { stop(); }",
        ),
        (
            "if ready then\n  call()\nelseif other then\n  stop()\nend\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if ready then\n  call()\nelseif other then\n  stop()\nend",
        ),
        (
            "if ready then\n  call()\nelse\n  stop()\nend\n",
            Language::Lua,
            ".lua",
            "if_statement",
            "if ready then\n  call()\nelse\n  stop()\nend",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_if(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_if",
                kind,
                text
            ),
            "normalize_if mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_elsif_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "if ready\n  call\nelsif other\n  stop\nend\n",
            "elsif",
            "elsif other\n  stop",
        ),
        (
            "if ready\n  call\nelsif other\n  stop\nelse\n  done\nend\n",
            "elsif",
            "elsif other\n  stop\nelse\n  done",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = node_value(&normalizer.normalize_elsif(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_elsif",
                kind,
                text
            ),
            "normalize_elsif mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_loop_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "while ready\n  work\nend\n",
            Language::Ruby,
            ".rb",
            "while",
            "while ready\n  work\nend",
        ),
        (
            "work while ready\n",
            Language::Ruby,
            ".rb",
            "while_modifier",
            "work while ready",
        ),
        (
            "work until ready\n",
            Language::Ruby,
            ".rb",
            "until_modifier",
            "work until ready",
        ),
        (
            "for item in items\n  work\nend\n",
            Language::Ruby,
            ".rb",
            "for",
            "for item in items\n  work\nend",
        ),
        (
            "while ready:\n    work()\n",
            Language::Python,
            ".py",
            "while_statement",
            "while ready:\n    work()",
        ),
        (
            "for item in items:\n    work()\n",
            Language::Python,
            ".py",
            "for_statement",
            "for item in items:\n    work()",
        ),
        (
            "while ready do\n  work()\nend\n",
            Language::Lua,
            ".lua",
            "while_statement",
            "while ready do\n  work()\nend",
        ),
        (
            "while (ready) { work(); }\n",
            Language::TypeScript,
            ".ts",
            "while_statement",
            "while (ready) { work(); }",
        ),
        (
            "for (let i = 0; i < n; i++) { work(i); }\n",
            Language::TypeScript,
            ".ts",
            "for_statement",
            "for (let i = 0; i < n; i++) { work(i); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let node_type = normalizer
            .loop_node_type(node.kind())
            .expect("test node should be a loop kind");
        let rust = normalizer
            .normalize_loop(node, node_type)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_loop",
                kind,
                text
            ),
            "normalize_loop mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_elsif_normalization_matches_ruby() {
    for source in [
        "if ready\n  call\nelsif other\n  stop\nend\n",
        "if ready\n  call\nelsif other\n  stop\nelse\n  done\nend\n",
    ] {
        let root = parse_language_source(source, Language::Ruby, ".rb");
        let if_node = first_node(&root, "IF", source.trim_end());

        assert_eq!(
            child_node(if_node, 2).r#type,
            "IF",
            "expected Ruby elsif alternative to normalize as nested IF: {if_node:#?}"
        );
        assert_ruby_parity(source, Language::Ruby, ".rb");
    }
}

#[test]
fn normalize_dotted_expression_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  user.name\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name",
        ),
        (
            "def f\n  user.name { value }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name { value }",
        ),
        (
            "user.name\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user.name",
        ),
        (
            "user.name;\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "user.name;",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_dotted_expression(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_dotted_expression",
                kind,
                text
            ),
            "normalize_dotted_expression mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_dotted_call_expression_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  user.name\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name",
        ),
        (
            "def f\n  user.name(1)\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name(1)",
        ),
        (
            "def f\n  user&.name\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user&.name",
        ),
        (
            "def f\n  user.name { value }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "user.name { value }",
        ),
        (
            "user.name\n",
            Language::Python,
            ".py",
            "expression_statement",
            "user.name",
        ),
        (
            "user.name;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_dotted_call_expression(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_dotted_call_expression",
                kind,
                text
            ),
            "normalize_dotted_call_expression mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn argument_list_call_with_block_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  return foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo { bar }",
        ),
        (
            "def f\n  return foo do\n    bar\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo do\n    bar\n  end",
        ),
        (
            "def f\n  return foo(1) { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo(1) { bar }",
        ),
        (
            "def f\n  foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { bar }",
        ),
        (
            "def f\n  return foo.bar { baz }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo.bar { baz }",
        ),
        (
            "def f\n  return Foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "Foo { bar }",
        ),
        (
            "def f():\n    return foo(lambda: bar)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(lambda: bar)",
        ),
        (
            "function f(){ return foo(() => bar); }\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(() => bar)",
        ),
        (
            "function f() return foo(function() return bar end) end\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(function() return bar end)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.argument_list_call_with_block(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "argument_list_call_with_block?",
                kind,
                text
            ),
            "argument_list_call_with_block? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_argument_list_call_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  return foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo { bar }",
        ),
        (
            "def f\n  return foo do\n    bar\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo do\n    bar\n  end",
        ),
        (
            "def f\n  return foo(1) { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo(1) { bar }",
        ),
        (
            "def f\n  foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { bar }",
        ),
        (
            "def f():\n    return foo(lambda: bar)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(lambda: bar)",
        ),
        (
            "function f(){ return foo(() => bar); }\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(() => bar)",
        ),
        (
            "function f() return foo(function() return bar end) end\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(function() return bar end)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_argument_list_call(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_argument_list_call",
                kind,
                text
            ),
            "normalize_argument_list_call mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_argument_list_call_with_block_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  return foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo { bar }",
        ),
        (
            "def f\n  return foo do\n    bar\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo do\n    bar\n  end",
        ),
        (
            "def f\n  return foo(1) { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "foo(1) { bar }",
        ),
        (
            "def f\n  foo { bar }\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo { bar }",
        ),
        (
            "def f():\n    return foo(lambda: bar)\n",
            Language::Python,
            ".py",
            "argument_list",
            "(lambda: bar)",
        ),
        (
            "function f(){ return foo(() => bar); }\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "(() => bar)",
        ),
        (
            "function f() return foo(function() return bar end) end\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(function() return bar end)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_argument_list_call_with_block(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_argument_list_call_with_block",
                kind,
                text
            ),
            "normalize_argument_list_call_with_block mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn safe_navigation_call_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user?.name;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user?.name",
        ),
        (
            "user?.name();\n",
            Language::TypeScript,
            ".ts",
            "call_expression",
            "user?.name()",
        ),
        (
            "user.name;\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.safe_navigation_call(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "safe_navigation_call?",
                kind,
                text
            ),
            "safe_navigation_call? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn rescue_source_end_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "begin\n  work\nrescue Error => e\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "rescue",
            "rescue Error => e\n  handle",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle()\n",
            Language::Python,
            ".py",
            "except_clause",
            "except Error as e:\n    handle()",
        ),
        (
            "try { work(); } catch (e) { handle(); }\n",
            Language::TypeScript,
            ".ts",
            "catch_clause",
            "catch (e) { handle(); }",
        ),
        ("work()\n", Language::Lua, ".lua", "function_call", "work()"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.rescue_source_end(node).map(|source_end| {
            (
                source_end.kind().to_string(),
                super::node_text(source_end, source).to_string(),
            )
        });

        assert_eq!(
            rust,
            ruby_private_node_signature(source, language, suffix, "rescue_source_end", kind, text),
            "rescue_source_end mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn rescue_exception_variable_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "begin\n  work\nrescue Error => e\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "rescue",
            "rescue Error => e\n  handle",
        ),
        (
            "begin\n  work\nrescue Error\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "rescue",
            "rescue Error\n  handle",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle()\n",
            Language::Python,
            ".py",
            "except_clause",
            "except Error as e:\n    handle()",
        ),
        (
            "try:\n    work()\nexcept Error:\n    handle()\n",
            Language::Python,
            ".py",
            "except_clause",
            "except Error:\n    handle()",
        ),
        (
            "try { work(); } catch (e) { handle(); }\n",
            Language::TypeScript,
            ".ts",
            "catch_clause",
            "catch (e) { handle(); }",
        ),
        ("work()\n", Language::Lua, ".lua", "function_call", "work()"),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .rescue_exception_variable(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "rescue_exception_variable",
                kind,
                text
            ),
            "rescue_exception_variable mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_rescue_clause_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "begin\n  work\nrescue Error => e\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "rescue",
            "rescue Error => e\n  handle",
        ),
        (
            "begin\n  work\nrescue Net::Error\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "rescue",
            "rescue Net::Error\n  handle",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
            Language::Python,
            ".py",
            "except_clause",
            "except Error as e:\n    handle(e)",
        ),
        (
            "try { work(); } catch (e) { handle(e); }\n",
            Language::TypeScript,
            ".ts",
            "catch_clause",
            "catch (e) { handle(e); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_rescue_clause(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_rescue_clause",
                kind,
                text
            ),
            "normalize_rescue_clause mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_rescue_modifier_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [(
        "value rescue fallback\n",
        Language::Ruby,
        ".rb",
        "rescue_modifier",
        "value rescue fallback",
    )] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_rescue_modifier(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_rescue_modifier",
                kind,
                text
            ),
            "normalize_rescue_modifier mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn prepend_rescue_exception_assignment_matches_ruby_private_method() {
    fn synthetic_node(
        node_type: &str,
        text: &str,
        first_lineno: usize,
        first_column: usize,
        last_lineno: usize,
        last_column: usize,
        children: Vec<Child>,
    ) -> Node {
        Node {
            r#type: node_type.to_string(),
            children,
            first_lineno,
            first_column,
            last_lineno,
            last_column,
            text: text.to_string(),
        }
    }

    let source = "assign\nbody\n";
    let assignment = synthetic_node("LASGN", "assign", 1, 0, 1, 6, Vec::new());
    let body = synthetic_node("VCALL", "body", 2, 0, 2, 4, Vec::new());
    let block = synthetic_node(
        "BLOCK",
        "body",
        2,
        0,
        2,
        4,
        vec![Child::Node(Box::new(body.clone())), Child::Nil],
    );

    for (label, body_node, assignment_node) in [
        ("no_assignment", Some(body.clone()), None),
        ("no_body", None, Some(assignment.clone())),
        ("block_body", Some(block), Some(assignment.clone())),
        ("scalar_body", Some(body), Some(assignment)),
    ] {
        let normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .prepend_rescue_exception_assignment(body_node.clone(), assignment_node.clone())
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);
        let body_value = body_node.as_ref().map(node_value).unwrap_or(Value::Null);
        let assignment_value = assignment_node
            .as_ref()
            .map(node_value)
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_prepend_rescue_exception_assignment_value(
                source,
                &body_value,
                &assignment_value
            ),
            "prepend_rescue_exception_assignment mismatch for {label}"
        );
    }
}

#[test]
fn dotted_call_parts_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        ("user.name\n", Language::Ruby, ".rb", "call", "user.name"),
        ("user&.name\n", Language::Ruby, ".rb", "call", "user&.name"),
        (
            "user.name()\n",
            Language::Python,
            ".py",
            "attribute",
            "user.name",
        ),
        (
            "user.name();\n",
            Language::TypeScript,
            ".ts",
            "member_expression",
            "user.name",
        ),
        (
            "user.name()\n",
            Language::Lua,
            ".lua",
            "dot_index_expression",
            "user.name",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .dotted_call_parts(node, None)
            .map(|(receiver, method)| {
                (
                    receiver.kind().to_string(),
                    super::node_text(receiver, source).to_string(),
                    method,
                )
            });

        assert_eq!(
            rust,
            ruby_private_dotted_call_parts(source, language, suffix, kind, text),
            "dotted_call_parts mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn dotted_call_parts_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("user.name\n", Language::Ruby, ".rb"),
        ("user&.name\n", Language::Ruby, ".rb"),
        ("user.name()\n", Language::Python, ".py"),
        ("user.name();\n", Language::TypeScript, ".ts"),
        ("user.name()\n", Language::Lua, ".lua"),
    ] {
        let root = parse_language_source(source, language, suffix);
        if language != Language::Lua {
            let mut calls = Vec::new();
            nodes_of_type(&root, "CALL", &mut calls);
            let mut qcalls = Vec::new();
            nodes_of_type(&root, "QCALL", &mut qcalls);
            assert!(
                    calls
                        .iter()
                        .chain(qcalls.iter())
                        .any(|node| matches!(node.children.get(1), Some(Child::Symbol(method)) if method == "name")),
                    "expected dotted call method name for {language:?} in {root:#?}"
                );
        }
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn leading_if_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  if x\n    y\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "if x\n    y\n  end",
        ),
        (
            "def f():\n    if x:\n        y()\n",
            Language::Python,
            ".py",
            "block",
            "if x:\n        y()",
        ),
        (
            "function f()\n  if x then\n    y()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "if x then\n    y()\n  end",
        ),
        (
            "function f() { if (x) { y(); } }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (x) { y(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.leading_if_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "leading_if_statement?",
                kind,
                text
            ),
            "leading_if_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_leading_if_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  if x\n    y\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "if x\n    y\n  end",
        ),
        (
            "def f():\n    if x:\n        y()\n",
            Language::Python,
            ".py",
            "block",
            "if x:\n        y()",
        ),
        (
            "function f()\n  if x then\n    y()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "if x then\n    y()\n  end",
        ),
        (
            "function f() { if (x) { y(); } }\n",
            Language::TypeScript,
            ".ts",
            "if_statement",
            "if (x) { y(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_leading_if_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_leading_if_statement",
                kind,
                text
            ),
            "normalize_leading_if_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn leading_if_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def f\n  if x\n    y\n  end\nend\n", Language::Ruby, ".rb"),
        (
            "def f():\n    if x:\n        y()\n",
            Language::Python,
            ".py",
        ),
        (
            "function f()\n  if x then\n    y()\n  end\nend\n",
            Language::Lua,
            ".lua",
        ),
        (
            "function f() { if (x) { y(); } }\n",
            Language::TypeScript,
            ".ts",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut if_nodes = Vec::new();
        nodes_of_type(&root, "IF", &mut if_nodes);
        assert!(
            !if_nodes.is_empty(),
            "expected IF node for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn leading_case_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "case x\n  when 1 then y\n  else z\n  end",
        ),
        (
            "def f(x):\n    match x:\n        case 1:\n            y()\n",
            Language::Python,
            ".py",
            "block",
            "match x:\n        case 1:\n            y()",
        ),
        (
            "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (x) { case 1: y(); break; default: z(); }",
        ),
        (
            "function f(x)\n  if x == 1 then y() end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "if x == 1 then y() end",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.leading_case_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "leading_case_statement?",
                kind,
                text
            ),
            "leading_case_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_leading_case_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "case x\n  when 1 then y\n  else z\n  end",
        ),
        (
            "def f(x):\n    match x:\n        case 1:\n            y()\n",
            Language::Python,
            ".py",
            "block",
            "match x:\n        case 1:\n            y()",
        ),
        (
            "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
            Language::TypeScript,
            ".ts",
            "switch_statement",
            "switch (x) { case 1: y(); break; default: z(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_leading_case_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_leading_case_statement",
                kind,
                text
            ),
            "normalize_leading_case_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn leading_case_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        (
            "def f(x)\n  case x\n  when 1 then y\n  else z\n  end\nend\n",
            Language::Ruby,
            ".rb",
        ),
        (
            "def f(x):\n    match x:\n        case 1:\n            y()\n",
            Language::Python,
            ".py",
        ),
        (
            "function f(x) { switch (x) { case 1: y(); break; default: z(); } }\n",
            Language::TypeScript,
            ".ts",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut case_nodes = Vec::new();
        nodes_of_type(&root, "CASE", &mut case_nodes);
        assert!(
            !case_nodes.is_empty(),
            "expected CASE node for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn leading_loop_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(x)\n  while x\n    y\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "while x\n    y\n  end",
        ),
        (
            "def f(x):\n    while x:\n        y()\n",
            Language::Python,
            ".py",
            "block",
            "while x:\n        y()",
        ),
        (
            "function f(x)\n  while x do\n    y()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "while x do\n    y()\n  end",
        ),
        (
            "function f(x) { while (x) { y(); } }\n",
            Language::TypeScript,
            ".ts",
            "while_statement",
            "while (x) { y(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.leading_loop_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "leading_loop_statement?",
                kind,
                text
            ),
            "leading_loop_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_leading_loop_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f(x)\n  while x\n    y\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "while x\n    y\n  end",
        ),
        (
            "def f(x)\n  until x\n    y\n  end\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "until x\n    y\n  end",
        ),
        (
            "def f(x):\n    while x:\n        y()\n",
            Language::Python,
            ".py",
            "block",
            "while x:\n        y()",
        ),
        (
            "function f(x)\n  while x do\n    y()\n  end\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "while x do\n    y()\n  end",
        ),
        (
            "function f(x) { while (x) { y(); } }\n",
            Language::TypeScript,
            ".ts",
            "while_statement",
            "while (x) { y(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_leading_loop_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_leading_loop_statement",
                kind,
                text
            ),
            "normalize_leading_loop_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn leading_loop_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        (
            "def f(x)\n  while x\n    y\n  end\nend\n",
            Language::Ruby,
            ".rb",
        ),
        (
            "def f(x):\n    while x:\n        y()\n",
            Language::Python,
            ".py",
        ),
        (
            "function f(x)\n  while x do\n    y()\n  end\nend\n",
            Language::Lua,
            ".lua",
        ),
        (
            "function f(x) { while (x) { y(); } }\n",
            Language::TypeScript,
            ".ts",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut while_nodes = Vec::new();
        nodes_of_type(&root, "WHILE", &mut while_nodes);
        assert!(
            !while_nodes.is_empty(),
            "expected WHILE node for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn rescue_body_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  work\nrescue Error => e\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "work\nrescue Error => e\n  handle",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
            Language::Python,
            ".py",
            "try_statement",
            "try:\n    work()\nexcept Error as e:\n    handle(e)",
        ),
        (
            "try { work(); } catch (e) { handle(e); }\n",
            Language::TypeScript,
            ".ts",
            "try_statement",
            "try { work(); } catch (e) { handle(e); }",
        ),
        (
            "local ok, err = pcall(work)\n",
            Language::Lua,
            ".lua",
            "variable_declaration",
            "local ok, err = pcall(work)",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.rescue_body_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "rescue_body_statement?",
                kind,
                text
            ),
            "rescue_body_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_rescue_body_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  work\nrescue Error => e\n  handle\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "work\nrescue Error => e\n  handle",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
            Language::Python,
            ".py",
            "try_statement",
            "try:\n    work()\nexcept Error as e:\n    handle(e)",
        ),
        (
            "try { work(); } catch (e) { handle(e); }\n",
            Language::TypeScript,
            ".ts",
            "try_statement",
            "try { work(); } catch (e) { handle(e); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_rescue_body_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_rescue_body_statement",
                kind,
                text
            ),
            "normalize_rescue_body_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn rescue_body_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        (
            "def f\n  work\nrescue Error => e\n  handle\nend\n",
            Language::Ruby,
            ".rb",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle(e)\n",
            Language::Python,
            ".py",
        ),
        (
            "try { work(); } catch (e) { handle(e); }\n",
            Language::TypeScript,
            ".ts",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut rescue_nodes = Vec::new();
        nodes_of_type(&root, "RESCUE", &mut rescue_nodes);
        assert!(
            !rescue_nodes.is_empty(),
            "expected RESCUE node for {language:?} in {root:#?}"
        );
        let mut resbody_nodes = Vec::new();
        nodes_of_type(&root, "RESBODY", &mut resbody_nodes);
        assert!(
            !resbody_nodes.is_empty(),
            "expected RESBODY node for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn ensure_body_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  work\nensure\n  cleanup\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "work\nensure\n  cleanup",
        ),
        (
            "try:\n    work()\nfinally:\n    cleanup()\n",
            Language::Python,
            ".py",
            "try_statement",
            "try:\n    work()\nfinally:\n    cleanup()",
        ),
        (
            "try { work(); } finally { cleanup(); }\n",
            Language::TypeScript,
            ".ts",
            "try_statement",
            "try { work(); } finally { cleanup(); }",
        ),
        (
            "work()\ncleanup()\n",
            Language::Lua,
            ".lua",
            "function_call",
            "work()",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.ensure_body_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "ensure_body_statement?",
                kind,
                text
            ),
            "ensure_body_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn ensure_body_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        (
            "def f\n  work\nensure\n  cleanup\nend\n",
            Language::Ruby,
            ".rb",
        ),
        (
            "try:\n    work()\nfinally:\n    cleanup()\n",
            Language::Python,
            ".py",
        ),
        (
            "try { work(); } finally { cleanup(); }\n",
            Language::TypeScript,
            ".ts",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()\n",
            Language::Python,
            ".py",
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut ensure_nodes = Vec::new();
        nodes_of_type(&root, "ENSURE", &mut ensure_nodes);
        assert!(
            !ensure_nodes.is_empty(),
            "expected ENSURE node for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn normalize_ensure_body_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  work\nensure\n  cleanup\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "work\nensure\n  cleanup",
        ),
        (
            "try:\n    work()\nfinally:\n    cleanup()\n",
            Language::Python,
            ".py",
            "try_statement",
            "try:\n    work()\nfinally:\n    cleanup()",
        ),
        (
            "try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()\n",
            Language::Python,
            ".py",
            "try_statement",
            "try:\n    work()\nexcept Error as e:\n    handle(e)\nfinally:\n    cleanup()",
        ),
        (
            "try { work(); } finally { cleanup(); }\n",
            Language::TypeScript,
            ".ts",
            "try_statement",
            "try { work(); } finally { cleanup(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_ensure_body_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_ensure_body_statement",
                kind,
                text
            ),
            "normalize_ensure_body_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_ensure_clause_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "begin\n  work\nensure\n  cleanup\nend\n",
            "ensure",
            "ensure\n  cleanup",
        ),
        (
            "begin\n  work\nensure\n  user.name\nend\n",
            "ensure",
            "ensure\n  user.name",
        ),
        (
            "begin\n  work\nensure\n  user.name\n  cleanup\nend\n",
            "ensure",
            "ensure\n  user.name\n  cleanup",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_ensure_clause(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_ensure_clause",
                kind,
                text
            ),
            "normalize_ensure_clause mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn ruby_begin_ensure_clause_keeps_all_body_statements() {
    let source = "begin\n  work\nensure\n  user.name\n  cleanup\nend\n";
    let root = parse_language_source(source, Language::Ruby, ".rb");
    let ensure = first_node(&root, "ENSURE", "work\nensure\n  user.name\n  cleanup");
    let ensure_body = child_node(ensure, 1);

    assert_eq!(
        child_types(ensure_body),
        vec!["CALL", "VCALL"],
        "Ruby ensure clause body must retain all statements: {ensure:#?}"
    );
    assert_ruby_parity(source, Language::Ruby, ".rb");
}

#[test]
fn array_literal_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  [a, b]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "[a, b]",
        ),
        (
            "def f():\n    [a, b]\n",
            Language::Python,
            ".py",
            "block",
            "[a, b]",
        ),
        (
            "function f() { [a, b]; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "[a, b];",
        ),
        (
            "function f()\n  {a, b}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  {a, b}",
        ),
        (
            "function f()\n  {x = a, y = b}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  {x = a, y = b}",
        ),
        (
            "local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n",
            Language::Lua,
            ".lua",
            "arguments",
            "({rocks_tree, \"a_rock\"})",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.array_literal_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "array_literal_statement?",
                kind,
                text
            ),
            "array_literal_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn array_literal_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def f\n  [a, b]\nend\n", Language::Ruby, ".rb"),
        ("def f():\n    [a, b]\n", Language::Python, ".py"),
        ("function f() { [a, b]; }\n", Language::TypeScript, ".ts"),
        ("function f()\n  {a, b}\nend\n", Language::Lua, ".lua"),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut lists = Vec::new();
        nodes_of_type(&root, "LIST", &mut lists);
        assert!(
            lists
                .iter()
                .any(|node| node.text.contains('a') && node.text.contains('b')),
            "expected LIST for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn normalize_array_literal_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  [a, b]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "[a, b]",
        ),
        (
            "def f\n  []\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "[]",
        ),
        (
            "def f():\n    [a, b]\n",
            Language::Python,
            ".py",
            "block",
            "[a, b]",
        ),
        ("def f():\n    []\n", Language::Python, ".py", "block", "[]"),
        (
            "function f() { [a, b]; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "[a, b];",
        ),
        (
            "function f() { []; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "[];",
        ),
        (
            "function f()\n  {a, b}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  {a, b}",
        ),
        (
            "assert.same(install, { bin = { P\"bin/binfile\" } })\n",
            Language::Lua,
            ".lua",
            "arguments",
            "(install, { bin = { P\"bin/binfile\" } })",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_array_literal_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_array_literal_statement",
                kind,
                text
            ),
            "normalize_array_literal_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn element_reference_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  items[0]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items[0]",
        ),
        (
            "def f\n  [0]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "[0]",
        ),
        (
            "def f():\n    items[0]\n",
            Language::Python,
            ".py",
            "block",
            "items[0]",
        ),
        (
            "return items[0]\n",
            Language::Python,
            ".py",
            "subscript",
            "items[0]",
        ),
        (
            "function f() { items[0]; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "items[0];",
        ),
        (
            "return items[0];\n",
            Language::TypeScript,
            ".ts",
            "subscript_expression",
            "items[0]",
        ),
        (
            "return items[1]\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "items[1]",
        ),
        (
            "print(items[1])\n",
            Language::Lua,
            ".lua",
            "bracket_index_expression",
            "items[1]",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.element_reference_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "element_reference_statement?",
                kind,
                text
            ),
            "element_reference_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_element_reference_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  items[0]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items[0]",
        ),
        (
            "def f\n  self[0]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "self[0]",
        ),
        (
            "return items[0]\n",
            Language::Python,
            ".py",
            "subscript",
            "items[0]",
        ),
        (
            "return items[0];\n",
            Language::TypeScript,
            ".ts",
            "subscript_expression",
            "items[0]",
        ),
        (
            "print(items[1])\n",
            Language::Lua,
            ".lua",
            "bracket_index_expression",
            "items[1]",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_element_reference(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_element_reference",
                kind,
                text
            ),
            "normalize_element_reference mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_element_reference_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  items[0]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items[0]",
        ),
        (
            "def f\n  self[0]\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "self[0]",
        ),
        (
            "def f():\n    items[0]\n",
            Language::Python,
            ".py",
            "block",
            "items[0]",
        ),
        (
            "return items[0]\n",
            Language::Python,
            ".py",
            "subscript",
            "items[0]",
        ),
        (
            "function f() { items[0]; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "items[0];",
        ),
        (
            "return items[0];\n",
            Language::TypeScript,
            ".ts",
            "subscript_expression",
            "items[0]",
        ),
        (
            "return items[1]\n",
            Language::Lua,
            ".lua",
            "expression_list",
            "items[1]",
        ),
        (
            "print(items[1])\n",
            Language::Lua,
            ".lua",
            "bracket_index_expression",
            "items[1]",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_element_reference_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_element_reference_statement",
                kind,
                text
            ),
            "normalize_element_reference_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn element_reference_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def f\n  items[0]\nend\n", Language::Ruby, ".rb"),
        ("def f():\n    items[0]\n", Language::Python, ".py"),
        ("function f() { items[0]; }\n", Language::TypeScript, ".ts"),
        ("return items[1]\n", Language::Lua, ".lua"),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut calls = Vec::new();
        nodes_of_type(&root, "CALL", &mut calls);
        assert!(
            calls.iter().any(|node| {
                matches!(node.children.get(1), Some(Child::Symbol(message)) if message == "[]")
                    && node.text.contains("items")
            }),
            "expected element reference CALL for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn hash_literal_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  {a: b}\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "{a: b}",
        ),
        (
            "def f():\n    {\"a\": b}\n",
            Language::Python,
            ".py",
            "block",
            "{\"a\": b}",
        ),
        (
            "function f() { ({a: b}); }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "({a: b});",
        ),
        (
            "return {a: b};\n",
            Language::TypeScript,
            ".ts",
            "object",
            "{a: b}",
        ),
        (
            "function f()\n  {a = b}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  {a = b}",
        ),
        (
            "function f()\n  {a, b}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  {a, b}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.hash_literal_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "hash_literal_statement?",
                kind,
                text
            ),
            "hash_literal_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_hash_literal_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  {a: b}\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "{a: b}",
        ),
        (
            "def f():\n    {\"a\": b}\n",
            Language::Python,
            ".py",
            "block",
            "{\"a\": b}",
        ),
        (
            "function f() { ({a: b}); }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "({a: b});",
        ),
        (
            "return {a: b};\n",
            Language::TypeScript,
            ".ts",
            "object",
            "{a: b}",
        ),
        (
            "function f()\n  {a = b}\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  {a = b}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_hash_literal_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_hash_literal_statement",
                kind,
                text
            ),
            "normalize_hash_literal_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_pair_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  {a: b}\nend\n",
            Language::Ruby,
            ".rb",
            "pair",
            "a: b",
        ),
        (
            "def f\n  {name:}\nend\n",
            Language::Ruby,
            ".rb",
            "pair",
            "name:",
        ),
        (
            "def f\n  {\"a\" => b}\nend\n",
            Language::Ruby,
            ".rb",
            "pair",
            "\"a\" => b",
        ),
        (
            "def f():\n    {\"a\": b}\n",
            Language::Python,
            ".py",
            "pair",
            "\"a\": b",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_pair(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_pair",
                kind,
                text
            ),
            "normalize_pair mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn hash_literal_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def f\n  {a: b}\nend\n", Language::Ruby, ".rb"),
        ("def f():\n    {\"a\": b}\n", Language::Python, ".py"),
        ("function f() { ({a: b}); }\n", Language::TypeScript, ".ts"),
        ("function f()\n  {a = b}\nend\n", Language::Lua, ".lua"),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut hashes = Vec::new();
        nodes_of_type(&root, "HASH", &mut hashes);
        assert!(
            hashes
                .iter()
                .any(|node| node.text.contains('a') && node.text.contains('b')),
            "expected hash literal HASH for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn empty_body_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f():\n    pass\n",
            Language::Python,
            ".py",
            "block",
            "pass",
        ),
        (
            "function f() {}\n",
            Language::TypeScript,
            ".ts",
            "statement_block",
            "{}",
        ),
        (
            "function f() { work(); }\n",
            Language::TypeScript,
            ".ts",
            "statement_block",
            "{ work(); }",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.empty_body_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "empty_body_statement?",
                kind,
                text
            ),
            "empty_body_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn empty_body_statement_normalization_matches_ruby() {
    for (source, language, suffix) in [
        ("def f():\n    pass\n", Language::Python, ".py"),
        ("function f() {}\n", Language::TypeScript, ".ts"),
    ] {
        let root = parse_language_source(source, language, suffix);
        let mut defns = Vec::new();
        nodes_of_type(&root, "DEFN", &mut defns);
        let scope = child_node(defns[0], 1);
        assert!(
            matches!(scope.children.get(2), Some(Child::Nil)),
            "expected empty body for {language:?} in {root:#?}"
        );
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn heredoc_body_statement_matches_ruby_private_predicate() {
    let ruby_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
    for (source, language, suffix, kind, text) in [
        (
            ruby_source,
            Language::Ruby,
            ".rb",
            "body_statement",
            "puts <<~TXT\n    hi\n  TXT",
        ),
        (ruby_source, Language::Ruby, ".rb", "call", "puts <<~TXT"),
        (
            "def f():\n    value = 1\n",
            Language::Python,
            ".py",
            "block",
            "value = 1",
        ),
        (
            "function f() { value = 1; }\n",
            Language::TypeScript,
            ".ts",
            "statement_block",
            "{ value = 1; }",
        ),
        (
            "function f()\n  value = 1\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "value = 1",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.heredoc_body_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "heredoc_body_statement?",
                kind,
                text
            ),
            "heredoc_body_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn heredoc_call_for_body_matches_ruby_private_predicate() {
    let ruby_arg_source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
    let ruby_receiver_source = "def emit\n  <<~ZIG.chomp\n    hi\n  ZIG\nend\n";
    for (source, language, suffix, kind, text) in [
        (
            ruby_arg_source,
            Language::Ruby,
            ".rb",
            "body_statement",
            "puts <<~TXT\n    hi\n  TXT",
        ),
        (
            ruby_arg_source,
            Language::Ruby,
            ".rb",
            "call",
            "puts <<~TXT",
        ),
        (
            ruby_arg_source,
            Language::Ruby,
            ".rb",
            "argument_list",
            "<<~TXT",
        ),
        (
            ruby_arg_source,
            Language::Ruby,
            ".rb",
            "method",
            "def f\n  puts <<~TXT\n    hi\n  TXT\nend",
        ),
        (
            ruby_receiver_source,
            Language::Ruby,
            ".rb",
            "call",
            "<<~ZIG.chomp",
        ),
        (
            ruby_receiver_source,
            Language::Ruby,
            ".rb",
            "heredoc_beginning",
            "<<~ZIG",
        ),
        (
            "def f():\n    value = 1\n",
            Language::Python,
            ".py",
            "block",
            "value = 1",
        ),
        (
            "function f() { value = 1; }\n",
            Language::TypeScript,
            ".ts",
            "statement_block",
            "{ value = 1; }",
        ),
        (
            "function f()\n  value = 1\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "value = 1",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.heredoc_call_for_body(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "heredoc_call_for_body?",
                kind,
                text
            ),
            "heredoc_call_for_body? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn with_current_heredoc_body_restores_previous_body() {
    let source = "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n";
    let tree = raw_tree(source, Language::Ruby);
    let body = first_raw_node(tree.root_node(), source, "heredoc_body", "\n    hi\n  TXT");
    let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
    normalizer.current_heredoc_body_span = Some([9, 2, 9, 7]);

    let result = normalizer.with_current_heredoc_body(Some(body), |normalizer| {
        assert_eq!(
            normalizer.current_heredoc_body_span,
            Some(super::span(body))
        );
        "result"
    });

    assert_eq!(result, "result");
    assert_eq!(normalizer.current_heredoc_body_span, Some([9, 2, 9, 7]));
}

#[test]
fn normalize_interpolation_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "name = \"#{user}\"\n",
            Language::Ruby,
            ".rb",
            "interpolation",
            "#{user}",
        ),
        (
            "name = \"#{a; b}\"\n",
            Language::Ruby,
            ".rb",
            "interpolation",
            "#{a; b}",
        ),
        (
            "name = f\"hi {user}\"\n",
            Language::Python,
            ".py",
            "interpolation",
            "{user}",
        ),
        (
            "const name = `hi ${user}`;\n",
            Language::TypeScript,
            ".ts",
            "template_substitution",
            "${user}",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_interpolation(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_interpolation",
                kind,
                text
            ),
            "normalize_interpolation mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_heredoc_children_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n",
            "heredoc_body",
            "\n    hi\n  TXT",
        ),
        (
            "def f\n  puts <<~TXT\n    hi #{name}\n  TXT\nend\n",
            "heredoc_body",
            "\n    hi #{name}\n  TXT",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = children_value(&normalizer.normalize_heredoc_children(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_heredoc_children",
                kind,
                text
            ),
            "normalize_heredoc_children mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_heredoc_beginning_matches_ruby_private_method() {
    for (source, kind, text) in [(
        "def emit\n  <<~ZIG.chomp\n    hi\n  ZIG\nend\n",
        "heredoc_beginning",
        "<<~ZIG",
    )] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = node_value(&normalizer.normalize_heredoc_beginning(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_heredoc_beginning",
                kind,
                text
            ),
            "normalize_heredoc_beginning mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_heredoc_beginning_uses_current_body_for_multiple_heredocs() {
    let source = "def f\n  puts <<~A, <<~B\n    one\n  A\n    two\n  B\nend\n";
    let tree = raw_tree(source, Language::Ruby);
    let beginning = first_raw_node(tree.root_node(), source, "heredoc_beginning", "<<~B");
    let body = first_raw_node(tree.root_node(), source, "heredoc_body", "\n    two\n  B");
    let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);

    let dstr = normalizer.with_current_heredoc_body(Some(body), |normalizer| {
        normalizer.normalize_heredoc_beginning(beginning)
    });

    let content = child_node(&dstr, 0);
    assert_eq!(content.r#type, "STR");
    assert_eq!(
        content.children,
        vec![Child::String("\n    two\n  ".to_string())]
    );
}

#[test]
fn normalize_heredoc_body_statement_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def f\n  puts <<~TXT\n    hi\n  TXT\nend\n",
            "body_statement",
            "puts <<~TXT\n    hi\n  TXT",
        ),
        (
            "def emit\n  <<~ZIG.chomp\n    hi\n  ZIG\nend\n",
            "body_statement",
            "<<~ZIG.chomp\n    hi\n  ZIG",
        ),
        (
            "def f\n  puts <<~A, <<~B\n    one\n  A\n    two\n  B\nend\n",
            "body_statement",
            "puts <<~A, <<~B\n    one\n  A\n    two\n  B",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = normalizer
            .normalize_heredoc_body_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_heredoc_body_statement",
                kind,
                text
            ),
            "normalize_heredoc_body_statement mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn interpolated_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  \"hi #{name}\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"hi #{name}\"",
        ),
        (
            "def f():\n    f\"hi {name}\"\n",
            Language::Python,
            ".py",
            "block",
            "f\"hi {name}\"",
        ),
        (
            "function f() { `hi ${name}`; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "`hi ${name}`;",
        ),
        (
            "function f()\n  \"hi\"\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  \"hi\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.interpolated_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "interpolated_statement?",
                kind,
                text
            ),
            "interpolated_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn interpolated_statement_normalization_matches_ruby() {
    let source = "def f\n  \"hi #{name}\"\nend\n";
    let root = parse_language_source(source, Language::Ruby, ".rb");
    let dstr = first_node(&root, "DSTR", "\"hi #{name}\"");

    assert_eq!(child_types(dstr), vec!["STR", "EVSTR"]);
    assert_ruby_parity(source, Language::Ruby, ".rb");
}

#[test]
fn normalize_interpolated_statement_matches_ruby_private_method() {
    for (source, kind, text) in [
        (
            "def f\n  \"hi #{name}\"\nend\n",
            "body_statement",
            "\"hi #{name}\"",
        ),
        (
            "def f\n  \"#{first} #{last}\"\nend\n",
            "body_statement",
            "\"#{first} #{last}\"",
        ),
    ] {
        let tree = raw_tree(source, Language::Ruby);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, Language::Ruby);
        let rust = node_value(&normalizer.normalize_interpolated_statement(node));

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                Language::Ruby,
                ".rb",
                "normalize_interpolated_statement",
                kind,
                text
            ),
            "normalize_interpolated_statement mismatch for {kind} {text:?}"
        );
    }
}

#[test]
fn concatenated_string_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  \"a\" \"b\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b\"",
        ),
        (
            "def f():\n    \"a\" \"b\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" \"b\"",
        ),
        (
            "function f() { \"a\"; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "\"a\";",
        ),
        (
            "function f()\n  \"a\"\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  \"a\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.concatenated_string_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "concatenated_string_statement?",
                kind,
                text
            ),
            "concatenated_string_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn concatenated_string_statement_normalization_matches_ruby() {
    for (source, language, suffix, expected_text, expected_types) in [
        (
            "def f\n  \"a\" \"b\"\nend\n",
            Language::Ruby,
            ".rb",
            "\"a\"",
            vec!["STR", "STR"],
        ),
        (
            "def f\n  \"a\" \"b #{name}\"\nend\n",
            Language::Ruby,
            ".rb",
            "\"b #{name}\"",
            vec!["STR", "STR", "EVSTR"],
        ),
        (
            "def f():\n    \"a\" \"b\"\n",
            Language::Python,
            ".py",
            "\"a\"",
            vec!["STR", "STR"],
        ),
        (
            "def f():\n    \"a\" f\"b {name}\"\n",
            Language::Python,
            ".py",
            "f\"b {name}\"",
            vec!["STR", "STRING_START", "STR", "EVSTR", "STRING_END"],
        ),
    ] {
        let root = parse_language_source(source, language, suffix);
        let dstr = first_node(&root, "DSTR", expected_text);

        assert_eq!(child_types(dstr), expected_types);
        assert_ruby_parity(source, language, suffix);
    }
}

#[test]
fn normalize_concatenated_string_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  \"a\" \"b\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b\"",
        ),
        (
            "def f\n  \"a\" \"b #{name}\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b #{name}\"",
        ),
        (
            "def f():\n    \"a\" \"b\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" \"b\"",
        ),
        (
            "def f():\n    \"a\" f\"b {name}\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" f\"b {name}\"",
        ),
        (
            "function f() { \"a\"; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "\"a\";",
        ),
        (
            "function f()\n  \"a\"\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "\n  \"a\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.normalize_concatenated_string_statement(node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_concatenated_string_statement",
                kind,
                text
            ),
            "normalize_concatenated_string_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_chained_string_matches_ruby_private_method() {
    for (source, language, suffix, ruby_kind, ruby_text, rust_kind, rust_text) in [
        (
            "def f\n  \"a\" \"b\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b\"",
            "chained_string",
            "\"a\" \"b\"",
        ),
        (
            "def f\n  \"a\" \"b #{name}\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b #{name}\"",
            "chained_string",
            "\"a\" \"b #{name}\"",
        ),
        (
            "def f():\n    \"a\" \"b\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" \"b\"",
            "concatenated_string",
            "\"a\" \"b\"",
        ),
        (
            "def f():\n    \"a\" f\"b {name}\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" f\"b {name}\"",
            "concatenated_string",
            "\"a\" f\"b {name}\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, rust_kind, rust_text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer.normalize_chained_string(node);

        assert_eq!(
            node_value(&rust),
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_chained_string",
                ruby_kind,
                ruby_text
            ),
            "normalize_chained_string mismatch for {language:?} {rust_kind} {rust_text:?}"
        );
    }
}

#[test]
fn dynamic_string_source_matches_ruby_private_method() {
    for (source, language, suffix, ruby_kind, ruby_text, rust_kind, rust_text) in [
        (
            "def f\n  \"a\" \"b #{name}\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b #{name}\"",
            "chained_string",
            "\"a\" \"b #{name}\"",
        ),
        (
            "def f\n  \"a\" \"b\"\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "\"a\" \"b\"",
            "chained_string",
            "\"a\" \"b\"",
        ),
        (
            "def f():\n    \"a\" f\"b {name}\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" f\"b {name}\"",
            "concatenated_string",
            "\"a\" f\"b {name}\"",
        ),
        (
            "def f():\n    \"a\" \"b\"\n",
            Language::Python,
            ".py",
            "block",
            "\"a\" \"b\"",
            "concatenated_string",
            "\"a\" \"b\"",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, rust_kind, rust_text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let mut normalized_children = Vec::new();
        for child in normalizer.named_children(node) {
            let normalized = normalizer.normalize_node(child);
            normalized_children.push((child, normalized));
        }
        let rust = normalizer
            .dynamic_string_source(&normalized_children)
            .map(|node| {
                (
                    node.kind().to_string(),
                    super::node_text(node, source).to_string(),
                )
            });
        let ruby = ruby_private_dynamic_string_source_signature(
            source, language, suffix, ruby_kind, ruby_text,
        );

        assert_eq!(
            rust, ruby,
            "dynamic_string_source mismatch for {language:?} {rust_kind} {rust_text:?}"
        );
    }
}

#[test]
fn terminal_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  foo()\nend\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "()",
        ),
        (
            "def f\n  foo\n  foo()\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "foo\n  foo()",
        ),
        (
            "def f():\n    foo()\n",
            Language::Python,
            ".py",
            "argument_list",
            "()",
        ),
        (
            "def f():\n    foo\n",
            Language::Python,
            ".py",
            "block",
            "foo",
        ),
        (
            "function f() { foo(); }\n",
            Language::TypeScript,
            ".ts",
            "arguments",
            "()",
        ),
        (
            "function f()\n  foo()\nend\n",
            Language::Lua,
            ".lua",
            "arguments",
            "()",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.terminal_statement(node),
            ruby_private_predicate(source, language, suffix, "terminal_statement?", kind, text),
            "terminal_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_terminal_statement_matches_ruby_private_method() {
    let cases = vec![
        (
            "yield\n",
            Language::Ruby,
            ".rb",
            "yield",
            "yield",
            "yield",
            Vec::<&str>::new(),
        ),
        (
            "@name\n",
            Language::Ruby,
            ".rb",
            "instance_variable",
            "instance_variable",
            "@name",
            Vec::<&str>::new(),
        ),
        (
            "$1\n$value\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "global_variable",
            "$1",
            Vec::<&str>::new(),
        ),
        (
            "$1\n$value\n",
            Language::Ruby,
            ".rb",
            "global_variable",
            "global_variable",
            "$value",
            Vec::<&str>::new(),
        ),
        (
            "nil\ntrue\nfalse\n",
            Language::Ruby,
            ".rb",
            "nil",
            "nil",
            "nil",
            Vec::<&str>::new(),
        ),
        (
            "nil\ntrue\nfalse\n",
            Language::Ruby,
            ".rb",
            "true",
            "true",
            "true",
            Vec::<&str>::new(),
        ),
        (
            "nil\ntrue\nfalse\n",
            Language::Ruby,
            ".rb",
            "false",
            "false",
            "false",
            Vec::<&str>::new(),
        ),
        (
            ":ready\n",
            Language::Ruby,
            ".rb",
            "simple_symbol",
            "simple_symbol",
            ":ready",
            Vec::<&str>::new(),
        ),
        (
            "-123\n",
            Language::Ruby,
            ".rb",
            "unary",
            "unary",
            "-123",
            Vec::<&str>::new(),
        ),
        (
            "[]\n",
            Language::Ruby,
            ".rb",
            "array",
            "array",
            "[]",
            Vec::<&str>::new(),
        ),
        (
            "foo\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "foo\n",
            Language::Ruby,
            ".rb",
            "identifier",
            "identifier",
            "foo",
            vec!["foo"],
        ),
        (
            "foo\n",
            Language::Python,
            ".py",
            "expression_statement",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "foo;\n",
            Language::TypeScript,
            ".ts",
            "identifier",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "foo()\n",
            Language::Lua,
            ".lua",
            "identifier",
            "identifier",
            "foo",
            Vec::<&str>::new(),
        ),
        (
            "foo()\n",
            Language::Ruby,
            ".rb",
            "argument_list",
            "argument_list",
            "()",
            Vec::<&str>::new(),
        ),
    ];

    for (source, language, suffix, ruby_kind, rust_kind, text, locals) in cases {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, rust_kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        if !locals.is_empty() {
            normalizer
                .local_stack
                .push(locals.iter().map(|name| name.to_string()).collect());
        }
        let rust = node_value(&normalizer.normalize_terminal_statement(node));

        assert_eq!(
                rust,
                ruby_private_normalize_terminal_statement_value(
                    source,
                    language,
                    suffix,
                    ruby_kind,
                    text,
                    &locals,
                ),
                "normalize_terminal_statement mismatch for {language:?} ruby={ruby_kind} rust={rust_kind} {text:?} locals={locals:?}"
            );
    }
}

#[test]
fn operator_assignment_statement_parts_matches_ruby_private_method() {
    for (source, language, suffix, ruby_kind, ruby_text, rust_kind, rust_text) in [
        (
            "def f\n  x += 1\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x += 1",
            "operator_assignment",
            "x += 1",
        ),
        (
            "def f\n  x ||= y\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x ||= y",
            "operator_assignment",
            "x ||= y",
        ),
        (
            "def f\n  x += 1\n  y += 2\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x += 1\n  y += 2",
            "body_statement",
            "x += 1\n  y += 2",
        ),
        (
            "def f():\n    x += 1\n",
            Language::Python,
            ".py",
            "block",
            "x += 1",
            "augmented_assignment",
            "x += 1",
        ),
        (
            "function f() { obj.x ||= y; }\n",
            Language::TypeScript,
            ".ts",
            "augmented_assignment_expression",
            "obj.x ||= y",
            "augmented_assignment_expression",
            "obj.x ||= y",
        ),
        (
            "function f() { x += 1; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "x += 1;",
            "expression_statement",
            "x += 1;",
        ),
        (
            "function f()\n  x = x + 1\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "x = x + 1",
            "block",
            "x = x + 1",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, rust_kind, rust_text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust =
            normalizer
                .operator_assignment_statement_parts(node)
                .map(|(left, operator, right)| {
                    (
                        left.kind().to_string(),
                        super::node_text(left, source).to_string(),
                        operator,
                        right.kind().to_string(),
                        super::node_text(right, source).to_string(),
                    )
                });
        let ruby = ruby_private_operator_assignment_statement_parts_signature(
            source, language, suffix, ruby_kind, ruby_text,
        );

        assert_eq!(
                rust, ruby,
                "operator_assignment_statement_parts mismatch for {language:?} {rust_kind} {rust_text:?}"
            );
    }
}

#[test]
fn operator_assignment_statement_matches_ruby_private_predicate() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  x += 1\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x += 1",
        ),
        (
            "def f\n  x ||= y\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x ||= y",
        ),
        (
            "def f\n  x = 1\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x = 1",
        ),
        (
            "def f\n  x += 1\n  y += 2\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x += 1\n  y += 2",
        ),
        (
            "def f():\n    x += 1\n",
            Language::Python,
            ".py",
            "block",
            "x += 1",
        ),
        (
            "function f() { x += 1; }\n",
            Language::TypeScript,
            ".ts",
            "expression_statement",
            "x += 1;",
        ),
        (
            "function f()\n  x = x + 1\nend\n",
            Language::Lua,
            ".lua",
            "block",
            "x = x + 1",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let normalizer = super::TreeSitterNormalizer::new(source, language);

        assert_eq!(
            normalizer.operator_assignment_statement(node),
            ruby_private_predicate(
                source,
                language,
                suffix,
                "operator_assignment_statement?",
                kind,
                text
            ),
            "operator_assignment_statement? mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn normalize_operator_assignment_statement_matches_ruby_private_method() {
    for (source, language, suffix, kind, text) in [
        (
            "def f\n  x += 1\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x += 1",
        ),
        (
            "def f\n  x ||= y\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "x ||= y",
        ),
        (
            "def f\n  items[index] += value\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "items[index] += value",
        ),
        (
            "def f\n  object.value += 1\nend\n",
            Language::Ruby,
            ".rb",
            "body_statement",
            "object.value += 1",
        ),
        (
            "def f():\n    x += 1\n",
            Language::Python,
            ".py",
            "block",
            "x += 1",
        ),
        (
            "function f() { x += 1; }\n",
            Language::TypeScript,
            ".ts",
            "augmented_assignment_expression",
            "x += 1",
        ),
        (
            "function f() { obj.x ||= y; }\n",
            Language::TypeScript,
            ".ts",
            "augmented_assignment_expression",
            "obj.x ||= y",
        ),
    ] {
        let tree = raw_tree(source, language);
        let node = first_raw_node(tree.root_node(), source, kind, text);
        let mut normalizer = super::TreeSitterNormalizer::new(source, language);
        let rust = normalizer
            .normalize_operator_assignment_statement(node)
            .map(|node| node_value(&node))
            .unwrap_or(Value::Null);

        assert_eq!(
            rust,
            ruby_private_normalize_method_value(
                source,
                language,
                suffix,
                "normalize_operator_assignment_statement",
                kind,
                text
            ),
            "normalize_operator_assignment_statement mismatch for {language:?} {kind} {text:?}"
        );
    }
}

#[test]
fn python_f_string_interpolation_next_to_equals_is_evstr_not_assignment() {
    let root = parse_language_source(
        r#"
class Tag:
    @property
    def markup(self):
        return f"[{self.name}={self.parameters}]"
"#,
        Language::Python,
        ".py",
    );
    let dstr = first_node(&root, "DSTR", r#"f"[{self.name}={self.parameters}]""#);

    let types = child_types(dstr);
    assert_eq!(
        types,
        vec![
            "STRING_START",
            "STR",
            "EVSTR",
            "STR",
            "EVSTR",
            "STR",
            "STRING_END"
        ],
        "expected Ruby-style f-string interpolation parts in {dstr:#?}"
    );
    assert!(
        !types.contains(&"LASGN"),
        "interpolation next to '=' must not normalize as assignment: {dstr:#?}"
    );
}

#[test]
fn python_relative_import_prefix_only_has_no_children() {
    let root = parse_language_source(
        r#"
if __name__ == "__main__":
    from . import box as box
"#,
        Language::Python,
        ".py",
    );
    let relative_import = first_node(&root, "RELATIVE_IMPORT", ".");

    assert!(
            relative_import.children.is_empty(),
            "Ruby exposes bare relative import prefix as an empty RELATIVE_IMPORT: {relative_import:#?}"
        );
}

#[test]
fn python_annotation_type_wrappers_match_ruby_tree_shape() {
    let root = parse_language_source(
        r#"
from typing import Callable

_is_single_cell_widths: Callable[[str], bool] = value
last_measured_character: str | None = None
fileno: Callable[[], int] | None = value
"#,
        Language::Python,
        ".py",
    );

    let str_list_type = first_node(&root, "TYPE", "[str]");
    assert_eq!(child_types(str_list_type), vec!["LVAR"]);
    assert_eq!(
        child_node(str_list_type, 0).children,
        vec![Child::String("str".to_string())]
    );

    let empty_list_type = first_node(&root, "TYPE", "[]");
    assert!(
        empty_list_type.children.is_empty(),
        "Ruby keeps Callable[[]] list type empty: {empty_list_type:#?}"
    );

    let union_type = first_node(&root, "TYPE", "str | None");
    assert_eq!(child_types(union_type), vec!["LVAR", "NIL"]);
}

#[test]
fn python_docstring_only_class_body_stays_block_wrapped() {
    let root = parse_language_source(
        r#"
class ColorParseError(Exception):
    """The color could not be parsed."""
"#,
        Language::Python,
        ".py",
    );
    let class_node = first_node(
        &root,
        "CLASS",
        "class ColorParseError(Exception):\n    \"\"\"The color could not be parsed.\"\"\"",
    );
    let scope = child_node(class_node, 2);
    let body = child_node(scope, 2);

    assert_eq!(body.r#type, "BLOCK");
    assert_eq!(
        child_types(body),
        vec!["STRING_START", "STR", "STRING_END"],
        "Ruby exposes docstring-only class body as BLOCK of string parts: {body:#?}"
    );
}

#[test]
fn python_ellipsis_only_function_body_is_empty_scope_with_root_source() {
    assert_ruby_parity(
        r#"def __rich__():
    ...
"#,
        Language::Python,
        ".py",
    );
}

#[test]
fn python_explicit_return_none_is_not_elided_from_function_body() {
    let source = r#"
class Thing:
    def _repr_latex_(self):
        return None
"#;
    let root = parse_language_source(source, Language::Python, ".py");
    let defn = first_node(
        &root,
        "DEFN",
        "def _repr_latex_(self):\n        return None",
    );
    let scope = child_node(defn, 1);
    let body = child_node(scope, 2);

    assert_eq!(body.r#type, "RETURN");
    assert_eq!(
            child_node(body, 0).r#type,
            "NIL",
            "Ruby only elides implicit nil bodies for Ruby, not explicit Python return None: {scope:#?}"
        );
    assert_ruby_parity(source, Language::Python, ".py");
}

#[test]
fn python_with_attribute_item_uses_ruby_clause_children() {
    let root = parse_language_source(
        r#"
def page(self):
    with self._console._lock:
        buffer = self._console._buffer[:]
"#,
        Language::Python,
        ".py",
    );
    let clause = first_node(&root, "WITH_CLAUSE", "self._console._lock");

    assert_eq!(
        child_types(clause),
        vec!["CALL", "LVAR"],
        "Ruby with_clause exposes attribute receiver and field separately: {clause:#?}"
    );
    assert_eq!(child_node(clause, 0).text, "self._console");
    assert_eq!(child_node(clause, 1).text, "_lock");
}

#[test]
fn python_bare_identifier_expression_statement_has_no_children() {
    let root = parse_language_source(
        r#"
def _is_jupyter():
    try:
        get_ipython  # type: ignore[name-defined]
    except NameError:
        return False
"#,
        Language::Python,
        ".py",
    );
    let expression = first_node(&root, "EXPRESSION_STATEMENT", "get_ipython");

    assert!(
            expression.children.is_empty(),
            "Ruby parser exposes bare identifier expression statements without named children: {expression:#?}"
        );
}

#[test]
fn python_bare_identifier_only_block_has_no_children() {
    assert_ruby_parity(
        r#"
def get_exception():
    try:
        pass
    except:
        foobarbaz
"#,
        Language::Python,
        ".py",
    );
}

#[test]
fn python_bare_dotted_expression_statement_normalizes_as_call() {
    let root = parse_language_source("os.get_terminal_size\n", Language::Python, ".py");
    let call = first_node(&root, "CALL", "os.get_terminal_size");

    assert_eq!(
        child_types(call),
        vec!["LVAR"],
        "bare Python dotted expression statements should normalize as calls: {call:#?}"
    );
}

#[test]
fn python_bare_comparison_expression_statement_keeps_statement_wrapper() {
    let root = parse_language_source(
        r#"
def test_get_style():
    console.get_style("repr.brace") == Style(bold=True)
"#,
        Language::Python,
        ".py",
    );
    let expression = first_node(
        &root,
        "EXPRESSION_STATEMENT",
        r#"console.get_style("repr.brace") == Style(bold=True)"#,
    );

    assert_eq!(
            child_types(expression),
            vec!["CALL", "FCALL"],
            "Ruby exposes bare comparison statements as expression_statement operand children: {expression:#?}"
        );
}

#[test]
fn python_delete_statement_matches_ruby_block_contexts() {
    assert_ruby_parity(
        r#"
def save(self, clear):
    if clear:
        del self._record_buffer[:]
    with self._record_buffer_lock:
        del self._record_buffer[:]
        text = ""
"#,
        Language::Python,
        ".py",
    );
}

#[test]
fn python_single_subscript_expression_block_exposes_subscript_children() {
    assert_ruby_parity(
        r#"
def test_render():
    with pytest.raises(KeyError):
        top["asdasd"]
"#,
        Language::Python,
        ".py",
    );
}

#[test]
fn python_single_if_block_under_try_matches_ruby_if_shape() {
    let root = parse_language_source(
        r#"
def load(args):
    try:
        if args.path == "-":
            json_data = sys.stdin.read()
        else:
            json_data = Path(args.path).read_text()
    except Exception as error:
        sys.exit(-1)
"#,
        Language::Python,
        ".py",
    );
    let if_node = first_node(
            &root,
            "IF",
            "if args.path == \"-\":\n            json_data = sys.stdin.read()\n        else:\n            json_data = Path(args.path).read_text()",
        );

    assert_eq!(
        child_types(if_node),
        vec!["OPCALL", "LASGN", "ELSE_CLAUSE"],
        "Ruby normalizes this Python try-body child as an IF: {if_node:#?}"
    );
    assert_eq!(child_types(child_node(if_node, 2)), vec!["BLOCK"]);
}

#[test]
fn python_single_decorated_definition_block_exposes_decorator_and_function() {
    assert_ruby_parity(
        r#"
def test_inspect_swig_edge_case():
    class Thing:
        @property
        def __class__(self):
            raise AttributeError
"#,
        Language::Python,
        ".py",
    );
}

#[test]
fn python_nested_class_inside_class_body_matches_ruby_iter_shape() {
    let root = parse_language_source(
        r#"
def test_can_handle_special_characters_in_docstrings():
    class Something:
        class Thing:
            pass
"#,
        Language::Python,
        ".py",
    );
    let iter = first_node(&root, "ITER", "class Thing:\n            pass");

    assert_eq!(child_node(iter, 0).r#type, "VCALL");
    assert_eq!(
        child_node(iter, 0).children,
        vec![Child::Symbol("Thing".to_string()), Child::Nil]
    );
    assert_eq!(child_node(iter, 1).r#type, "SCOPE");
}

#[test]
fn lua_local_assignment_call_rhs_matches_ruby_expression_list_shape() {
    let root = parse_language_source(
        r#"local test_env = require("spec.util.test_env")
"#,
        Language::Lua,
        ".lua",
    );
    let expression_list = first_node(&root, "EXPRESSION_LIST", r#"require("spec.util.test_env")"#);

    assert_eq!(
            child_types(expression_list),
            vec!["LVAR", "ARGUMENTS"],
            "Ruby exposes a Lua call RHS expression_list as the call function and arguments, without a FUNCTION_CALL wrapper: {expression_list:#?}"
        );
}

#[test]
fn lua_local_assignment_member_rhs_matches_ruby_expression_list_shape() {
    let root = parse_language_source("local run = test_env.run\n", Language::Lua, ".lua");
    let expression_list = first_node(&root, "EXPRESSION_LIST", "test_env.run");

    assert_eq!(
            child_types(expression_list),
            vec!["LVAR", "LVAR"],
            "Ruby exposes a Lua dotted RHS expression_list as receiver and field, without a DOT_INDEX_EXPRESSION wrapper: {expression_list:#?}"
        );
}

#[test]
fn lua_table_string_entry_matches_ruby_field_shape() {
    let root = parse_language_source(
        "local extra_rocks = {\n   \"/luasocket-${LUASOCKET}.src.rock\",\n}\n",
        Language::Lua,
        ".lua",
    );
    let list = first_node(
        &root,
        "LIST",
        "{\n   \"/luasocket-${LUASOCKET}.src.rock\",\n}",
    );
    let string = child_node(list, 0);

    assert_eq!(
        child_types(list),
        vec!["STR"],
        "Ruby exposes a Lua positional table constructor assignment RHS as a LIST: {list:#?}"
    );
    assert_eq!(string.r#type, "STR");
    assert_eq!(
        string.children,
        vec![Child::String(
            "/luasocket-${LUASOCKET}.src.rock".to_string()
        )],
        "Ruby normalizes a Lua table string field from string_content, without quotes: {string:#?}"
    );
}

#[test]
fn lua_table_dollar_string_entry_matches_ruby_str_not_gvar() {
    let root = parse_language_source(
        "local incdirs = { \"$(FOO1_INCDIR)\" }\n",
        Language::Lua,
        ".lua",
    );
    let string = first_node(&root, "STR", "$(FOO1_INCDIR)");
    let mut gvars = Vec::new();
    nodes_of_type(&root, "GVAR", &mut gvars);

    assert_eq!(
        string.children,
        vec![Child::String("$(FOO1_INCDIR)".to_string())],
        "Ruby normalizes Lua table strings starting with $ as STR, not GVAR: {string:#?}"
    );
    assert!(
        gvars.is_empty(),
        "Lua string_content starting with $ must not normalize as GVAR: {gvars:#?}"
    );
}

#[test]
fn lua_table_call_entry_matches_ruby_field_children_shape() {
    assert_ruby_parity(
        "assert.same(install, { bin = { P\"bin/binfile\" } })\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_table_identifier_entry_matches_ruby_empty_field_shape() {
    assert_ruby_parity(
        "local rocks_path = table.concat({rocks_tree, \"a_rock\"})\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_single_call_function_body_matches_ruby_block_shape() {
    assert_ruby_parity(
        "before_each(function()\n   test_env.setup_specs(extra_rocks)\nend)\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_single_assignment_function_body_matches_ruby_lasgn_shape() {
    assert_ruby_parity(
        "lazy_setup(function()\n   git = git_repo.start()\nend)\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_single_bare_assignment_function_body_matches_ruby_lasgn_shape() {
    let root = parse_language_source("function()\n   x = y\nend\n", Language::Lua, ".lua");
    let defn = first_node(&root, "DEFN", "function()\n   x = y\nend");
    let scope = child_node(defn, 1);
    let body = child_node(scope, 2);
    let right = child_node(body, 1);

    assert_eq!(body.r#type, "LASGN");
    assert_eq!(body.children.first(), Some(&Child::String("x".to_string())));
    assert_eq!(right.r#type, "LVAR");
    assert!(
        right.children == vec![Child::String("y".to_string())],
        "Ruby exposes a bare identifier Lua single-assignment RHS as an LVAR: {right:#?}"
    );
}

#[test]
fn lua_single_dotted_assignment_function_body_normalizes_as_attribute_assignment() {
    let root = parse_language_source(
        "function()\n   package.path = oldpath\nend\n",
        Language::Lua,
        ".lua",
    );
    let defn = first_node(&root, "DEFN", "function()\n   package.path = oldpath\nend");
    let scope = child_node(defn, 1);
    let body = child_node(scope, 2);
    let assignment = body;
    let receiver = child_node(assignment, 0);
    let args = child_node(assignment, 2);

    assert_eq!(body.r#type, "ATTRASGN");
    assert_eq!(receiver.r#type, "LVAR");
    assert_eq!(
        receiver.children,
        vec![Child::String("package".to_string())]
    );
    assert_eq!(
        assignment.children.get(1),
        Some(&Child::Symbol("path=".to_string()))
    );
    assert_eq!(args.r#type, "LIST");
}

#[test]
fn lua_single_local_assignment_function_body_matches_ruby_lasgn_shape() {
    assert_ruby_parity(
        "it(function()\n   local output = run.luarocks(\"show --rock-tree luacov\")\nend)\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_assigned_function_expression_matches_ruby_expression_list_shape() {
    assert_ruby_parity(
        "local test_with_location = function(location)\n   lfs.mkdir(location)\nend\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_assigned_function_if_else_matches_fixed_ruby_if_shape() {
    assert_ruby_parity(
            "local make_unreadable = function(path)\n  if is_win then\n    fs.execute(\"x\")\n  else\n    fs.execute(\"y\")\n  end\nend\n",
            Language::Lua,
            ".lua",
        );
}

#[test]
fn lua_single_return_function_body_matches_ruby_opcall_shape() {
    let source = "function sum.sum(a, b)\n   return a + b\nend\n";
    let root = parse_language_source(source, Language::Lua, ".lua");
    let defn = first_node(
        &root,
        "DEFN",
        "function sum.sum(a, b)\n   return a + b\nend",
    );
    let scope = child_node(defn, 1);
    let body = child_node(scope, 2);
    let returned = child_node(body, 0);

    assert_eq!(body.r#type, "RETURN");
    assert_eq!(returned.r#type, "OPCALL");
    assert_eq!(
            returned.children.get(1),
            Some(&Child::Symbol("+".to_string())),
            "Ruby exposes a single Lua return body as RETURN wrapping the returned operator call: {body:#?}"
        );
    assert_ruby_parity(source, Language::Lua, ".lua");
}

#[test]
fn lua_top_level_return_identifier_matches_ruby_lvar() {
    let root = parse_language_source("return sum\n", Language::Lua, ".lua");
    let return_node = first_node(&root, "RETURN", "return sum");
    let value = child_node(return_node, 0);

    assert_eq!(value.r#type, "LVAR");
    assert!(
        value.children == vec![Child::String("sum".to_string())],
        "Ruby exposes a Lua return of a bare identifier as an LVAR: {value:#?}"
    );
}

#[test]
fn lua_top_level_return_scalar_literals_match_ruby_empty_expression_list() {
    for literal in ["true", "false", "nil", "0"] {
        let root = parse_language_source(&format!("return {literal}\n"), Language::Lua, ".lua");
        let return_node = first_node(&root, "RETURN", &format!("return {literal}"));
        let expression_list = child_node(return_node, 0);

        assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
        assert!(
                expression_list.children.is_empty(),
                "Ruby exposes a Lua return of {literal} as an empty expression_list: {expression_list:#?}"
            );
    }
}

#[test]
fn lua_assignment_scalar_literals_match_ruby_empty_expression_list() {
    for literal in ["true", "false", "nil", "0"] {
        let root = parse_language_source(&format!("tmpfile = {literal}\n"), Language::Lua, ".lua");
        let assignment = first_node(&root, "LASGN", &format!("tmpfile = {literal}"));
        let expression_list = child_node(assignment, 1);

        assert_eq!(expression_list.r#type, "EXPRESSION_LIST");
        assert!(
                expression_list.children.is_empty(),
                "Ruby exposes a Lua scalar literal assignment RHS as an empty expression_list: {expression_list:#?}"
            );
    }
}

#[test]
fn lua_no_paren_string_argument_matches_ruby_string_content_shape() {
    let root = parse_language_source("V\"foo\"\n", Language::Lua, ".lua");
    let call = first_node(&root, "FUNCTION_CALL", "V\"foo\"");
    let arguments = child_node(call, 1);
    let string = child_node(arguments, 0);

    assert_eq!(arguments.r#type, "ARGUMENTS");
    assert_eq!(arguments.text, "\"foo\"");
    assert_eq!(string.r#type, "STR");
    assert_eq!(string.text, "foo");
    assert_eq!(string.children, vec![Child::String("foo".to_string())]);
}

#[test]
fn lua_long_string_assignment_matches_ruby_expression_list_content_shape() {
    assert_ruby_parity(
        "local c_module_source = [[\n   #include <lua.h>\n]]\n",
        Language::Lua,
        ".lua",
    );
}

#[test]
fn lua_elseif_branch_is_preserved_as_if_alternative() {
    let root = parse_language_source(
        r#"if test_env.LUA_V == "5.1" then
  one()
elseif test_env.LUA_V == "5.2" then
  two()
end
"#,
        Language::Lua,
        ".lua",
    );
    let if_node = first_node(
            &root,
            "IF",
            "if test_env.LUA_V == \"5.1\" then\n  one()\nelseif test_env.LUA_V == \"5.2\" then\n  two()\nend",
    );
    let alternative = child_node(if_node, 2);

    assert_eq!(alternative.r#type, "IF");
}

#[test]
fn lua_binary_assignment_rhs_matches_ruby_expression_list_shape() {
    let root = parse_language_source(
        "local rockspec = testing_paths.fixtures_dir .. \"/build_only_deps-0.1-1.rockspec\"\n",
        Language::Lua,
        ".lua",
    );
    let expression_list = first_node(
        &root,
        "EXPRESSION_LIST",
        "testing_paths.fixtures_dir .. \"/build_only_deps-0.1-1.rockspec\"",
    );

    assert_eq!(
            child_types(expression_list),
            vec!["DOT_INDEX_EXPRESSION", "STR"],
            "Ruby exposes a Lua binary RHS expression_list as the binary operands, without a BINARY_EXPRESSION wrapper: {expression_list:#?}"
        );
}

#[test]
fn lua_local_declaration_without_rhs_matches_ruby_empty_variable_list() {
    let root = parse_language_source("local tmpdir\n", Language::Lua, ".lua");
    let variable_list = first_node(&root, "VARIABLE_LIST", "tmpdir");

    assert!(
            variable_list.children.is_empty(),
            "Ruby exposes a Lua local declaration without RHS as an empty VARIABLE_LIST: {variable_list:#?}"
        );
}

#[test]
fn lua_multi_local_declaration_without_rhs_keeps_ruby_variable_list_children() {
    let root = parse_language_source("local cfg, fs\n", Language::Lua, ".lua");
    let variable_list = first_node(&root, "VARIABLE_LIST", "cfg, fs");

    assert_eq!(
            child_types(variable_list),
            vec!["LVAR", "LVAR"],
            "Ruby keeps children for a multi-name Lua local declaration without RHS: {variable_list:#?}"
        );
}

#[test]
fn lua_single_generic_for_variable_matches_ruby_empty_variable_list() {
    let root = parse_language_source(
        "for f in lfs.dir(spec_quick) do end\n",
        Language::Lua,
        ".lua",
    );
    let variable_list = first_node(&root, "VARIABLE_LIST", "f");

    assert!(
        variable_list.children.is_empty(),
        "Ruby exposes a single Lua generic-for variable list as empty: {variable_list:#?}"
    );
}

#[test]
fn lua_multi_generic_for_variable_list_keeps_ruby_children() {
    let root = parse_language_source("for _, t in ipairs(tests) do end\n", Language::Lua, ".lua");
    let variable_list = first_node(&root, "VARIABLE_LIST", "_, t");

    assert_eq!(
        child_types(variable_list),
        vec!["LVAR", "LVAR"],
        "Ruby keeps children for a multi-name Lua generic-for variable list: {variable_list:#?}"
    );
}

#[test]
fn normalizes_safe_navigation_inside_multi_statement_else_body() {
    let root = parse_source(
        r#"
def x(cond, node)
  if cond
    node.storage = :stack
  else
    node.storage = :heap
    current_fn_ctx&.record_heap_use!
  end
end
"#,
    );
    let mut qcalls = Vec::new();
    nodes_of_type(&root, "QCALL", &mut qcalls);

    assert!(
            qcalls
                .iter()
                .any(|node| node.text == "current_fn_ctx&.record_heap_use!"),
            "expected normalized QCALL for current_fn_ctx safe navigation, got {qcalls:#?} in {root:#?}"
        );
}

#[test]
fn normalizes_visibility_wrapped_singleton_def() {
    let root = parse_source(
        r#"
private_class_method def self.collect_payload_binding_names(node, names)
  if node.is_a?(AST::Identifier)
    return
  end
  AST.wrapped_children(node).each { |child| collect_payload_binding_names(child, names) if child.is_a?(AST::Locatable) }
end
"#,
    );
    let mut defs = Vec::new();
    nodes_of_type(&root, "DEFS", &mut defs);

    assert!(
        defs.iter().any(|node| node.children.get(1)
            == Some(&Child::Symbol("collect_payload_binding_names".to_string()))),
        "expected normalized DEFS for visibility-wrapped singleton def, got {root:#?}"
    );

    let def = defs
        .into_iter()
        .find(|node| {
            node.children.get(1)
                == Some(&Child::Symbol("collect_payload_binding_names".to_string()))
        })
        .expect("visibility-wrapped singleton def should normalize to DEFS");
    let mut calls = Vec::new();
    nodes_of_type(def, "CALL", &mut calls);
    nodes_of_type(def, "FCALL", &mut calls);
    calls.sort_by_key(|node| (node.first_lineno, node.first_column));
    let ordered = calls
        .iter()
        .map(|node| (node.first_lineno, node.text.as_str()))
        .collect::<Vec<_>>();

    let first_if_call = ordered
        .iter()
        .position(|(_line, text)| *text == "node.is_a?(AST::Identifier)")
        .expect("expected identifier guard call");
    let recursive_call = ordered
        .iter()
        .position(|(_line, text)| *text == "collect_payload_binding_names(child, names)")
        .expect("expected recursive payload scan call");
    assert!(
        first_if_call < recursive_call,
        "expected method body calls in source order, got {ordered:#?} in {root:#?}"
    );
}

#[test]
fn normalizes_heredoc_beginning_as_dynamic_string_receiver() {
    let root = parse_source(
        r#"
def emit
  <<~ZIG.chomp
    hi
  ZIG
end
"#,
    );
    let mut calls = Vec::new();
    nodes_of_type(&root, "CALL", &mut calls);

    let call = calls
        .iter()
        .find(|node| node.text == "<<~ZIG.chomp")
        .expect("expected heredoc chomp call");
    assert_eq!(
        call.children.get(1),
        Some(&Child::Symbol("chomp".to_string()))
    );
    assert_eq!(
        call.children
            .first()
            .and_then(super::node)
            .map(|node| node.r#type.as_str()),
        Some("DSTR")
    );
}

#[test]
fn flatten_and_matches_ruby_ast_helper() {
    let left = Node {
        r#type: "LVAR".to_string(),
        children: vec![Child::String("a".to_string())],
        first_lineno: 1,
        first_column: 0,
        last_lineno: 1,
        last_column: 1,
        text: "a".to_string(),
    };
    let right = Node {
        r#type: "LVAR".to_string(),
        children: vec![Child::String("b".to_string())],
        first_lineno: 1,
        first_column: 5,
        last_lineno: 1,
        last_column: 6,
        text: "b".to_string(),
    };
    let and_node = Node {
        r#type: "AND".to_string(),
        children: vec![Child::Node(Box::new(left)), Child::Node(Box::new(right))],
        first_lineno: 1,
        first_column: 0,
        last_lineno: 1,
        last_column: 6,
        text: "a && b".to_string(),
    };

    assert_eq!(super::flatten_and(&and_node).len(), 2);
}
