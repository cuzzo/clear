(() => {
  let storage = null;
  try {
    storage = window.localStorage;
  } catch (_error) {
    storage = null;
  }

  const read = (key) => {
    if (!storage) return null;
    try {
      return storage.getItem(key);
    } catch (_error) {
      return null;
    }
  };

  const write = (key, value) => {
    if (!storage) return;
    try {
      storage.setItem(key, value);
    } catch (_error) {
      // Ignore private-mode or quota failures; controls still work per page.
    }
  };

  const syncInputState = (input) => {
    const sourceView = input.closest(".source-view");
    if (sourceView && input.classList.contains("layer-toggle")) {
      sourceView.classList.toggle(`${input.id}-on`, input.checked);
    }
  };

  const restoreInput = (input) => {
    const key = input.dataset.persistKey;
    const stored = key ? read(key) : null;
    if (input.type === "radio") {
      if (stored === input.id) input.checked = true;
      input.addEventListener("change", () => {
        if (input.checked && key) write(key, input.id);
        syncInputState(input);
      });
    } else {
      if (stored === "true") input.checked = true;
      if (stored === "false") input.checked = false;
      input.addEventListener("change", () => {
        if (key) write(key, String(input.checked));
        syncInputState(input);
      });
    }
    syncInputState(input);
  };

  const bindLayerLabel = (label) => {
    label.addEventListener("click", (event) => {
      const input = document.getElementById(label.htmlFor);
      if (!input || input.type !== "checkbox") return;
      event.preventDefault();
      input.checked = !input.checked;
      input.dispatchEvent(new Event("change", { bubbles: true }));
    });
  };

  const setFoldRows = (input) => {
    const foldId = input.dataset.foldId;
    const sourceView = input.closest(".source-view");
    const row = input.closest(".row");
    if (row) {
      row.classList.toggle("comment-fold-collapsed", input.checked);
      row.classList.toggle("comment-fold-expanded", !input.checked);
    }
    if (!foldId || !sourceView) return;
    sourceView
      .querySelectorAll(`[data-comment-fold-child="${foldId}"]`)
      .forEach((row) => row.classList.toggle("comment-fold-hidden", input.checked));
  };

  const restoreCommentFold = (input) => {
    restoreInput(input);
    setFoldRows(input);
    input.addEventListener("change", () => setFoldRows(input));
  };

  const restoreWarningDismissal = (button) => {
    const key = button.dataset.dismissKey;
    const warning = button.closest(".warning");
    if (!key || !warning) return;
    if (read(key) === "true") warning.hidden = true;
    button.addEventListener("click", () => {
      write(key, "true");
      warning.hidden = true;
    });
  };

  document.addEventListener("DOMContentLoaded", () => {
    document
      .querySelectorAll("input[data-persist-key]:not(.comment-fold-toggle)")
      .forEach(restoreInput);
    document.querySelectorAll(".comment-fold-toggle[data-persist-key]").forEach(restoreCommentFold);
    document.querySelectorAll(".warning-dismiss[data-dismiss-key]").forEach(restoreWarningDismissal);
    document.querySelectorAll(".layers-panel label[for]").forEach(bindLayerLabel);
  });
})();
