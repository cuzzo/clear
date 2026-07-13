use super::*;

mod architecture;
mod assets;
mod index;
mod source;

pub(super) fn router(state: UiServerState) -> Router {
    Router::new()
        .merge(index::routes())
        .merge(source::routes())
        .merge(architecture::routes())
        .merge(assets::routes())
        .with_state(state)
}
