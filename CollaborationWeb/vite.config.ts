import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
export default defineConfig({
  plugins: [react()],
  build: { target: 'safari16', assetsInlineLimit: Infinity, cssCodeSplit: false, rollupOptions: { output: { inlineDynamicImports: true } } },
  server: { port: 5179, strictPort: true, fs: { allow: ['..'] } },
});
