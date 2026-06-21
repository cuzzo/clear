use super::normalized_behavior::NormalizedLanguageBehavior;

struct KotlinNormalizedBehavior;

impl NormalizedLanguageBehavior for KotlinNormalizedBehavior {
    fn parameter_name_from_signature(&self, param: &str) -> Option<String> {
        let text = param.split('=').next().unwrap_or(param).trim();
        let before_colon = text.split_once(':')?.0.trim();
        let name = before_colon
            .strip_prefix("vararg ")
            .unwrap_or(before_colon)
            .trim();
        simple_identifier(name).then(|| name.to_string())
    }
}

static BEHAVIOR: KotlinNormalizedBehavior = KotlinNormalizedBehavior;

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
