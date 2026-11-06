# 海岛碰碰球 · BumpBall

[公开试玩](https://wcc030515.github.io/BumpBall/)

Q 版动物踩球竞技：控制方向把其他选手撞出小岛，最后留在岛上的选手获胜。

## 游玩

- WASD / 方向键移动，Esc / P 暂停或继续。
- 八种动物可选，支持角色主色自定义；每局随机抽取不同属性的 NPC。
- 右侧七个按钮（数字键 1–7）模拟变大、变小、加速、减速、侧风、空降 NPC、方向混乱。
- 变大、变小、加速、减速为本局永久效果；侧风持续 3 秒并排队，方向混乱持续 3 秒且可叠加。
- 开局优先使用不同动物；开局或空降出现同种 NPC 时自动选取不同主色；玩家落败播放诙谐管乐，获胜播放海岛钢鼓，背景音乐默认关闭。

## 新版角色与贴图接缝

已接入确认的八个新版动物、五段骨骼动作、头像和主色换色层，保留小兔眼睛高光。角色底图与换色层使用匹配的防接缝线性采样，开始预览、比赛和空降NPC统一生效；原模型、骨骼及动作保持不变。3D渲染仍保持1920×1080像素预算。

## 本地开发

需要 Node.js 22.12 或更新版本，推荐 Node.js 24。

```sh
npm ci
npm run dev
```

## 构建和运行

```sh
npm run check
npm run build
npm start
```

本地完整服务默认地址为 http://localhost:54127/ball-island/，支持两名玩家创建或加入房间。

## GitHub Pages

推送 main 分支后，GitHub Actions 构建并仅发布 dist/ 内的游戏运行文件。
Pages 提供公开的单人模式、NPC 和互动按钮；联机房间需要独立运行 server.mjs 的 Node/WebSocket 服务，Pages 不运行该服务。

## 项目内容

- src/：Three.js 渲染、Rapier 物理、AI、交互、UI、音频和联机逻辑。
- public/assets/native/：实际使用的角色、动作、岛屿、贴图及音频。
- server.mjs：可独立部署的联机中继及静态文件服务。
- public/licenses/、public/THIRD_PARTY_NOTICES.txt：第三方许可与素材来源。

仓库当前版本仅保留 HTML 游戏源代码、必要素材和构建部署配置，不包含制作工程、测试代码、日志、截图、演示页或安装包。原 Godot 版本保留在 Git 提交历史中。
