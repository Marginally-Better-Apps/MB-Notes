import { defineConfig } from '@playwright/test';
export default defineConfig({
  testDir: './e2e', timeout: 90000, workers: 1,
  use: { baseURL: process.env.MB_DEMO_URL || 'http://localhost:5179', headless: true, viewport: { width: 1280, height: 900 }, screenshot: 'only-on-failure', trace: 'retain-on-failure',
    launchOptions: process.env.MB_CHROMIUM ? { executablePath: process.env.MB_CHROMIUM } : undefined },
  webServer: process.env.MB_DEMO_URL ? undefined : { command: 'python3 -m http.server 5179 --directory dist', url: 'http://localhost:5179', reuseExistingServer: true },
});
