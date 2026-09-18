import { sep } from 'node:path'
import { defineConfig } from 'vite'
import vue from '@vitejs/plugin-vue'
import tailwindcss from '@tailwindcss/vite'
import { VitePWA } from 'vite-plugin-pwa'

export default defineConfig({
  plugins: [
    vue(),
    tailwindcss(),
    VitePWA({
      registerType: 'autoUpdate',
      includeAssets: ['favicon.svg'],
      manifest: {
        name: 'timing.runXC.run',
        short_name: 'runXC',
        description: 'Cross country race timing — setup, registration, finish line, team scores.',
        theme_color: '#0b1220',
        background_color: '#0b1220',
        display: 'standalone',
        start_url: '/',
        icons: [
          { src: 'icons/icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icons/icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'icons/icon-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        globPatterns: ['**/*.{js,css,html,svg,png,woff2,wasm}'],
        navigateFallback: '/index.html',
        navigateFallbackDenylist: [/^\/api\//],
        runtimeCaching: [
          {
            // Never cache Supabase API responses; the app syncs explicitly.
            urlPattern: ({ url }) => url.hostname.includes('supabase') || url.port === '54321' || url.port === '8000',
            handler: 'NetworkOnly',
          },
        ],
      },
    }),
  ],
  server: {
    port: 8080,
    strictPort: true,
    watch: {
      // Local Postgres data (aspire/infra) and tooling output churn inside the
      // project root and must not trigger HMR reloads. A predicate is used
      // instead of globs because chokidar matches absolute paths here, and a
      // mid-race page reload of the timing console is unacceptable.
      ignored: (path: string) =>
        path.includes('node_modules') ||
        path.includes(`${sep}aspire${sep}`) ||
        path.includes('.playwright-mcp') ||
        path.includes(`${sep}dist${sep}`),
    },
  },
  preview: {
    port: 8080,
    strictPort: true,
  },
  build: {
    // zxing wasm worker chunks
    target: 'es2022',
  },
})
