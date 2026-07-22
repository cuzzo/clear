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

/// The query resources exported by this crate. The manifest's `queries` map
/// is validated against this list so adding a query cannot silently bypass
/// the contract or leave a stale language name behind.
pub const QUERY_RESOURCES: &[(&str, &str)] = &[
    ("c", C_HAZARDS),
    ("cpp", CPP_HAZARDS),
    ("csharp", CSHARP_HAZARDS),
    ("go", GO_HAZARDS),
    ("rust", RUST_HAZARDS),
    ("zig", ZIG_HAZARDS),
    ("ruby", RUBY_HAZARDS),
    ("python", PYTHON_HAZARDS),
    ("javascript", JAVASCRIPT_HAZARDS),
    ("typescript", TYPESCRIPT_HAZARDS),
    ("lua", LUA_HAZARDS),
    ("java", JAVA_HAZARDS),
    ("php", PHP_HAZARDS),
    ("kotlin", KOTLIN_HAZARDS),
    ("swift", SWIFT_HAZARDS),
];

/// Return whether a numeric literal on a C/C++ arithmetic hazard is
/// sanitizer-relevant. Dynamic operands remain relevant; harmless literals
/// such as `/ 2` and `<< 3` do not. Zero divisors and shift counts at least
/// 32 are retained conservatively for UBSan's target-type checks.
pub fn c_arithmetic_literal_is_relevant(operator: &str, rhs: &str) -> bool {
    let mut literal = rhs.trim();
    let without_suffix = literal.trim_end_matches(['u', 'U', 'l', 'L']);
    literal = without_suffix;
    let value = if let Some(hex) = literal.strip_prefix("0x").or_else(|| literal.strip_prefix("0X")) {
        u128::from_str_radix(hex, 16).ok()
    } else if literal.chars().all(|character| character.is_ascii_digit()) {
        literal.parse::<u128>().ok()
    } else {
        None
    };
    let Some(value) = value else {
        return true;
    };
    match operator {
        "/" | "%" => value == 0,
        "<<" | ">>" => value >= 32,
        _ => true,
    }
}

#[derive(Debug, Clone, PartialEq)]
enum JsonValue {
    Object(std::collections::BTreeMap<String, JsonValue>),
    Array(Vec<JsonValue>),
    String(String),
    Bool(bool),
    Number,
    Null,
}

struct JsonParser<'a> {
    input: &'a [u8],
    offset: usize,
}

impl<'a> JsonParser<'a> {
    fn parse(input: &'a str) -> Result<JsonValue, String> {
        let mut parser = Self { input: input.as_bytes(), offset: 0 };
        let value = parser.value()?;
        parser.whitespace();
        if parser.offset != parser.input.len() {
            return Err(format!("unexpected JSON at byte {}", parser.offset));
        }
        Ok(value)
    }

    fn whitespace(&mut self) {
        while self.input.get(self.offset).is_some_and(|byte| byte.is_ascii_whitespace()) {
            self.offset += 1;
        }
    }

    fn value(&mut self) -> Result<JsonValue, String> {
        self.whitespace();
        match self.input.get(self.offset).copied() {
            Some(b'{') => self.object(),
            Some(b'[') => self.array(),
            Some(b'"') => Ok(JsonValue::String(self.string()?)),
            Some(b't') => { self.literal(b"true")?; Ok(JsonValue::Bool(true)) }
            Some(b'f') => { self.literal(b"false")?; Ok(JsonValue::Bool(false)) }
            Some(b'n') => { self.literal(b"null")?; Ok(JsonValue::Null) }
            Some(byte) if byte == b'-' || byte.is_ascii_digit() => {
                self.number()?;
                Ok(JsonValue::Number)
            }
            _ => Err(format!("expected JSON value at byte {}", self.offset)),
        }
    }

    fn object(&mut self) -> Result<JsonValue, String> {
        self.offset += 1;
        let mut object = std::collections::BTreeMap::new();
        self.whitespace();
        if self.input.get(self.offset) == Some(&b'}') {
            self.offset += 1;
            return Ok(JsonValue::Object(object));
        }
        loop {
            self.whitespace();
            let key = self.string()?;
            self.whitespace();
            if self.input.get(self.offset) != Some(&b':') {
                return Err(format!("expected ':' at byte {}", self.offset));
            }
            self.offset += 1;
            let value = self.value()?;
            if object.insert(key.clone(), value).is_some() {
                return Err(format!("duplicate JSON object key {key:?}"));
            }
            self.whitespace();
            match self.input.get(self.offset) {
                Some(b',') => self.offset += 1,
                Some(b'}') => { self.offset += 1; break; }
                _ => return Err(format!("expected ',' or '}}' at byte {}", self.offset)),
            }
        }
        Ok(JsonValue::Object(object))
    }

    fn array(&mut self) -> Result<JsonValue, String> {
        self.offset += 1;
        let mut array = Vec::new();
        self.whitespace();
        if self.input.get(self.offset) == Some(&b']') {
            self.offset += 1;
            return Ok(JsonValue::Array(array));
        }
        loop {
            array.push(self.value()?);
            self.whitespace();
            match self.input.get(self.offset) {
                Some(b',') => self.offset += 1,
                Some(b']') => { self.offset += 1; break; }
                _ => return Err(format!("expected ',' or ']' at byte {}", self.offset)),
            }
        }
        Ok(JsonValue::Array(array))
    }

    fn string(&mut self) -> Result<String, String> {
        if self.input.get(self.offset) != Some(&b'"') {
            return Err(format!("expected JSON string at byte {}", self.offset));
        }
        self.offset += 1;
        let mut output = String::new();
        while let Some(byte) = self.input.get(self.offset).copied() {
            self.offset += 1;
            match byte {
                b'"' => return Ok(output),
                b'\\' => {
                    let escaped = self.input.get(self.offset).copied().ok_or_else(|| "unterminated escape".to_string())?;
                    self.offset += 1;
                    match escaped {
                        b'"' => output.push('"'),
                        b'\\' => output.push('\\'),
                        b'/' => output.push('/'),
                        b'b' => output.push('\u{0008}'),
                        b'f' => output.push('\u{000c}'),
                        b'n' => output.push('\n'),
                        b'r' => output.push('\r'),
                        b't' => output.push('\t'),
                        b'u' => {
                            let end = self.offset + 4;
                            let hex = self.input.get(self.offset..end).ok_or_else(|| "short unicode escape".to_string())?;
                            let text = std::str::from_utf8(hex).map_err(|_| "invalid unicode escape".to_string())?;
                            let code = u32::from_str_radix(text, 16).map_err(|_| "invalid unicode escape".to_string())?;
                            let character = char::from_u32(code).ok_or_else(|| "invalid unicode scalar".to_string())?;
                            output.push(character);
                            self.offset = end;
                        }
                        _ => return Err(format!("invalid escape at byte {}", self.offset - 1)),
                    }
                }
                byte if byte < 0x20 => return Err("control character in JSON string".to_string()),
                byte => output.push(byte as char),
            }
        }
        Err("unterminated JSON string".to_string())
    }

    fn literal(&mut self, expected: &[u8]) -> Result<(), String> {
        let end = self.offset + expected.len();
        if self.input.get(self.offset..end) == Some(expected) {
            self.offset = end;
            Ok(())
        } else {
            Err(format!("invalid JSON literal at byte {}", self.offset))
        }
    }

    fn number(&mut self) -> Result<(), String> {
        while self.input.get(self.offset).is_some_and(|byte| {
            byte.is_ascii_digit() || matches!(byte, b'-' | b'+' | b'.' | b'e' | b'E')
        }) {
            self.offset += 1;
        }
        Ok(())
    }
}

fn object<'a>(value: &'a JsonValue, context: &str) -> Result<&'a std::collections::BTreeMap<String, JsonValue>, String> {
    match value {
        JsonValue::Object(object) => Ok(object),
        _ => Err(format!("{context} must be a JSON object")),
    }
}

fn array<'a>(value: &'a JsonValue, context: &str) -> Result<&'a [JsonValue], String> {
    match value {
        JsonValue::Array(array) => Ok(array),
        _ => Err(format!("{context} must be a JSON array")),
    }
}

fn string_field<'a>(object: &'a std::collections::BTreeMap<String, JsonValue>, key: &str) -> Result<&'a str, String> {
    string_value(object.get(key), key)
}

fn string_value<'a>(value: Option<&'a JsonValue>, context: &str) -> Result<&'a str, String> {
    match value {
        Some(JsonValue::String(value)) if !value.is_empty() => Ok(value),
        Some(JsonValue::String(_)) => Err(format!("{context} must not be empty")),
        _ => Err(format!("missing string field {context:?}")),
    }
}

fn bool_field(object: &std::collections::BTreeMap<String, JsonValue>, key: &str) -> Result<bool, String> {
    match object.get(key) {
        Some(JsonValue::Bool(value)) => Ok(*value),
        _ => Err(format!("missing boolean field {key:?}")),
    }
}

fn pattern_matches(pattern: &str, hazard: &str) -> bool {
    if !pattern.contains('*') {
        return pattern == hazard;
    }
    let mut remainder = hazard;
    for part in pattern.split('*').filter(|part| !part.is_empty()) {
        let Some(index) = remainder.find(part) else { return false; };
        remainder = &remainder[index + part.len()..];
    }
    true
}

fn query_hazard_names(query: &str) -> Vec<String> {
    let bytes = query.as_bytes();
    let mut names = Vec::new();
    let mut index = 0;
    while index + 8 < bytes.len() {
        if bytes[index..].starts_with(b"@hazard.") {
            let start = index + 8;
            let mut end = start;
            while end < bytes.len() && (bytes[end].is_ascii_alphanumeric() || bytes[end] == b'_') {
                end += 1;
            }
            if end > start {
                names.push(query[start..end].to_string());
            }
            index = end;
        } else {
            index += 1;
        }
    }
    names
}

/// Validate all policy/query invariants shared by FactMine, Lineage, and
/// SlopCop. This intentionally uses a tiny JSON reader so the contract crate
/// remains dependency-free; consumers can still deserialize the same bytes
/// with their native JSON libraries.
pub fn validate_contract() -> Result<(), String> {
    let root = JsonParser::parse(CONTRACT_JSON)?;
    let root = object(&root, "contract")?;
    let evidence = object(root.get("evidence").ok_or("contract.evidence is missing")?, "contract.evidence")?;
    let policies = array(root.get("policies").ok_or("contract.policies is missing")?, "contract.policies")?;
    let queries = object(root.get("queries").ok_or("contract.queries is missing")?, "contract.queries")?;

    let resource_names: std::collections::BTreeSet<_> = QUERY_RESOURCES.iter().map(|(name, _)| *name).collect();
    let manifest_names: std::collections::BTreeSet<_> = queries.keys().map(String::as_str).collect();
    if resource_names != manifest_names {
        return Err(format!("query resources and contract.queries differ: resources={resource_names:?}, manifest={manifest_names:?}"));
    }

    let mut patterns = Vec::new();
    for (index, policy_value) in policies.iter().enumerate() {
        let policy = object(policy_value, &format!("policy {index}"))?;
        let pattern = string_field(policy, "match")?;
        let kind = string_field(policy, "kind")?;
        let provider = string_field(policy, "evidence_provider")?;
        let claim = string_field(policy, "evidence_claim")?;
        let _ = bool_field(policy, "coverage_required")?;
        let _ = bool_field(policy, "report_required")?;
        let _ = string_field(policy, "label")?;
        let _ = string_field(policy, "mitigation")?;
        let evidence_entry = object(evidence.get(provider).ok_or_else(|| format!("policy {pattern:?} uses unknown evidence provider {provider:?}"))?, provider)?;
        let declared_claim = string_field(evidence_entry, "claim")?;
        if declared_claim != claim {
            return Err(format!("policy {pattern:?} claims {claim:?}, provider {provider:?} declares {declared_claim:?}"));
        }
        if patterns.iter().any(|existing: &String| existing == pattern) {
            return Err(format!("duplicate hazard policy {pattern:?}"));
        }
        let _ = kind;
        patterns.push(pattern.to_string());
    }

    let mut all_hazards = std::collections::BTreeSet::new();
    for (name, query) in QUERY_RESOURCES {
        let query_path = string_value(
            Some(queries.get(*name).ok_or_else(|| format!("missing query manifest entry {name:?}"))?),
            name,
        )?;
        let expected_path = format!("queries/{name}_hazards.scm");
        if query_path != expected_path {
            return Err(format!("query manifest entry {name:?} points to {query_path:?}, expected {expected_path:?}"));
        }
        let captures = query_hazard_names(query);
        if captures.is_empty() {
            return Err(format!("query {name:?} exports no hazard captures"));
        }
        for hazard in captures {
            all_hazards.insert(hazard.clone());
            let matches = patterns.iter().filter(|pattern| pattern_matches(pattern, &hazard)).count();
            if matches != 1 {
                return Err(format!("hazard capture {hazard:?} matches {matches} policies"));
            }
        }
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::validate_contract;

    #[test]
    fn canonical_contract_is_valid_and_synchronized() {
        validate_contract().expect("canonical hazard contract must validate");
    }
}
