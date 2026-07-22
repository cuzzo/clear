import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  test: {
    coverage: {
      all: true,
      exclude: ["src/vite-env.d.ts"],
      include: ["src/**/*.{ts,tsx}"],
      provider: "v8",
      thresholds: {
        lines: 98,
      },
    },
    environment: "jsdom",
    setupFiles: ["./src/test/setup.ts"],
  },
});
