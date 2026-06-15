(() => {
  const storage = window.localStorage;
  if (!storage) return;

  const read = (key) => {
    try {
      return storage.getItem(key);
    } catch (_error) {
      return null;
    }
  };

  const write = (key, value) => {
    try {
      storage.setItem(key, value);
    } catch (_error) {
      // Ignore private-mode or quota failures; controls still work per page.
    }
  };

  const restoreInput = (input) => {
    const key = input.dataset.persistKey;
    if (!key) return;
    const stored = read(key);
    if (input.type === "radio") {
      if (stored === input.id) input.checked = true;
      input.addEventListener("change", () => {
        if (input.checked) write(key, input.id);
      });
    } else {
      if (stored === "true") input.checked = true;
      if (stored === "false") input.checked = false;
      input.addEventListener("change", () => write(key, String(input.checked)));
    }
  };

  const setFoldRows = (input) => {
    const foldId = input.dataset.foldId;
    const sourceView = input.closest(".source-view");
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
    const warning = button.closest("[data-dismiss-key]");
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
  });
})();
