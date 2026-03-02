import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

export default defineConfig({
  plugins: [react()],
  base: "/admin/",
  build: {
    outDir: "../backend/internal/handler/static/admin",
    emptyOutDir: true,
  },
  server: {
    proxy: {
      "/v1": "http://localhost:9847",
    },
  },
});
