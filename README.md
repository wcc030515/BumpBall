# 海岛碰碰球 · BumpBall

[公开试玩](https://wcc030515.github.io/BumpBall/?v=resize-20261118)

Q 版动物踩球竞技：将其他选手撞出小岛，最后留在岛上的选手获胜。八种动物支持主色自定义，单人模式包含不同属性的 NPC 和七种互动事件。

## 本地运行

需要 Node.js 22.12 或更新版本，推荐 Node.js 24。

```sh
npm ci
npm run dev
```

开发页面为 http://localhost:5173/ball-island/。WASD / 方向键移动，Esc / P 暂停或继续；音量和暂停按钮位于右下角。

运行完整本地服务：

```sh
npm --prefix server ci
npm run check
npm run build:all
npm start
```

页面默认地址 http://localhost:54127/ball-island/。联机开发时另行启动服务，Vite 将 /services/bumpball 请求转发到它。

## GitHub Pages 与联机

推送 main 分支后，GitHub Actions 构建并仅发布 dist/ 中的静态前端和必要素材。Pages 构建使用 /BumpBall/ 路径，关闭 QA 入口；本地开发仍使用 /ball-island/。

2–4 人联机由独立的 Node.js / Colyseus 权威服务提供，GitHub Pages 不运行该后端。工作流通过 VITE_MULTIPLAYER_URL 连接现有独立服务 https://boe-gyl-vibe-games-ws.bytedance.net/services/bumpball；发布前当前开发环境的健康检查正常，但未验证所有公网环境的可达性，不能据此保证所有访客均可联机。单人模式无需该服务。

自行部署联机服务时，在 server/ 安装生产依赖，构建后运行 node server/dist/index.js；HOST、PORT 和 BUMPBALL_STATIC_DIR 可配置监听与静态目录。前端使用 HTTPS 时，独立后端也必须支持 HTTPS/WSS。

## 仓库内容

- src/：渲染、物理、AI、UI、音频与联机客户端。
- public/assets/native/：实际使用的模型、动作、贴图及音频。
- server/src/、server/build.mjs、server/package*.json：独立联机服务源码与构建配置。
- public/licenses/、public/THIRD_PARTY_NOTICES.txt：第三方许可与素材来源。

仅保留游戏源码、必要素材和构建发布配置；不包含制作工程、测试与调试脚本、截图、预览页、日志或安装包。
