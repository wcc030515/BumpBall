import {defineConfig} from 'vite';
export default defineConfig({
  base: './',
  build: {target:'es2022',sourcemap:false,chunkSizeWarningLimit:3500,rollupOptions:{output:{inlineDynamicImports:true}}},
  server: {proxy:{'/ws':{target:'ws://127.0.0.1:54127',ws:true}}},
});
