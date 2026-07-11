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

  const linePanelClass = (input) => {
    if (input.dataset.panelClass) return input.dataset.panelClass;
    if (input.classList.contains("bug-toggle")) return "bug-open";
    if (input.classList.contains("meta-toggle")) return "meta-open";
    if (input.classList.contains("decomplex-toggle")) return "decomplex-open";
    return null;
  };

  const syncLinePanelState = (input) => {
    const row = input.closest(".row");
    const klass = linePanelClass(input);
    if (row && klass) row.classList.toggle(klass, input.checked);
  };

  const bindLineToggle = (input) => {
    syncLinePanelState(input);
    input.addEventListener("change", () => syncLinePanelState(input));
  };

  const bindLineToggleLabel = (label) => {
    label.addEventListener("click", (event) => {
      const input = document.getElementById(label.htmlFor);
      if (!input || !input.classList.contains("line-toggle")) return;
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

  const setFnFoldRows = (input) => {
    const foldId = input.dataset.foldId;
    const sourceView = input.closest(".source-view");
    const row = input.closest(".row");
    if (row) {
      row.classList.toggle("fn-fold-collapsed", input.checked);
      row.classList.toggle("fn-fold-expanded", !input.checked);
    }
    if (!foldId || !sourceView) return;
    sourceView
      .querySelectorAll(`[data-fn-fold-child="${foldId}"]`)
      .forEach((row) => row.classList.toggle("fn-fold-hidden", input.checked));
  };

  const restoreFnFold = (input) => {
    const key = input.dataset.persistKey;
    const stored = key ? read(key) : null;
    if (stored === null) {
      if (input.classList.contains("private-fn-fold")) {
        const privateFoldingLayer = document.getElementById("layer-private-folding");
        input.checked = privateFoldingLayer ? privateFoldingLayer.checked : true;
      } else {
        input.checked = false;
      }
    } else {
      input.checked = (stored === "true");
    }
    input.addEventListener("change", () => {
      if (key) write(key, String(input.checked));
      setFnFoldRows(input);
    });
    setFnFoldRows(input);
  };

  const restoreWarningDismissal = (control) => {
    const key = control.dataset.dismissKey;
    const warning = control.closest(".warning");
    const input = control.htmlFor ? document.getElementById(control.htmlFor) : null;
    if (!key || !warning) return;
    if (read(key) === "true") {
      if (input) input.checked = true;
      warning.hidden = true;
    }
    control.addEventListener("click", () => {
      write(key, "true");
      setTimeout(() => {
        if (input) input.checked = true;
        warning.hidden = true;
      }, 0);
    });
  };

  const definitionPromises = new Map(); // name -> Promise<boolean>

  const checkClickable = (name) => {
    if (definitionPromises.has(name)) {
      return definitionPromises.get(name);
    }
    const promise = (async () => {
      try {
        const urlParams = new URLSearchParams(window.location.search);
        const commit = urlParams.get("commit") || "";
        const path = urlParams.get("path") || "";
        const res = await fetch(`/api/definition?name=${encodeURIComponent(name)}&commit=${encodeURIComponent(commit)}&path=${encodeURIComponent(path)}`);
        if (res.ok) {
          const data = await res.json();
          return data && data.length > 0;
        }
      } catch (_e) {}
      return false;
    })();
    definitionPromises.set(name, promise);
    return promise;
  };

  const setupClickableTokens = () => {
    const tokens = document.querySelectorAll(".tok-function, .tok-type");
    tokens.forEach((token) => {
      const name = token.textContent.trim();
      if (!name) return;

      token.addEventListener("mouseenter", async () => {
        const isClickable = await checkClickable(name);
        if (isClickable) {
          token.classList.add("clickable");
        }
      });

      token.addEventListener("click", async () => {
        const isClickable = await checkClickable(name);
        if (!isClickable) return;
        try {
          const urlParams = new URLSearchParams(window.location.search);
          const commit = urlParams.get("commit") || "";
          const path = urlParams.get("path") || "";
          const res = await fetch(`/api/definition?name=${encodeURIComponent(name)}&commit=${encodeURIComponent(commit)}&path=${encodeURIComponent(path)}`);
          if (res.ok) {
            const data = await res.json();
            if (data && data.length > 0) {
              const match = data[0];
              const commitArg = commit ? `&commit=${encodeURIComponent(commit)}` : "";
              window.location.href = `/?path=${encodeURIComponent(match.path)}${commitArg}#L${match.line}`;
            }
          }
        } catch (_e) {}
      });
    });
  };

  const setupDashboardSectionSwitchers = () => {
    document.querySelectorAll("[data-dashboard-section-switcher]").forEach((switcher) => {
      const buttons = Array.from(switcher.querySelectorAll("[data-dashboard-panel]"));
      const panels = buttons
        .map((button) => document.getElementById(button.dataset.dashboardPanel))
        .filter(Boolean);
      if (!buttons.length || panels.length !== buttons.length) return;

      const select = (button, allowCollapse) => {
        const panel = document.getElementById(button.dataset.dashboardPanel);
        const collapse = allowCollapse && button.classList.contains("active") && panel.open;
        buttons.forEach((candidate) => {
          candidate.classList.remove("active");
          candidate.setAttribute("aria-selected", "false");
        });
        panels.forEach((candidate) => { candidate.open = false; });
        if (collapse) return;
        button.classList.add("active");
        button.setAttribute("aria-selected", "true");
        panel.open = true;
      };

      buttons.forEach((button, index) => {
        button.id ||= `dashboard-section-tab-${index}`;
        const panel = document.getElementById(button.dataset.dashboardPanel);
        panel.setAttribute("role", "tabpanel");
        panel.setAttribute("aria-labelledby", button.id);
        button.addEventListener("click", () => select(button, true));
        button.addEventListener("keydown", (event) => {
          let target = null;
          if (event.key === "ArrowRight") target = buttons[(index + 1) % buttons.length];
          if (event.key === "ArrowLeft") target = buttons[(index - 1 + buttons.length) % buttons.length];
          if (event.key === "Home") target = buttons[0];
          if (event.key === "End") target = buttons[buttons.length - 1];
          if (!target) return;
          event.preventDefault();
          target.focus();
          select(target, false);
        });
      });
      switcher.classList.add("is-enhanced");
      select(buttons[0], false);
    });
  };

  const setupArchitectureView = () => {
    const search = document.querySelector("[data-architecture-search]");
    if (search) {
      search.addEventListener("input", () => {
        const query = search.value.trim().toLowerCase();
        document.querySelectorAll(".architecture-member").forEach((member) => {
          member.hidden = query && !String(member.dataset.memberName || "").toLowerCase().includes(query);
        });
      });
    }
    const relationshipSearch = document.querySelector("[data-relationship-search]");
    if (relationshipSearch) {
      relationshipSearch.addEventListener("input", () => {
        const query = relationshipSearch.value.trim().toLowerCase();
        document.querySelectorAll("[data-relationship-row]").forEach((row) => {
          row.hidden = query && !row.textContent.toLowerCase().includes(query);
        });
      });
    }
    document.querySelectorAll("[data-architecture-fit]").forEach((button) => {
      button.addEventListener("click", () => {
        const viewport = button.closest(".architecture-focus")?.querySelector(".architecture-graph-viewport");
        if (viewport) viewport.scrollTo({ left: 0, top: 0, behavior: "smooth" });
      });
    });
    const graphLinks = Array.from(document.querySelectorAll(".architecture-graph a"));
    graphLinks.forEach((link, index) => {
      link.addEventListener("keydown", (event) => {
        if (!['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown'].includes(event.key)) return;
        event.preventDefault();
        const delta = event.key === 'ArrowLeft' || event.key === 'ArrowUp' ? -1 : 1;
        graphLinks[(index + delta + graphLinks.length) % graphLinks.length]?.focus();
      });
    });
  };

  document.addEventListener("DOMContentLoaded", () => {
    document
      .querySelectorAll("input[data-persist-key]:not(.comment-fold-toggle):not(.fn-fold-toggle)")
      .forEach(restoreInput);
    document.querySelectorAll(".comment-fold-toggle[data-persist-key]").forEach(restoreCommentFold);
    document.querySelectorAll(".fn-fold-toggle[data-persist-key]").forEach(restoreFnFold);

    const privateFoldingLayer = document.getElementById("layer-private-folding");
    if (privateFoldingLayer) {
      privateFoldingLayer.addEventListener("change", () => {
        document.querySelectorAll(".private-fn-fold").forEach(input => {
          const key = input.dataset.persistKey;
          const stored = key ? read(key) : null;
          if (stored === null) {
            input.checked = privateFoldingLayer.checked;
            input.dispatchEvent(new Event("change", { bubbles: true }));
          }
        });
      });
    }

    document.querySelectorAll(".warning-dismiss[data-dismiss-key]").forEach(restoreWarningDismissal);
    document.querySelectorAll(".layers-panel label[for]").forEach(bindLayerLabel);
    document.querySelectorAll(".line-toggle").forEach(bindLineToggle);
    document.querySelectorAll(".gutter .line-icon[for]").forEach(bindLineToggleLabel);
    setupDashboardSectionSwitchers();
    setupClickableTokens();
    setupArchitectureView();
  });
})();
