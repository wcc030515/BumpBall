import{build}from'esbuild';
import fs from'node:fs/promises';
import path from'node:path';
import{fileURLToPath}from'node:url';
const root=path.dirname(fileURLToPath(import.meta.url));
await fs.mkdir(path.join(root,'dist'),{recursive:true});
await build({entryPoints:[path.join(root,'src/index.js')],outfile:path.join(root,'dist/index.js'),bundle:true,packages:'external',platform:'node',target:'node22',format:'esm',sourcemap:false,legalComments:'eof',logLevel:'info'});
await fs.copyFile(path.join(root,'../public/assets/native/island/stage_geometry.json'),path.join(root,'dist/stage_geometry.json'));
console.log('Built authoritative BumpBall service and its approved island collision geometry.');
