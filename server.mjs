import http from 'node:http';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { randomBytes } from 'node:crypto';
import { WebSocketServer, WebSocket } from 'ws';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), 'dist');
const port = Number(process.env.PORT || 54127);
const gameIdentity = { appId: 'ball-island-survival', name: '海岛碰碰球', version: '2.0.0-web', sourceVersion: 'Godot 1.0.27', entry: '/ball-island/', assetRevision: 'audio-confusion-v2' };
const rooms = new Map();
const mime = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.wasm': 'application/wasm',
  '.png': 'image/png', '.jpg': 'image/jpeg', '.jpeg': 'image/jpeg', '.webp': 'image/webp',
  '.svg': 'image/svg+xml', '.glb': 'model/gltf-binary', '.gltf': 'model/gltf+json',
  '.bin': 'application/octet-stream', '.ico': 'image/x-icon', '.mp3': 'audio/mpeg', '.ogg':'audio/ogg', '.wav':'audio/wav',
};

const server = http.createServer((req, res) => {
  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD' }); res.end(); return;
  }
  let pathname;
  try { pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname); }
  catch { res.writeHead(400); res.end('Bad request'); return; }
  if (pathname === '/ball-island/health') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store', 'X-Game-Id': gameIdentity.appId });
    res.end(req.method === 'HEAD' ? undefined : JSON.stringify(gameIdentity)); return;
  }
  if (pathname === '/' || pathname === '/ball-island') {
    res.writeHead(302, { Location: '/ball-island/' + new URL(req.url, 'http://localhost').search, 'Cache-Control': 'no-store' }); res.end(); return;
  }
  if (pathname === '/ball-island/play.html') {
    res.writeHead(302, { Location: '/ball-island/' + new URL(req.url, 'http://localhost').search, 'Cache-Control': 'no-store' }); res.end(); return;
  }
  if (pathname.startsWith('/ball-island/')) pathname = pathname.slice('/ball-island'.length);
  if (pathname === '/') pathname = '/index.html';
  const target = path.resolve(root, `.${pathname}`);
  if (target !== root && !target.startsWith(root + path.sep)) {
    res.writeHead(403); res.end('Forbidden'); return;
  }
  fs.stat(target, (error, stat) => {
    if (error || !stat.isFile()) {
      res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' });
      res.end('未找到游戏文件。请先执行 npm run build，再执行 npm start。'); return;
    }
    res.writeHead(200, {
      'Content-Type': mime[path.extname(target).toLowerCase()] || 'application/octet-stream',
      'Content-Length': stat.size,
      'Cache-Control': path.extname(target) === '.html' ? 'no-store' : 'public, max-age=3600',
      'X-Game-Id': gameIdentity.appId,
      'X-Content-Type-Options': 'nosniff',
    });
    if (req.method === 'HEAD') res.end();
    else fs.createReadStream(target).pipe(res);
  });
});

const wss = new WebSocketServer({ server, path: '/ws', maxPayload: 8 * 1024 * 1024 });
const send = (ws, value) => {
  if (ws?.readyState === WebSocket.OPEN && ws.bufferedAmount < 4 * 1024 * 1024) ws.send(JSON.stringify(value));
};
const error = (ws, message) => send(ws, { type: 'error', message });
const effectKinds = new Set(['grow', 'shrink', 'speedUp', 'speedDown', 'wind', 'airdrop', 'confusion']);
const color = value => typeof value === 'string' && /^#[a-fA-F0-9]{6}$/.test(value);
function appearance(input) {
  const colors = Array.isArray(input?.colors) ? input.colors.filter(color).slice(0, 3) : [];
  while (colors.length < 3) colors.push(['#f6be69', '#fff0cc', '#e97e53'][colors.length]);
  const image = typeof input?.image === 'string' && input.image.length < 2_500_000 && /^data:image\/(png|jpeg|webp);base64,/.test(input.image) ? input.image : undefined;
  return { colors, ...(image ? { image } : {}) };
}
function config(input, role) {
  return {
    id: role, name: String(input?.name || (role === 'host' ? '玩家一' : '玩家二')).slice(0, 24),
    animal: ['rabbit', 'bear', 'hamster', 'cat', 'dog', 'fox', 'panda', 'raccoon'].includes(input?.animal) ? input.animal : 'rabbit',
    character: appearance(input?.character), ball: appearance(input?.ball), human: true,
  };
}
function leave(ws) {
  const room = rooms.get(ws.roomCode);
  if (!room) { ws.roomCode = null; return; }
  if (room.host === ws) {
    send(room.guest, { type: 'peer-left', message: '房主已离开，比赛已中止' });
    if (room.guest) room.guest.roomCode = null;
    rooms.delete(ws.roomCode);
  } else if (room.guest === ws) {
    room.guest = null;
    room.guestConfig = null;
    room.started = false;
    send(room.host, { type: 'peer-left', message: '另一位主播已离开，比赛已中止' });
  }
  ws.roomCode = null;
}
function createCode() {
  let code;
  do { code = randomBytes(3).toString('hex').toUpperCase(); } while (rooms.has(code));
  return code;
}

wss.on('connection', ws => {
  ws.alive = true;
  ws.roomCode = null;
  ws.rateAt = Date.now();
  ws.rateCount = 0;
  ws.on('pong', () => { ws.alive = true; });
  ws.on('message', raw => {
    let message;
    try { message = JSON.parse(raw.toString()); } catch { error(ws, '无效消息'); return; }
    if (!message || typeof message.type !== 'string') return;
    const now = Date.now();
    if (now - ws.rateAt > 1000) { ws.rateAt = now; ws.rateCount = 0; }
    if (++ws.rateCount > 140) return;
    if (message.type === 'create') {
      leave(ws);
      if (rooms.size >= 200) { error(ws, '房间已满，请稍后再试'); return; }
      const code = createCode(), hostConfig = config(message.config, 'host');
      rooms.set(code, { host: ws, guest: null, hostConfig, guestConfig: null, started: false });
      ws.roomCode = code;
      send(ws, { type: 'room', code, role: 'host', hostConfig });
      return;
    }
    if (message.type === 'join') {
      const code = String(message.code || '').toUpperCase().trim();
      const room = rooms.get(code);
      if (!room) { error(ws, '房间不存在，请检查房间码'); return; }
      if (room.host === ws) { error(ws, '你已经是该房间的房主'); return; }
      if (room.guest) { error(ws, '房间已有两位主播'); return; }
      leave(ws);
      room.guest = ws;
      room.guestConfig = config(message.config, 'guest');
      ws.roomCode = code;
      send(ws, { type: 'room', code, role: 'guest', hostConfig: room.hostConfig, guestConfig: room.guestConfig });
      send(room.host, { type: 'peer-joined', config: room.guestConfig });
      return;
    }
    const room = rooms.get(ws.roomCode);
    if (!room) { error(ws, '请先创建或加入房间'); return; }
    const isHost = ws === room.host;
    if (message.type === 'start' && isHost) {
      if (!room.guest) { error(ws, '等待另一位主播加入后才能开赛'); return; }
      room.started = true;
      send(room.guest, { type: 'start', players: [room.hostConfig, room.guestConfig] });
    } else if (message.type === 'state' && isHost && room.started && message.snapshot) {
      send(room.guest, { type: 'state', snapshot: message.snapshot });
    } else if (message.type === 'input' && !isHost && room.started) {
      const x = Number(message.x), z = Number(message.z);
      if (Number.isFinite(x) && Number.isFinite(z)) send(room.host, { type: 'input', x: Math.max(-1, Math.min(1, x)), z: Math.max(-1, Math.min(1, z)) });
    } else if (message.type === 'effect' && !isHost && room.started && effectKinds.has(message.kind)) {
      if (typeof message.targetId === 'string' && message.targetId.length < 40) send(room.host, { type: 'effect', targetId: message.targetId, kind: message.kind });
    } else if (message.type === 'effect-result' && isHost && room.started) {
      send(room.guest, {
        type: 'effect-result', ok: Boolean(message.ok), message: String(message.message || '').slice(0, 100),
        targetId: String(message.targetId || '').slice(0, 40), kind: message.kind, actor: message.actor === 'guest' ? 'guest' : 'host',
      });
    } else if (message.type === 'pause' && room.started) {
      // Either participant can pause the same authoritative match. Never let one
      // browser continue while the other displays a frozen local overlay.
      send(isHost ? room.guest : room.host, { type: 'pause', paused: Boolean(message.paused) });
    } else if (message.type === 'leave') leave(ws);
  });
  ws.on('close', () => leave(ws));
  ws.on('error', () => {});
});

const heartbeat = setInterval(() => {
  for (const ws of wss.clients) {
    if (!ws.alive) { ws.terminate(); continue; }
    ws.alive = false;
    ws.ping();
  }
}, 30_000);
heartbeat.unref();
wss.on('close', () => clearInterval(heartbeat));
server.on('error', error => {
  console.error(error.code === 'EADDRINUSE' ? `端口 ${port} 已被其他服务占用。请使用“启动游戏.cmd”自动选择专属入口。` : error);
  process.exitCode = 1;
});
server.listen(port, '0.0.0.0', () => {
  console.log(`海岛碰碰球 HTML 版 http://127.0.0.1:${port}/ball-island/`);
  console.log(`局域网 PK：两台设备打开此电脑的局域网 IP:${port}，创建并加入同一个房间。`);
});
