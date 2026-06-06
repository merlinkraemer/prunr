import { defineConfig } from 'vite'

// The page transpiles JSX in the browser via Babel standalone (script type="text/babel"),
// so coming-soon.jsx isn't part of Vite's module graph. Force a full page reload whenever
// any source file changes so hot-reload still works.
export default defineConfig({
  server: {
    port: 5180,   // strictPort defaults to false → Vite auto-picks the next free port
    open: true,   // open the page in the default browser on start
  },
  plugins: [
    {
      name: 'full-reload-on-change',
      handleHotUpdate({ server, file }) {
        if (/\.(jsx|js|css|html|png)$/.test(file)) {
          server.ws.send({ type: 'full-reload' })
          return []
        }
      },
    },
  ],
})
