use super::{adapters::LanguageProfile, CallSite, FunctionDef};

pub(crate) fn apply_visibility(
    functions: &mut [FunctionDef],
    calls: &[CallSite],
    profile: &dyn LanguageProfile,
) {
    let mut owners = functions
        .iter()
        .map(|function| function.owner.clone())
        .collect::<Vec<_>>();
    owners.sort();
    owners.dedup();

    for owner in owners {
        let function_indices = functions
            .iter()
            .enumerate()
            .filter_map(|(index, function)| (function.owner == owner).then_some(index))
            .collect::<Vec<_>>();
        let call_indices = calls
            .iter()
            .enumerate()
            .filter_map(|(index, call)| {
                (call.owner == owner && profile.visibility_call(call)).then_some(index)
            })
            .collect::<Vec<_>>();

        let mut visibility = "public".to_string();
        let mut events = Vec::new();
        events.extend(
            function_indices
                .iter()
                .map(|index| (functions[*index].line, 1_u8, *index)),
        );
        events.extend(
            call_indices
                .iter()
                .map(|index| (calls[*index].line, 0_u8, *index)),
        );
        events.sort();

        for (_, kind, index) in events {
            if kind == 1 {
                if functions[index].visibility.is_none() {
                    functions[index].visibility = Some(if functions[index].name.contains('.') {
                        "public".to_string()
                    } else {
                        visibility.clone()
                    });
                }
            } else {
                let call = &calls[index];
                if call.arguments.is_empty() {
                    visibility = call.message.clone();
                } else {
                    for argument in &call.arguments {
                        let name = profile.visibility_arg_name(argument);
                        for function_index in function_indices.iter().rev() {
                            if functions[*function_index].name == name {
                                functions[*function_index].visibility = Some(call.message.clone());
                                break;
                            }
                        }
                    }
                }
            }
        }
    }
}
