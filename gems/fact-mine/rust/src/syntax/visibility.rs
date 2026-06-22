use super::{normalized_behavior::NormalizedVisibilityEvent, FunctionDef};

pub(crate) fn apply_normalized_visibility(
    functions: &mut [FunctionDef],
    visibility_events: &[NormalizedVisibilityEvent],
) {
    let mut owners = functions
        .iter()
        .map(|function| function.owner.clone())
        .collect::<Vec<_>>();
    owners.sort();
    owners.dedup();

    for owner in owners {
        apply_normalized_visibility_for_owner(functions, visibility_events, &owner);
    }
}

fn apply_normalized_visibility_for_owner(
    functions: &mut [FunctionDef],
    visibility_events: &[NormalizedVisibilityEvent],
    owner: &str,
) {
    let function_indices = functions
        .iter()
        .enumerate()
        .filter_map(|(index, function)| (function.owner == owner).then_some(index))
        .collect::<Vec<_>>();

    let mut events = function_indices
        .iter()
        .map(|index| (functions[*index].line, 1_u8, *index))
        .collect::<Vec<_>>();
    let owner_events = visibility_events
        .iter()
        .enumerate()
        .filter_map(|(index, event)| (event.owner == owner).then_some(index))
        .collect::<Vec<_>>();
    events.extend(
        owner_events
            .iter()
            .map(|index| (visibility_events[*index].line, 0_u8, *index)),
    );
    events.sort();

    let mut current = "public".to_string();
    for (_, kind, index) in events {
        if kind == 1 {
            let function = &mut functions[index];
            if function.name.contains('.') {
                function.visibility = Some("public".to_string());
            } else if function.visibility.as_deref() == Some("public") {
                function.visibility = Some(current.clone());
            }
            continue;
        }

        let event = &visibility_events[index];
        if event.target_names.is_empty() {
            current = event.visibility.clone();
        } else {
            for target in &event.target_names {
                for function_index in function_indices.iter().rev() {
                    if functions[*function_index].name == *target {
                        functions[*function_index].visibility = Some(event.visibility.clone());
                        break;
                    }
                }
            }
        }
    }
}
