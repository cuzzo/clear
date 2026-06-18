fn call_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    match node.kind() {
        "element_reference" => Some("[]".to_string()),
        "operator_assignment" if operator_assignment_index_read_node(node, file) => Some("[]".to_string()),
        "assignment" | "operator_assignment" if assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference") => {
            Some("[]=".to_string())
        }
        "assignment" | "operator_assignment" if assignment_lhs(node).is_some_and(|lhs| normalized_kind(lhs, file) == NormKind::Call) => {
            assignment_lhs(node)
                .and_then(|lhs| call_name(lhs, file))
                .map(|name| format!("{name}="))
        }
        "binary" => all_children(node)
            .into_iter()
            .find(|child| !child.is_named() && !matches!(node_text_raw(*child).as_str(), "(" | ")"))
            .map(node_text_raw),
        "unary" => all_children(node)
            .into_iter()
            .find(|child| !child.is_named())
            .map(node_text_raw),
        "identifier" => Some(node_text(node, file)),
        "return" => Some("return".to_string()),
        "call" | "command" | "method_call" | "body_statement" | "block_body" | "then" => node
            .child_by_field_name("method")
            .or_else(|| method_after_dot(node))
            .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "identifier"))
            .map(|child| node_text(child, file))
            .or_else(|| {
                let text = node_text(node, file);
                identifier_like(&text).then_some(text)
            }),
        _ => None,
    }
}

fn call_receiver<'tree>(node: Node<'tree>, _file: &SourceFile) -> Option<Node<'tree>> {
    match node.kind() {
        "element_reference" => node.child_by_field_name("object").or_else(|| named_children(node).first().copied()),
        "assignment" | "operator_assignment" => assignment_lhs(node).and_then(|lhs| {
            lhs.child_by_field_name("object")
                .or_else(|| named_children(lhs).first().copied())
        }),
        "binary" => named_children(node).first().copied(),
        "unary" | "identifier" => None,
        _ => node.child_by_field_name("receiver").or_else(|| receiver_before_dot(node)),
    }
}

fn call_arguments<'tree>(node: Node<'tree>, file: &SourceFile) -> Vec<Node<'tree>> {
    match node.kind() {
        "element_reference" => named_children(node).into_iter().skip(1).collect(),
        "unary" if unary_arithmetic_node(node) => Vec::new(),
        "operator_assignment" if operator_assignment_index_read_node(node, file) => assignment_lhs(node)
            .map(|lhs| named_children(lhs).into_iter().skip(1).collect())
            .unwrap_or_default(),
        "assignment" | "operator_assignment" if assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference") => {
            let mut out = assignment_lhs(node)
                .map(|lhs| named_children(lhs).into_iter().skip(1).collect::<Vec<_>>())
                .unwrap_or_default();
            if let Some(value) = write_value(node) {
                out.push(value);
            }
            out
        }
        "assignment" | "operator_assignment" if assignment_lhs(node).is_some_and(|lhs| normalized_kind(lhs, file) == NormKind::Call) => {
            write_value(node).into_iter().collect()
        }
        "binary" => named_children(node).into_iter().skip(1).take(1).collect(),
        "return" => raw_return_args(node),
        _ => {
            if let Some(args) = node
                .child_by_field_name("arguments")
                .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "argument_list"))
            {
                return named_children(args);
            }
            named_children(node)
                .into_iter()
                .filter(|child| {
                    !matches!(
                        child.kind(),
                        "identifier" | "block" | "do_block" | "method_parameters" | "body_statement"
                    ) && Some(*child) != call_receiver(node, file)
                })
                .collect()
        }
    }
}

fn call_block(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("block").or_else(|| {
        named_children(node)
            .into_iter()
            .find(|child| matches!(child.kind(), "block" | "do_block"))
    })
}

fn block_param_names(block: Node<'_>, file: &SourceFile) -> Vec<String> {
    let Some(params) = block.child_by_field_name("parameters").or_else(|| {
        named_children(block)
            .into_iter()
            .find(|child| child.kind() == "block_parameters")
    }) else {
        return Vec::new();
    };
    named_children(params)
        .into_iter()
        .filter_map(|param| parameter_name(param, file))
        .collect()
}

fn raw_return_args(node: Node<'_>) -> Vec<Node<'_>> {
    let children = named_children(node);
    if children.len() == 1 && children[0].kind() == "argument_list" {
        named_children(children[0])
    } else {
        children
    }
}

fn receiver_before_dot(node: Node<'_>) -> Option<Node<'_>> {
    let children = all_children(node);
    let idx = children
        .iter()
        .position(|child| !child.is_named() && matches!(node_text_raw(*child).as_str(), "." | "&."))?;
    children[..idx].iter().rev().find(|child| child.is_named()).copied()
}

fn method_after_dot(node: Node<'_>) -> Option<Node<'_>> {
    let children = all_children(node);
    let idx = children
        .iter()
        .position(|child| !child.is_named() && matches!(node_text_raw(*child).as_str(), "." | "&."))?;
    children[idx + 1..]
        .iter()
        .find(|child| child.is_named() && child.kind() == "identifier")
        .copied()
}

fn safe_navigation(node: Node<'_>) -> bool {
    all_children(node)
        .iter()
        .any(|child| !child.is_named() && node_text_raw(*child) == "&.")
}

fn assignment_lhs(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("left").or_else(|| named_children(node).first().copied())
}

fn write_value(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("right")
        .or_else(|| node.child_by_field_name("value"))
        .or_else(|| named_children(node).get(1).copied())
}

fn write_name(node: Node<'_>, file: &SourceFile) -> Option<String> {
    assignment_lhs(node).map(|target| node_text(target, file))
}

fn hidden_or_body_statement(node: Node<'_>) -> bool {
    let _ = node;
    false
}

fn condition_node(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("condition")
        .or_else(|| named_children(node).first().copied())
}

fn consequent_node(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("consequence")
        .or_else(|| node.child_by_field_name("body"))
        .or_else(|| {
            named_children(node)
                .into_iter()
                .find(|child| matches!(child.kind(), "then" | "body_statement" | "block_body"))
        })
}

fn alternative_node(node: Node<'_>) -> Option<Node<'_>> {
    node.child_by_field_name("alternative")
        .or_else(|| node.child_by_field_name("else"))
        .or_else(|| named_children(node).into_iter().find(|child| child.kind() == "else"))
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
enum NormKind {
    Program,
    Statements,
    Class,
    Module,
    Def,
    Parameters,
    Block,
    Call,
    Array,
    Hash,
    KeywordHash,
    Pair,
    String,
    InterpolatedString,
    Symbol,
    Integer,
    Float,
    True,
    False,
    Nil,
    Range,
    Return,
    Yield,
    If,
    Unless,
    While,
    Until,
    Case,
    When,
    Else,
    Begin,
    Rescue,
    Parentheses,
    SelfNode,
    ConstRead,
    ConstPath,
    ConstWrite,
    LocalRead,
    LocalWrite,
    IvarRead,
    IvarWrite,
    ClassVarRead,
    ClassVarWrite,
    GlobalVarRead,
    GlobalVarWrite,
    Or,
    HiddenOr,
    Other,
}

fn normalized_kind(node: Node<'_>, file: &SourceFile) -> NormKind {
    match node.kind() {
        "program" => NormKind::Program,
        "body_statement" | "block_body" | "then" => body_statement_kind(node, file),
        "class" => NormKind::Class,
        "module" => NormKind::Module,
        "method" | "singleton_method" => NormKind::Def,
        "method_parameters" => NormKind::Parameters,
        "block" | "do_block" => NormKind::Block,
        "assignment" | "operator_assignment" => assignment_kind(node),
        "call" | "command" | "method_call" => NormKind::Call,
        "element_reference" | "binary" | "unary" => {
            if node.kind() == "binary" && binary_operator(node).is_some_and(|op| matches!(op.as_str(), "||" | "or")) {
                NormKind::Or
            } else if node.kind() == "binary" && binary_operator(node).is_some_and(|op| matches!(op.as_str(), "&&" | "and")) {
                NormKind::Other
            } else {
                NormKind::Call
            }
        }
        "array" => NormKind::Array,
        "hash" => NormKind::Hash,
        "pair" => NormKind::Pair,
        "argument_list" if looks_like_keyword_hash(node) => NormKind::KeywordHash,
        "string" => {
            if named_children(node).iter().any(|child| child.kind() == "interpolation") {
                NormKind::InterpolatedString
            } else {
                NormKind::String
            }
        }
        "chained_string" => NormKind::Other,
        "bare_string" => NormKind::String,
        "simple_symbol" | "hash_key_symbol" | "symbol" => NormKind::Symbol,
        "integer" => NormKind::Integer,
        "float" => NormKind::Float,
        "true" => NormKind::True,
        "false" => NormKind::False,
        "nil" => NormKind::Nil,
        "range" => NormKind::Range,
        "return" => NormKind::Return,
        "yield" => NormKind::Yield,
        "if" => NormKind::If,
        "unless" => NormKind::Unless,
        "while" => NormKind::While,
        "until" => NormKind::Until,
        "case" => NormKind::Case,
        "when" => NormKind::When,
        "else" => NormKind::Else,
        "begin" => NormKind::Begin,
        "rescue" | "rescue_modifier" => NormKind::Rescue,
        "parenthesized_statements" | "parenthesized_expression" => NormKind::Parentheses,
        "self" => NormKind::SelfNode,
        "constant" => NormKind::ConstRead,
        "scope_resolution" => NormKind::ConstPath,
        "instance_variable" => {
            if assignment_lhs_node(node) {
                NormKind::IvarWrite
            } else {
                NormKind::IvarRead
            }
        }
        "class_variable" => {
            if assignment_lhs_node(node) {
                NormKind::ClassVarWrite
            } else {
                NormKind::ClassVarRead
            }
        }
        "global_variable" => {
            if assignment_lhs_node(node) {
                NormKind::GlobalVarWrite
            } else {
                NormKind::GlobalVarRead
            }
        }
        "identifier" => {
            if identifier_is_local(node, file) {
                NormKind::LocalRead
            } else {
                NormKind::Call
            }
        }
        _ => NormKind::Other,
    }
}

fn normalized_kind_by_raw(node: Node<'_>) -> NormKind {
    match node.kind() {
        "return" => NormKind::Return,
        _ => NormKind::Other,
    }
}

fn body_statement_kind(node: Node<'_>, _file: &SourceFile) -> NormKind {
    if hidden_or_body_statement(node) {
        return NormKind::HiddenOr;
    }
    let first = all_children(node).first().copied();
    match first.map(|child| child.kind()) {
        Some("def") => NormKind::Def,
        Some("class") => NormKind::Class,
        Some("module") => NormKind::Module,
        Some("return") => NormKind::Return,
        Some("if") => NormKind::If,
        Some("unless") => NormKind::Unless,
        Some("while") => NormKind::While,
        Some("until") => NormKind::Until,
        Some("case") => NormKind::Case,
        Some("begin") => NormKind::Begin,
        _ => {
            NormKind::Statements
        }
    }
}

fn assignment_kind(node: Node<'_>) -> NormKind {
    let lhs = assignment_lhs(node);
    match lhs.map(|lhs| lhs.kind()) {
        Some("element_reference") | Some("call") => NormKind::Call,
        Some("identifier") => NormKind::LocalWrite,
        Some("instance_variable") => NormKind::IvarWrite,
        Some("class_variable") => NormKind::ClassVarWrite,
        Some("global_variable") => NormKind::GlobalVarWrite,
        Some("constant") | Some("scope_resolution") => NormKind::ConstWrite,
        _ => NormKind::Other,
    }
}

fn assignment_lhs_node(node: Node<'_>) -> bool {
    matches!(
        next_sibling_raw_text(node).as_deref(),
        Some("=" | "+=" | "-=" | "*=" | "/=" | "%=" | "&&=" | "||=")
    )
}

fn identifier_is_local(node: Node<'_>, file: &SourceFile) -> bool {
    let Some(parent) = node.parent() else {
        return false;
    };
    if parent.child_by_field_name("name") == Some(node) {
        return false;
    }
    let text = node_text(node, file);
    let mut scope = Some(parent);
    while let Some(current) = scope {
        if matches!(
            current.kind(),
            "method" | "singleton_method" | "block" | "do_block" | "lambda" | "program"
        ) && file
            .local_names_by_scope
            .get(&scope_key(current))
            .is_some_and(|names| names.contains(&text))
        {
            return true;
        }
        scope = current.parent();
    }
    false
}

fn build_local_name_cache(file: &SourceFile) -> BTreeMap<ScopeKey, BTreeSet<String>> {
    let mut names_by_scope = BTreeMap::new();
    collect_local_name_cache(file.root_node(), file, &mut names_by_scope);
    names_by_scope
}

fn collect_local_name_cache(
    node: Node<'_>,
    file: &SourceFile,
    names_by_scope: &mut BTreeMap<ScopeKey, BTreeSet<String>>,
) {
    if matches!(
        node.kind(),
        "method" | "singleton_method" | "block" | "do_block" | "lambda" | "program"
    ) {
        let mut names = BTreeSet::new();
        collect_scope_parameters(node, file, &mut names);
        collect_scope_assignments(node, file, &mut names);
        names_by_scope.insert(scope_key(node), names);
    }

    for child in named_children(node) {
        collect_local_name_cache(child, file, names_by_scope);
    }
}

fn collect_scope_parameters(scope: Node<'_>, file: &SourceFile, names: &mut BTreeSet<String>) {
    if matches!(scope.kind(), "method" | "singleton_method" | "block" | "do_block" | "lambda") {
        if let Some(params) = scope.child_by_field_name("parameters") {
            for param in named_children(params).into_iter().filter_map(|param| {
                param
                    .child_by_field_name("name")
                    .or_else(|| named_children(param).into_iter().find(|child| child.kind() == "identifier"))
                    .or_else(|| (param.kind() == "identifier").then_some(param))
            }) {
                names.insert(node_text(param, file));
            }
        }
    }
}

fn collect_scope_assignments(scope: Node<'_>, file: &SourceFile, names: &mut BTreeSet<String>) {
    walk_raw(scope, &mut |node| {
        if node != scope && matches!(node.kind(), "method" | "singleton_method" | "class" | "module") {
            return;
        }
        if matches!(node.kind(), "assignment" | "operator_assignment") {
            if let Some(lhs) = assignment_lhs(node).filter(|lhs| lhs.kind() == "identifier") {
                names.insert(node_text(lhs, file));
            }
        }
        if node.kind() == "rescue" {
            for child in named_children(node) {
                if matches!(child.kind(), "body_statement" | "block_body" | "then") {
                    continue;
                }
                collect_identifier_names(child, file, names);
            }
        }
    });
}

fn collect_identifier_names(node: Node<'_>, file: &SourceFile, names: &mut BTreeSet<String>) {
    if node.kind() == "identifier" {
        names.insert(node_text(node, file));
    }
    for child in named_children(node) {
        collect_identifier_names(child, file, names);
    }
}

fn scope_key(node: Node<'_>) -> ScopeKey {
    (node.start_byte(), node.end_byte())
}

fn walk_key(node: Node<'_>) -> WalkKey {
    (node.start_byte(), node.end_byte(), node.kind().to_string())
}

fn lhs_element_reference_node(node: Node<'_>) -> bool {
    node.kind() == "element_reference"
        && node.parent().is_some_and(|parent| {
            matches!(parent.kind(), "assignment" | "operator_assignment")
                && assignment_lhs(parent) == Some(node)
        })
}

fn looks_like_keyword_hash(node: Node<'_>) -> bool {
    !named_children(node).is_empty()
        && named_children(node)
            .into_iter()
            .all(|child| child.kind() == "pair")
}

fn nested_scope_node(node: Node<'_>, file: &SourceFile) -> bool {
    matches!(
        normalized_kind(node, file),
        NormKind::Def | NormKind::Class | NormKind::Module
    )
}

fn nested_scope_kind(kind: &str) -> bool {
    matches!(kind, "method" | "singleton_method" | "class" | "module")
}

fn binary_operator(node: Node<'_>) -> Option<String> {
    all_children(node)
        .into_iter()
        .find(|child| !child.is_named() && !matches!(node_text_raw(*child).as_str(), "(" | ")"))
        .map(node_text_raw)
}

fn logical_and_node(node: Node<'_>) -> bool {
    node.kind() == "binary"
        && binary_operator(node).is_some_and(|op| matches!(op.as_str(), "&&" | "and"))
}

fn unary_bang_node(node: Node<'_>) -> bool {
    node.kind() == "unary"
        && all_children(node)
            .into_iter()
            .find(|child| !child.is_named())
            .map(node_text_raw)
            .as_deref() == Some("!")
}

fn unary_arithmetic_node(node: Node<'_>) -> bool {
    node.kind() == "unary"
        && all_children(node)
            .into_iter()
            .find(|child| !child.is_named())
            .map(node_text_raw)
            .is_some_and(|op| matches!(op.as_str(), "-" | "+"))
}

fn operator_assignment_index_read_node(node: Node<'_>, file: &SourceFile) -> bool {
    node.kind() == "operator_assignment"
        && node_text(node, file).contains("+=")
        && assignment_lhs(node).is_some_and(|lhs| lhs.kind() == "element_reference")
        && write_value(node).is_some_and(|value| normalized_kind(value, file) == NormKind::LocalRead)
}

fn unary_bang_condition_and_operand(node: Node<'_>, file: &SourceFile) -> bool {
    if !unary_bang_node(node) {
        return false;
    }
    let mut current = node;
    while let Some(parent) = current.parent() {
        if logical_and_node(parent) {
            return logical_and_condition_node(parent, file);
        }
        if matches!(parent.kind(), "parenthesized_statements" | "parenthesized_expression") {
            current = parent;
            continue;
        }
        return false;
    }
    false
}

fn unary_bang_logical_and_operand(node: Node<'_>) -> bool {
    if !unary_bang_node(node) {
        return false;
    }
    let mut current = node;
    while let Some(parent) = current.parent() {
        if logical_and_node(parent) {
            return true;
        }
        if matches!(parent.kind(), "parenthesized_statements" | "parenthesized_expression") {
            current = parent;
            continue;
        }
        return false;
    }
    false
}

fn under_unary_bang_logical_and_operand(node: Node<'_>, file: &SourceFile) -> bool {
    let mut current = Some(node);
    while let Some(inner) = current {
        if unary_bang_logical_and_operand(inner) {
            return true;
        }
        if logical_and_node(inner) {
            let needle = format!("!{}", node_text(node, file));
            if node_text(inner, file).contains(&needle) {
                return true;
            }
        }
        current = inner.parent();
    }
    false
}

fn negated_logical_child(parent: Node<'_>, child: Node<'_>, file: &SourceFile) -> bool {
    let parent_text = node_text(parent, file);
    if !parent_text.contains("&&") && !parent_text.contains(" and ") {
        return false;
    }
    parent_text.contains(&format!("!{}", node_text(child, file)))
}

fn logical_and_condition_node(node: Node<'_>, file: &SourceFile) -> bool {
    if !logical_and_node(node) {
        return false;
    }
    let mut current = node;
    while let Some(parent) = current.parent() {
        if logical_and_node(parent) {
            current = parent;
            continue;
        }
        let condition_parent = matches!(
            normalized_kind(parent, file),
            NormKind::If | NormKind::Unless | NormKind::While | NormKind::Until
        ) || matches!(
            parent.kind(),
            "if_modifier" | "unless_modifier" | "modifier_if" | "modifier_unless" | "conditional"
        );
        return condition_parent && condition_node(parent) == Some(current);
    }
    false
}

fn logical_and_assignment_value_node(node: Node<'_>) -> bool {
    if !logical_and_node(node) {
        return false;
    }
    let mut current = node;
    while let Some(parent) = current.parent() {
        if logical_and_node(parent) || matches!(parent.kind(), "parenthesized_statements" | "parenthesized_expression") {
            current = parent;
            continue;
        }
        return matches!(parent.kind(), "assignment" | "operator_assignment")
            && write_value(parent) == Some(current);
    }
    false
}

fn logical_and_usage_node(node: Node<'_>, file: &SourceFile) -> bool {
    logical_and_condition_node(node, file) || logical_and_assignment_value_node(node)
}

fn walk_raw(node: Node<'_>, f: &mut impl FnMut(Node<'_>)) {
    f(node);
    for child in named_children(node) {
        walk_raw(child, f);
    }
}

fn line(node: Node<'_>) -> usize { node.start_position().row + 1 }

fn end_line(node: Node<'_>) -> usize {
    node.end_position().row + 1
}

fn named_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    let children = node.named_children(&mut cursor)
        .filter(|child| *child != node)
        .filter(|child| child.kind() != "comment")
        .collect::<Vec<_>>();
    if node.kind() == "ensure" {
        children.first().copied().into_iter().collect()
    } else if matches!(node.kind(), "body_statement" | "block_body" | "then")
        && node.parent().is_some_and(|parent| parent.kind() == "ensure")
    {
        children.first().copied().into_iter().collect()
    } else {
        children
    }
}

fn all_children(node: Node<'_>) -> Vec<Node<'_>> {
    let mut cursor = node.walk();
    node.children(&mut cursor)
        .filter(|child| *child != node)
        .collect()
}

fn node_text(node: Node<'_>, file: &SourceFile) -> String {
    node.utf8_text(file.source.as_bytes()).unwrap_or("").to_string()
}

fn node_text_raw(node: Node<'_>) -> String {
    node.kind().to_string()
}

fn next_sibling_raw_text(node: Node<'_>) -> Option<String> {
    let mut sibling = node.next_sibling();
    while let Some(candidate) = sibling {
        if !candidate.is_named() {
            return Some(node_text_raw(candidate));
        }
        sibling = candidate.next_sibling();
    }
    None
}

fn identifier_like(text: &str) -> bool {
    let mut chars = text.chars();
    matches!(chars.next(), Some('a'..='z' | '_'))
        && chars.all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '_' | '!' | '?' | '='))
}

fn unquote(text: &str) -> String {
    text.trim()
        .trim_start_matches('"')
        .trim_start_matches('\'')
        .trim_end_matches('"')
        .trim_end_matches('\'')
        .to_string()
}

fn first_line(text: &str) -> String {
    text.lines().next().unwrap_or("").trim().chars().take(160).collect()
}

fn rel_path(root: &Path, path: &Path) -> String {
    if let Ok(stripped) = path.strip_prefix(root) {
        return stripped.to_string_lossy().trim_start_matches("./").to_string();
    }

    let root_components = root.components().collect::<Vec<_>>();
    let path_components = path.components().collect::<Vec<_>>();
    let mut common = 0usize;
    while common < root_components.len()
        && common < path_components.len()
        && root_components[common] == path_components[common]
    {
        common += 1;
    }
    if common == 0 {
        return path.to_string_lossy().to_string();
    }

    let mut rel = PathBuf::new();
    for component in &root_components[common..] {
        if matches!(component, std::path::Component::Normal(_)) {
            rel.push("..");
        }
    }
    for component in &path_components[common..] {
        match component {
            std::path::Component::Normal(part) => rel.push(part),
            std::path::Component::ParentDir => rel.push(".."),
            std::path::Component::CurDir => {}
            _ => return path.to_string_lossy().to_string(),
        }
    }
    rel.to_string_lossy().trim_start_matches("./").to_string()
}

fn debug_node_name(kind: NormKind) -> &'static str {
    match kind {
        NormKind::Program => "ProgramNode",
        NormKind::Statements => "StatementsNode",
        NormKind::Class => "ClassNode",
        NormKind::Module => "ModuleNode",
        NormKind::Def => "DefNode",
        NormKind::Parameters => "ParametersNode",
        NormKind::Block => "BlockNode",
        NormKind::Call => "CallNode",
        NormKind::Array => "ArrayNode",
        NormKind::Hash | NormKind::KeywordHash => "HashNode",
        NormKind::Pair => "AssocNode",
        NormKind::String => "StringNode",
        NormKind::InterpolatedString => "InterpolatedStringNode",
        NormKind::Symbol => "SymbolNode",
        NormKind::Integer => "IntegerNode",
        NormKind::Float => "FloatNode",
        NormKind::True => "TrueNode",
        NormKind::False => "FalseNode",
        NormKind::Nil => "NilNode",
        NormKind::Range => "RangeNode",
        NormKind::Return => "ReturnNode",
        NormKind::Yield => "YieldNode",
        NormKind::If => "IfNode",
        NormKind::Unless => "UnlessNode",
        NormKind::While => "WhileNode",
        NormKind::Until => "UntilNode",
        NormKind::Case => "CaseNode",
        NormKind::When => "WhenNode",
        NormKind::Else => "ElseNode",
        NormKind::Begin => "BeginNode",
        NormKind::Rescue => "RescueNode",
        NormKind::Parentheses => "ParenthesesNode",
        NormKind::SelfNode => "SelfNode",
        NormKind::ConstRead => "ConstantReadNode",
        NormKind::ConstPath => "ConstantPathNode",
        NormKind::ConstWrite => "ConstantWriteNode",
        NormKind::LocalRead => "LocalVariableReadNode",
        NormKind::LocalWrite => "LocalVariableWriteNode",
        NormKind::IvarRead => "InstanceVariableReadNode",
        NormKind::IvarWrite => "InstanceVariableWriteNode",
        NormKind::ClassVarRead => "ClassVariableReadNode",
        NormKind::ClassVarWrite => "ClassVariableWriteNode",
        NormKind::GlobalVarRead => "GlobalVariableReadNode",
        NormKind::GlobalVarWrite => "GlobalVariableWriteNode",
        NormKind::Or => "HiddenOrNode",
        NormKind::HiddenOr => "HiddenOrNode",
        NormKind::Other => "Node",
    }
}
