use super::{
    adapters::false_simplicity_lexicon::{false_simplicity_lexicon, FalseSimplicityLexicon},
    CallSite, FunctionDef, Language, SemanticEffectSite,
};
use std::collections::HashSet;

const GENERIC_SYSTEM_IO_BARE: &[&str] =
    &["print", "println", "eprintln", "printf", "puts", "panic"];

pub(crate) fn semantic_effect_sites_from_calls(
    language: Language,
    call_sites: &[CallSite],
    function_defs: &[FunctionDef],
) -> Vec<SemanticEffectSite> {
    let lexicon = false_simplicity_lexicon(language);
    let local_methods = function_defs
        .iter()
        .map(|function| (function.owner.clone(), function.name.clone()))
        .collect::<HashSet<_>>();
    call_sites
        .iter()
        .filter(|call| !local_self_call_to_known_function(call, &local_methods))
        .filter_map(|call| semantic_effect_site_for_call(call, &lexicon))
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
    lexicon: &FalseSimplicityLexicon,
) -> Option<SemanticEffectSite> {
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
    } else if call.receiver == "self"
        && (lexicon.io_bare.contains(&message) || GENERIC_SYSTEM_IO_BARE.contains(&message))
    {
        ("hidden_io", message.to_string())
    } else if call.receiver == "self" && lexicon.context_bare.contains(&message) {
        ("context_dependency", message.to_string())
    } else if message.len() > 1 && message.ends_with('!') && !matches!(message, "!=" | "!~") {
        ("hidden_mutation", message.to_string())
    } else {
        return None;
    };

    Some(SemanticEffectSite {
        kind: kind.to_string(),
        detail,
        file: call.file.clone(),
        function: call.function.clone(),
        line: call.line,
        span: call.span,
    })
}

fn const_effect_kind_detail(
    call: &CallSite,
    message: &str,
    lexicon: &FalseSimplicityLexicon,
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
    if base == "Dir" && lexicon.dir_context.contains(&message) {
        return Some(("context_dependency", format!("Dir.{message}")));
    }
    if receiver == "URI" && message == "open" {
        return Some(("hidden_io", "URI.open".to_string()));
    }
    if lexicon.io_consts.contains(&base) || receiver.starts_with("Net::") {
        return Some((
            "hidden_io",
            format!("{}.{}", receiver.trim_start_matches("::"), message),
        ));
    }
    if receiver == "ENV" {
        return Some(("context_dependency", "ENV".to_string()));
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

fn effect_callback_call(call: &CallSite, message: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    effect_callback_name(message, lexicon)
        && !lexicon.meta_mids.contains(&message)
        && (!lexicon.callback_requires_block
            || call.block
            || call.arguments.iter().any(|arg| arg.starts_with('&')))
}

fn effect_callback_name(message: &str, lexicon: &FalseSimplicityLexicon) -> bool {
    lexicon.callback_set.contains(&message)
        || message.starts_with("with_")
        || message.starts_with("around_")
        || message.starts_with("on_")
        || message.starts_with("before_")
        || message.starts_with("after_")
        || message.ends_with("_hook")
}

fn method_object_receiver(receiver: &str, lexicon: &FalseSimplicityLexicon) -> bool {
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
