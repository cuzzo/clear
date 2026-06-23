use crate::decomplex::syntax::Language;
use std::sync::OnceLock;
use regex::Regex;

pub trait Dialect: Send + Sync {
    /// Normalize/clean an identifier token (e.g. trimming `@` ivar sigils or `=` setter suffixes).
    fn clean_identifier(&self, token: &str) -> String;

    /// Normalize/canonicalize a predicate expression for semantic alias analysis.
    fn canonicalize_predicate(&self, text: &str) -> String;

    /// Checks if a member access/prefix matches an instance variable (ivar) pattern.
    fn is_ivar(&self, text: &str) -> bool;

    /// Check if a token is a valid identifier.
    fn is_identifier(&self, token: &str) -> bool;

    /// Normalize a message call name under a given caller name.
    fn scoped_name(&self, caller_name: &str, message: &str) -> String;
}

fn default_clean_identifier(token: &str) -> String {
    token
        .trim_start_matches('@')
        .trim_end_matches('=')
        .to_string()
}

fn default_canonicalize_predicate(text: &str) -> String {
    let mut t = text.strip_prefix("self.").unwrap_or(text).to_string();
    t = t.strip_prefix('@').unwrap_or(&t).to_string();

    static RECEIVER_PREFIX: OnceLock<Regex> = OnceLock::new();
    let re = RECEIVER_PREFIX.get_or_init(|| {
        Regex::new(r"^[A-Za-z_]\w*(?:\([^)]*\))?\.(?P<rest>[A-Za-z_]\w*\s*(?:==|!=|\.))")
            .expect("receiver prefix regex")
    });
    t = re.replace(&t, "$rest").to_string();

    t.split_whitespace().collect::<Vec<_>>().join(" ")
}

pub struct RubyDialect;

impl Dialect for RubyDialect {
    fn clean_identifier(&self, token: &str) -> String {
        default_clean_identifier(token)
    }

    fn canonicalize_predicate(&self, text: &str) -> String {
        default_canonicalize_predicate(text)
    }

    fn is_ivar(&self, text: &str) -> bool {
        text.starts_with('@')
    }

    fn is_identifier(&self, token: &str) -> bool {
        let token = token.strip_prefix('@').unwrap_or(token);
        let token = token.trim_end_matches(['!', '?', '=']);
        let mut chars = token.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        (first == '_' || first.is_ascii_alphabetic())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    }

    fn scoped_name(&self, caller_name: &str, message: &str) -> String {
        if caller_name.starts_with("self.") {
            format!("self.{}", message)
        } else {
            message.to_string()
        }
    }
}

pub struct PythonDialect;

impl Dialect for PythonDialect {
    fn clean_identifier(&self, token: &str) -> String {
        let t = token.strip_prefix("self.").unwrap_or(token);
        default_clean_identifier(t)
    }

    fn canonicalize_predicate(&self, text: &str) -> String {
        default_canonicalize_predicate(text)
    }

    fn is_ivar(&self, text: &str) -> bool {
        text.starts_with("self.")
    }

    fn is_identifier(&self, token: &str) -> bool {
        let mut chars = token.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        (first == '_' || first.is_ascii_alphabetic())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    }

    fn scoped_name(&self, caller_name: &str, message: &str) -> String {
        if caller_name.starts_with("self.") {
            format!("self.{}", message)
        } else {
            message.to_string()
        }
    }
}

pub struct DefaultDialect;

impl Dialect for DefaultDialect {
    fn clean_identifier(&self, token: &str) -> String {
        default_clean_identifier(token)
    }

    fn canonicalize_predicate(&self, text: &str) -> String {
        default_canonicalize_predicate(text)
    }

    fn is_ivar(&self, text: &str) -> bool {
        text.starts_with('@')
    }

    fn is_identifier(&self, token: &str) -> bool {
        let token = token.strip_prefix('@').unwrap_or(token);
        let token = token.trim_end_matches(['!', '?', '=']);
        let mut chars = token.chars();
        let Some(first) = chars.next() else {
            return false;
        };
        (first == '_' || first.is_ascii_alphabetic())
            && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
    }

    fn scoped_name(&self, caller_name: &str, message: &str) -> String {
        if caller_name.starts_with("self.") {
            format!("self.{}", message)
        } else {
            message.to_string()
        }
    }
}

pub fn dialect_for(language: Language) -> Box<dyn Dialect> {
    match language {
        Language::Ruby => Box::new(RubyDialect),
        Language::Python => Box::new(PythonDialect),
        _ => Box::new(DefaultDialect),
    }
}

pub fn dialect_for_document(doc: &crate::decomplex::syntax::Document) -> Box<dyn Dialect> {
    dialect_for(doc.language)
}

pub fn dialect_for_method(method: &crate::decomplex::syntax::local_flow::MethodSummary) -> Box<dyn Dialect> {
    let language = std::path::Path::new(&method.file)
        .extension()
        .and_then(|ext| ext.to_str())
        .and_then(|ext| crate::decomplex::syntax::Language::for_extension(ext))
        .unwrap_or(crate::decomplex::syntax::Language::Ruby);
    dialect_for(language)
}
