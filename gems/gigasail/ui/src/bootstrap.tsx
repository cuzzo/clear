import { StrictMode } from "react";
import { createRoot } from "react-dom/client";
import { App } from "./App";

export function mountApplication(container: Element | null): void {
  if (!(container instanceof HTMLElement)) {
    throw new Error("Lineage UI requires an HTML root element");
  }

  createRoot(container).render(
    <StrictMode>
      <App />
    </StrictMode>,
  );
}
