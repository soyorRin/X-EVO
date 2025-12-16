# X-Evo / xPhone（x-evo-unified）

一个“类手机”交互形态的本地自托管应用：前端为 Vue3 + Vite（支持 PWA / Capacitor Android），后端为 Node.js + Express，提供 AI 角色聊天、Agent 执行、知识库/记忆库、共享池、游戏中心、音乐/天气等模块，并通过 PostgreSQL（含 pgvector）+ Redis 做持久化与缓存。

> 说明：项目包含授权校验逻辑；未获得有效租约时，大部分 `/api/*` 接口会返回 403，前端会跳转到未授权页面。

---

## 功能概览（按模块）

- **聊天与角色**：角色/群聊、会话设置、记忆库（Memory Bank）、提示词（Prompts）、知识库（Knowledge Base）、正则管理等。
- **Agent**：脚本、计划/调度、执行日志与事件订阅（后端含定时任务与事件总线）。
- **世界/世界观**：World Tick（每分钟）、世界观管理（事件/地点等）。
- **游戏中心（H5 游戏）**：上传/安装 ZIP，iframe 容器 + 运行时 SDK，支持与聊天互通。
- **音乐**：后端可内嵌网易云音乐 API 服务并通过 `/music-api` 代理；前端提供播放与歌单等。
- **TTS**：语音合成配置与生成（产物输出到 `storage/tts`）。
- **论坛/社交**：论坛内容、通知、延迟发布检查（定时任务）。
- **MCP / WebSocket**：提供 `/api/mcp`（需授权）与 `/api/ws`（WebSocket）端点。
- **第三方代理**：Imgur、Amap（高德）等通过后端代理，避免前端直连与跨域问题。

---

## 技术栈

- **前端**：Vue 3、Vite、Pinia、Vue Router、Sass、PWA（`vite-plugin-pwa`）
- **后端**：Node.js、Express、ws、node-cron
- **数据**：PostgreSQL（pgvector）、Redis（可选但建议）
- **其他**：MCP SDK（Streamable HTTP）、Live2D（通过代理拉取 `live2dcubismcore.min.js`）

---

## 目录结构（摘选）

- `src/`：前端（`Phone/`、`World/`、`Agent/` 等模块）
- `server/`：后端（路由 `server/routes.js`，入口 `server/index.js`）
- `server/data/`：数据库连接、初始化、迁移、默认数据等
- `storage/`：运行期文件（头像、游戏、TTS、主题资源等），会通过后端以 `/storage` 对外提供静态访问
- `data/`：运行期数据文件（如实例 ID 等）
- `docs/`：项目文档（例如游戏中心开发指南）

---

## 本地开发（推荐）

### 1) 准备环境

- Node.js 20+
- Docker（推荐，用于一键启动 PostgreSQL + Redis）

### 2) 配置环境变量

项目会从应用根目录的 `.env` 读取配置（后端连接 DB/Redis，前端构建时也会读取部分 `VITE_*` 变量）。

你至少需要配置：

- `DATABASE_URL`：PostgreSQL 连接串（建议使用 `pgvector/pgvector:pg15`）
- `REDIS_URL`：Redis 连接串（未配置会禁用缓存）

常用可选项：

- `PORT` / `HOST`：后端监听地址（默认 `127.0.0.1:3001`）
- `MUSIC_API_HOST` / `MUSIC_API_PORT`：内嵌音乐服务监听地址（默认 `127.0.0.1:30488`）
- `MUSIC_API_DISABLE=1`：禁用内嵌音乐服务
- `XEVO_APP_ROOT`（或 `APP_ROOT`）：指定应用根目录（会影响 `storage/`、`data/`、`.env` 的查找位置）

> 安全提示：不要在公开仓库提交真实口令/密钥；建议为本机开发单独设置账户与密码。

### 3) 启动依赖（Postgres + Redis）

```bash
docker compose up -d postgres redis
```

### 4) 安装依赖并启动

```bash
npm install
npm run dev
```

- 前端：Vite 默认监听 `https://localhost:5173`（自签名证书，浏览器需允许继续访问）
- 后端：默认 `http://127.0.0.1:3001`
- 代理：前端开发服务器会将 `/api`、`/storage`、`/music-api`、`/imgur-api`、`/api/amap` 等转发到后端（见 `vite.config.js`）

### 5) 授权状态

- 前端会在启动时调用 `GET /api/auth/status`，并在前端本地使用 `VITE_LICENSE_PUBLIC_KEY` 对租约 JWT 做验签。
- 未授权时会跳转到未授权页（`src/Phone/App/core/views/Unauthorized.vue`），并阻止访问大部分页面/接口。

---

## 生产部署

### 方式 A：直接运行（推荐自托管）

```bash
npm install
npm run build
npm run start
```

`npm run start` 会以 `NODE_ENV=production` 启动后端，并在同一端口（默认 `3001`）托管前端构建产物（`dist/`）。

### 方式 B：Docker 镜像

仓库提供了 `Dockerfile`（构建前端后将 `dist/` 与 `server/` 打包进运行镜像）。你仍需要外部的 PostgreSQL 与 Redis。

---

## 常用脚本

来自 `package.json`：

- `npm run dev`：同时启动后端（watch）与前端（Vite）
- `npm run build`：构建前端到 `dist/`
- `npm run start`：生产模式启动后端（并托管 `dist/`）
- `npm run build:backend-obf`：混淆并输出后端产物（见 `scripts/build-backend-obf.mjs`）
- `npm run build:backend-termux-bin`：生成 Termux 发行包/启动器（用于 Android/Termux 环境）

---

## 端口与接口速查

- 后端健康检查：`GET /api/health`
- 授权状态：`GET /api/auth/status`；激活：`POST /api/license/activate`
- WebSocket：`ws://<host>:<port>/api/ws`
- MCP：`http://<host>:<port>/api/mcp`（需授权）
- 静态资源：`/storage/*`（运行期文件），生产模式下还会托管 `dist/`

---

## 游戏中心开发

如果你要为 xPhone 的游戏中心分发/嵌入 HTML5 游戏，请先阅读：

- `docs/GameCenterDeveloperGuide.md`

该文档覆盖：ZIP 结构与 `game.json` manifest、运行时 SDK（`/games/sdk.js`）、与聊天互通能力、Dev Game Devkit 本地调试、以及后端 API 速查。

---

## 许可与安全（开发者提示）

- 后端提供豆包逆向等能力（内置浏览器登录方式），请优先使用合规/官方渠道并自行承担相关风险。
- 运行目录会产生 `storage/` 与 `data/`，请确保具备读写权限并做好备份策略（数据库同理）。
