use super::normalized_behavior::NormalizedLanguageBehavior;

struct SwiftNormalizedBehavior;

impl NormalizedLanguageBehavior for SwiftNormalizedBehavior {
    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.split('=').next().unwrap_or(param).trim();
        let before_colon = text.split_once(':')?.0.trim();
        before_colon
            .split_whitespace()
            .filter(|part| *part != "_")
            .next_back()
            .filter(|name| simple_identifier(name))
            .map(ToString::to_string)
    }
}

static BEHAVIOR: SwiftNormalizedBehavior = SwiftNormalizedBehavior;

pub(crate) fn behavior() -> &'static dyn NormalizedLanguageBehavior {
    &BEHAVIOR
}

fn simple_identifier(name: &str) -> bool {
    let mut chars = name.chars();
    let Some(first) = chars.next() else {
        return false;
    };
    (first == '_' || first.is_ascii_alphabetic())
        && chars.all(|ch| ch == '_' || ch.is_ascii_alphanumeric())
}
