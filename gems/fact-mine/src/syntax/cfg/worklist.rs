use std::collections::BTreeMap;

/// Deterministic fixed-point driver shared by forward and backward analyses.
/// The caller supplies dependency order and the lattice transfer/join step.
pub(crate) fn solve<K, V, F>(order: &[K], state: &mut BTreeMap<K, V>, mut next: F)
where
    K: Clone + Ord,
    V: Eq,
    F: FnMut(&K, &BTreeMap<K, V>) -> V,
{
    loop {
        let mut changed = false;
        for key in order {
            let value = next(key, state);
            if state.get(key) != Some(&value) {
                state.insert(key.clone(), value);
                changed = true;
            }
        }
        if !changed {
            return;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn converges_over_a_cycle() {
        let order = vec!["a", "b", "c"];
        let mut state = BTreeMap::from([("a", 1_u8), ("b", 0), ("c", 0)]);
        solve(&order, &mut state, |key, values| match *key {
            "a" => 1,
            "b" => values["a"],
            "c" => values["b"],
            _ => 0,
        });
        assert_eq!(state.values().copied().collect::<Vec<_>>(), vec![1, 1, 1]);
    }
}
