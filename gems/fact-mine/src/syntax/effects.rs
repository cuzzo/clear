use super::{
    normalized_behavior::{NormalizedLanguageBehavior, NormalizedSemanticEffect},
    CallSite, FunctionDef, SemanticEffectSite,
};
use std::collections::HashSet;

#[derive(Clone, Copy)]
pub(crate) struct EffectLexicon {
    pub(crate) dispatch_mids: &'static [&'static str],
    pub(crate) meta_mids: &'static [&'static str],
    pub(crate) method_obj_mids: &'static [&'static str],
    pub(crate) io_consts: &'static [&'static str],
    pub(crate) io_pairs: &'static [(&'static str, &'static [&'static str])],
    pub(crate) io_receiver_prefixes: &'static [&'static str],
    pub(crate) io_bare: &'static [&'static str],
    pub(crate) context_pairs: &'static [(&'static str, &'static [&'static str])],
    pub(crate) context_consts: &'static [&'static str],
    pub(crate) context_bare: &'static [&'static str],
    pub(crate) callback_set: &'static [&'static str],
    pub(crate) callback_requires_block: bool,
    pub(crate) bang_mutation: bool,
}

impl EffectLexicon {
    pub(crate) const fn empty() -> Self {
        Self {
            dispatch_mids: &[],
            meta_mids: &[],
            method_obj_mids: &[],
            io_consts: &[],
            io_pairs: &[],
            io_receiver_prefixes: &[],
            io_bare: &[],
            context_pairs: &[],
            context_consts: &[],
            context_bare: &[],
            callback_set: &[],
            callback_requires_block: false,
            bang_mutation: false,
        }
    }
}

pub(crate) fn semantic_effect_sites_from_calls(
    behavior: &dyn NormalizedLanguageBehavior,
    call_sites: &[CallSite],
    function_defs: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let local_methods = function_defs
        .iter()
        .map(|function| (function.owner.clone(), function.name.clone()))
        .collect::<HashSet<_>>();
    call_sites
        .iter()
        .filter(|call| !local_self_call_to_known_function(call, &local_methods))
        .filter_map(|call| semantic_effect_site_for_call(call, behavior))
        .collect()
}

pub(crate) fn dedup_semantic_effect_sites(sites: &mut Vec<SemanticEffectSite>) {
    let mut seen = HashSet::new();
    sites.retain(|site| {
        seen.insert((
            site.kind.clone(),
            site.detail.clone(),
            site.file.clone(),
            site.function.clone(),
            site.line,
            site.span,
        ))
    });
}

fn local_self_call_to_known_function(
    call: &CallSite,
    local_methods: &HashSet<(String, String)>,
) -> bool {
    call.receiver == "self" && local_methods.contains(&(call.owner.clone(), call.message.clone()))
}

fn semantic_effect_site_for_call(
    call: &CallSite,
    behavior: &dyn NormalizedLanguageBehavior,
) -> Option<SemanticEffectSite> {
    let effect = if call.safe_navigation && !call.receiver.is_empty() {
        NormalizedSemanticEffect {
            kind: "eliminable_guard".to_string(),
            detail: call.receiver.clone(),
        }
    } else {
        behavior.semantic_effect_for_call(call)?
    };
    Some(SemanticEffectSite {
        kind: effect.kind,
        detail: effect.detail,
        file: call.file.clone(),
        function: call.function.clone(),
        line: call.line,
        span: call.span,
    })
}

pub(crate) fn effect_from_call_with_lexicon(
    call: &CallSite,
    lexicon: &EffectLexicon,
) -> Option<NormalizedSemanticEffect> {
    let message = call.message.as_str();
    let (kind, detail) = if effect_callback_call(call, message, lexicon) {
        ("callback_inversion", message.to_string())
    } else if lexicon.meta_mids.contains(&message) {
        ("metaprogramming", message.to_string())
    } else if lexicon.dispatch_mids.contains(&message) {
        ("dynamic_dispatch", message.to_string())
    } else if message == "call" && !call.receiver.is_empty() {
        if method_object_receiver(&call.receiver, lexicon) {
            ("dynamic_dispatch", "method(...).call".to_string())
        } else if variable_receiver(&call.receiver) {
            ("dynamic_dispatch", format!("{}.call", call.receiver))
        } else {
            return None;
        }
    } else if let Some((kind, detail)) = const_effect_kind_detail(call, message, lexicon) {
        (kind, detail)
    } else if call.receiver == "self" && lexicon.io_bare.contains(&message) {
        ("hidden_io", message.to_string())
    } else if call.receiver == "self" && lexicon.context_bare.contains(&message) {
        ("context_dependency", message.to_string())
    } else if lexicon.bang_mutation
        && message.len() > 1
        && message.ends_with('!')
        && !matches!(message, "!=" | "!~")
    {
        ("hidden_mutation", message.to_string())
    } else {
        return None;
    };

    Some(NormalizedSemanticEffect {
        kind: kind.to_string(),
        detail,
    })
}

fn const_effect_kind_detail(
    call: &CallSite,
    message: &str,
    lexicon: &EffectLexicon,
) -> Option<(&'static str, String)> {
    let receiver = call.receiver.as_str();
    if receiver.is_empty() || receiver == "self" {
        return None;
    }
    let base = receiver
        .trim_start_matches("::")
        .split("::")
        .next()
        .unwrap_or("");
    if lexicon.io_consts.contains(&base)
        || lexicon
            .io_pairs
            .iter()
            .any(|(name, mids)| *name == base && mids.contains(&message))
        || lexicon
            .io_receiver_prefixes
            .iter()
            .any(|prefix| receiver.starts_with(prefix))
    {
        return Some((
            "hidden_io",
            format!("{}.{}", receiver.trim_start_matches("::"), message),
        ));
    }
    if lexicon.context_consts.contains(&base) {
        return Some((
            "context_dependency",
            receiver.trim_start_matches("::").to_string(),
        ));
    }
    if lexicon
        .context_pairs
        .iter()
        .any(|(name, mids)| *name == base && mids.contains(&message))
    {
        return Some(("context_dependency", format!("{base}.{message}")));
    }
    None
}

fn effect_callback_call(call: &CallSite, message: &str, lexicon: &EffectLexicon) -> bool {
    effect_callback_name(message, lexicon)
        && !lexicon.meta_mids.contains(&message)
        && (!lexicon.callback_requires_block
            || call.block
            || call.arguments.iter().any(|arg| arg.starts_with('&')))
}

fn effect_callback_name(message: &str, lexicon: &EffectLexicon) -> bool {
    lexicon.callback_set.contains(&message)
        || message.starts_with("with_")
        || message.starts_with("around_")
        || message.starts_with("on_")
        || message.starts_with("before_")
        || message.starts_with("after_")
        || message.ends_with("_hook")
}

fn method_object_receiver(receiver: &str, lexicon: &EffectLexicon) -> bool {
    lexicon
        .method_obj_mids
        .iter()
        .any(|name| receiver.contains(name))
}

fn variable_receiver(receiver: &str) -> bool {
    let mut chars = receiver.chars();
    matches!(chars.next(), Some(first) if first == '@' || first == '$' || first == '_' || first.is_ascii_lowercase())
        && chars.all(|ch| ch == '_' || ch == '!' || ch == '?' || ch.is_ascii_alphanumeric())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_lexicon_empty() {
        let lexicon = EffectLexicon::empty();
        assert!(lexicon.meta_mids.is_empty());
        assert!(!lexicon.bang_mutation);
    }

    #[test]
    fn test_method_object_call() {
        let mut lexicon = EffectLexicon::empty();
        lexicon.method_obj_mids = &["method"];
        let call = CallSite {
            receiver: "method(:foo)".to_string(),
            message: "call".to_string(),
            file: "foo.rb".to_string(),
            function: "bar".to_string(),
            owner: "A".to_string(),
            line: 1,
            span: [1, 0, 1, 5],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        };
        let effect = effect_from_call_with_lexicon(&call, &lexicon).unwrap();
        assert_eq!(effect.kind, "dynamic_dispatch");
        assert_eq!(effect.detail, "method(...).call");
    }

    #[test]
    fn test_call_other_receiver_none() {
        let lexicon = EffectLexicon::empty();
        let call = CallSite {
            receiver: "OtherNode".to_string(), // not variable receiver (starts with uppercase)
            message: "call".to_string(),
            file: "foo.rb".to_string(),
            function: "bar".to_string(),
            owner: "A".to_string(),
            line: 1,
            span: [1, 0, 1, 5],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        };
        assert!(effect_from_call_with_lexicon(&call, &lexicon).is_none());
    }

    #[test]
    fn test_context_bare_effect() {
        let mut lexicon = EffectLexicon::empty();
        lexicon.context_bare = &["current_user"];
        let call = CallSite {
            receiver: "self".to_string(),
            message: "current_user".to_string(),
            file: "foo.rb".to_string(),
            function: "bar".to_string(),
            owner: "A".to_string(),
            line: 1,
            span: [1, 0, 1, 5],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        };
        let effect = effect_from_call_with_lexicon(&call, &lexicon).unwrap();
        assert_eq!(effect.kind, "context_dependency");
        assert_eq!(effect.detail, "current_user");
    }

    #[test]
    fn test_bang_mutation_excludes() {
        let mut lexicon = EffectLexicon::empty();
        lexicon.bang_mutation = true;
        let call1 = CallSite {
            receiver: "self".to_string(),
            message: "!=".to_string(),
            file: "foo.rb".to_string(),
            function: "bar".to_string(),
            owner: "A".to_string(),
            line: 1,
            span: [1, 0, 1, 5],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        };
        assert!(effect_from_call_with_lexicon(&call1, &lexicon).is_none());

        let call2 = CallSite {
            receiver: "self".to_string(),
            message: "update!".to_string(),
            file: "foo.rb".to_string(),
            function: "bar".to_string(),
            owner: "A".to_string(),
            line: 1,
            span: [1, 0, 1, 5],
            conditional: false,
            arguments: Vec::new(),
            control: None,
            safe_navigation: false,
            block: false,
        };
        let effect = effect_from_call_with_lexicon(&call2, &lexicon).unwrap();
        assert_eq!(effect.kind, "hidden_mutation");
        assert_eq!(effect.detail, "update!");
    }
}
