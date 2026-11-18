import { defineConfig } from 'vite';
import { cpSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { resolve, join } from 'node:path';

let outputDirectory = fileURLToPath(new URL('./dist/', import.meta.url));

export default defineConfig({
  base: '/ball-island/',
  publicDir: false,
  plugins: [{
    name: 'approved-native-assets',
    configResolved(config) {
      outputDirectory = resolve(config.root, config.build.outDir);
    },
    closeBundle() {
      cpSync(fileURLToPath(new URL('./public/assets/native/', import.meta.url)),
        join(outputDirectory, 'assets/native'), { recursive: true });
      cpSync(fileURLToPath(new URL('./public/licenses/', import.meta.url)),
        join(outputDirectory, 'licenses'), { recursive: true });
      cpSync(fileURLToPath(new URL('./public/THIRD_PARTY_NOTICES.txt', import.meta.url)),
        join(outputDirectory, 'THIRD_PARTY_NOTICES.txt'));
    },
    // Development serves the same public directory; production copies only the
    // approved assets, so legacy prototypes never enter the delivered runtime.
    configureServer(server) {
      server.middlewares.use('/ball-island/assets/native', async (req, res, next) => {
        const { readFile } = await import('node:fs/promises');
        const { resolve, sep, extname } = await import('node:path');
        const root = fileURLToPath(new URL('./public/assets/native/', import.meta.url));
        let name: string;
        try { name = resolve(root, '.' + decodeURIComponent(new URL(req.url || '/', 'http://localhost').pathname)); }
        catch { next(); return; }
        if (!name.startsWith(root.endsWith(sep) ? root : root + sep)) { next(); return; }
        try {
          const data = await readFile(name);
          res.setHeader('Content-Type', ({ '.ogg':'audio/ogg', '.mp3':'audio/mpeg', '.wav':'audio/wav', '.glb': 'model/gltf-binary', '.svg': 'image/svg+xml', '.json': 'application/json', '.webp': 'image/webp', '.png': 'image/png' } as Record<string,string>)[extname(name)] || 'application/octet-stream');
          res.end(data);
        } catch { next(); }
      });
    },
  }],
  build: {
    target: 'es2022',
    chunkSizeWarningLimit: 3500,
    rollupOptions: { output: { inlineDynamicImports: true } },
  },
  server: { proxy: { '/services/bumpball': { target: 'http://127.0.0.1:54127', ws: true } } },
});
