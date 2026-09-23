# Personal DeepSeek — Development Notes

这是一个仅供个人签名安装的第一阶段可运行工程。它包含 iOS 17 SwiftUI 客户端与零运行时依赖的 Node.js 24/TypeScript 后端，严格以 [ARCHITECTURE.md](ARCHITECTURE.md) 为边界。

## 已实现

- SwiftData 本地会话和消息，多轮请求固定为 `system + 已排序历史 + 新消息`。
- 单一路由架构：聊天、图片理解、本地知识库和深度研究直接在 iPhone 上运行；DeepSeek 与搜索 API Key 只保存在 Keychain，源码、配置和日志均不包含密钥。
- 云端服务只承担定时任务、执行历史、配额护栏和 APNs；访问令牌保存在 Keychain，非回环地址启动时后端强制要求访问令牌。
- DeepSeek Chat Completions SSE，区分 `reasoning_content` 与 `content`，忽略空行和 `: keep-alive`，支持 CRLF、分片、usage 与 `[DONE]`。
- 流开始前的 429/5xx 有界指数退避；流中断显式报错，不自动重复生成；网络超时覆盖服务端十分钟未开始推理的边界。
- 模型名、thinking 和 reasoning effort 设置；思考内容折叠；系统 Markdown、复制和分享。
- 自然语言任务由 strict tool call 转成共享 Schema；客户端必须预览确认后才保存。
- 任务 CRUD、暂停/恢复、删除、到期执行、运行历史、最短一小时、每日次数、连续未读暂停、月预算降级到 `deepseek-flash` 与硬熔断。
- 多会话选择、新建、删除，以及会话级标题、模型名和自定义 system 指令。
- Dockerfile、Compose、持久化卷、健康检查、自动调度循环和 SIGINT/SIGTERM 优雅退出。
- JSON 文件持久化位于仓储接口之后，可替换为 PostgreSQL。后端没有 Key 仍可启动和响应健康检查。
- 后端保留兼容性的 Files/搜索/抓取接口，并实现定时任务、APNs 设备/Live Activity token 与通知状态；日常聊天与研究不依赖后端在线。
- iOS 相册多图、相机、附件预览/移除和 base64 `image_url`；文本/JSON 聊天附件，PDF 在知识库页用 PDFKit 提取文本。
- SwiftData 本地知识库创建、启停、导入、文件列表/删除和查询；聊天自动检索启用知识库，在本轮最后一条 user 消息前插入不可信引用上下文，从而保持既有 system+历史前缀稳定。
- 本地深度研究初版：Brave Search 搜索、并发 HTTPS 抓取、网页正文提取、本地知识库融合、DeepSeek 流式汇总与编号引用，全程由 iPhone 编排。
- WidgetKit 会话/任务摘要、生成与任务 Live Activity、App Group 离线快照，以及 iOS 26 AlarmKit 一次性/固定每周强提醒。

## 明确延期

完整 Markdown 表格/代码高亮/LaTeX、扫描 PDF OCR、CloudKit、StoreKit、App Intents、Share Extension，以及会根据证据缺口自动追加搜索词的多轮研究循环仍延期。知识库当前使用确定性词元哈希向量，只适合个人初版离线验证，语义质量不能替代生产 embedding 服务；JSON 仓储只适合单进程个人开发，生产多实例需换数据库和分布式租约。

## 后端

要求 Node.js 24。

```powershell
cd backend
npm install
npm test
npm run build
$env:DEEPSEEK_API_KEY="在本机临时设置，不要写入文件"
$env:INTERNAL_TOKEN="自行生成的本地调度令牌"
npm start
```

服务默认监听 `127.0.0.1:8787`。`GET /health` 不需要密钥；其他用户接口要求 `X-User-ID`，值必须是 8–128 位不透明随机标识。触发本地调度：

```powershell
Invoke-RestMethod -Method Post http://127.0.0.1:8787/v1/internal/tasks/run-due -Headers @{ Authorization = "Bearer $env:INTERNAL_TOKEN" }
```

可选环境变量：

| 变量 | 默认值 | 用途 |
|---|---|---|
| `PORT` | `8787` | HTTP 端口 |
| `HOST` | `127.0.0.1` | 监听地址；非回环地址必须配置访问令牌 |
| `DEEPSEEK_API_KEY` | 无 | 代理与任务执行密钥 |
| `APP_ACCESS_TOKEN` | 无 | iOS 访问代理使用的 Bearer Token |
| `DEEPSEEK_BASE_URL` | `https://api.deepseek.com` | 官方兼容地址 |
| `DEEPSEEK_BETA_BASE_URL` | `https://api.deepseek.com/beta` | strict Tool Calls 的 Beta 地址 |
| `DEEPSEEK_DEFAULT_MODEL` | `deepseek-flash` | 任务默认模型 |
| `DEEPSEEK_TASK_MODEL` | `deepseek-flash` | 自然语言任务解析模型 |
| `DATA_FILE` | `backend/data/store.json` | JSON 数据文件 |
| `INTERNAL_TOKEN` | 无 | 内部调度端点令牌；未配置时拒绝全部调用 |
| `ENABLE_SCHEDULER` | `false` | 是否在服务进程内每分钟触发到期任务 |
| `SCHEDULER_INTERVAL_SECONDS` | `60` | 自动调度扫描周期，最小 60 秒 |
| `DAILY_RUN_LIMIT` | `24` | 每用户每日执行上限 |
| `UNREAD_PAUSE_THRESHOLD` | `5` | 连续未读自动暂停阈值 |
| `MONTHLY_BUDGET_MICROS` | `5000000` | 月预算微单位软阈值；120% 为硬熔断 |
| `INPUT_COST_MICROS_PER_MILLION` | `280000` | 每百万输入 token 的预算估算微单位 |
| `OUTPUT_COST_MICROS_PER_MILLION` | `420000` | 每百万输出 token 的预算估算微单位 |
| `WEB_SEARCH_API_URL` / `WEB_SEARCH_API_KEY` | Brave Search 地址 / 无 | 搜索 provider；未配置返回 `search_not_configured` |
| `WEB_FETCH_MAX_BYTES` | `1000000` | 安全网页抓取响应上限；DNS 地址固定并拒绝私网及私网重定向 |
| `DOCUMENTS_DIR` / `KNOWLEDGE_FILE` / `KNOWLEDGE_BASES_FILE` | `backend/data/*` | 文档、检索块与知识库元数据 |
| `KNOWLEDGE_MIN_SCORE` | `0.05` | 本地检索最低余弦相似度，避免注入无关片段 |
| `JSON_BODY_MAX_BYTES` | `16000000` | JSON/multipart 请求体上限，需高于 base64 图片大小 |
| `APNS_TEAM_ID` / `APNS_KEY_ID` / `APNS_TOPIC` / `APNS_PRIVATE_KEY` | 无 | APNs token 鉴权；缺失时任务记录 `not_configured` 而不影响生成结果 |

设置 `ENABLE_SCHEDULER=true` 后服务会自动扫描到期任务，也可以由外部 cron 调用内部端点。图片上传只接受 JPEG/PNG/GIF/WebP，`purpose` 固定为 DeepSeek 要求的 `user_data`；`expiresAfterSeconds` 可为 `null`（永久）或 3600–2592000 秒，并代理为 Files API 的 `expires_after[anchor]` 与 `expires_after[seconds]`。

## Docker 部署

复制环境变量模板，至少替换 DeepSeek、应用访问令牌和内部调度令牌；需要搜索或 APNs 时再填写对应可选项：

```bash
cp .env.example .env
docker compose up -d --build
docker compose ps
curl http://127.0.0.1:8787/health
```

Compose 默认只把端口绑定到宿主机回环地址，适合在同机反向代理后提供 HTTPS。若仅在可信局域网测试，可把 `compose.yaml` 的端口改为 `8787:8787`；不要删除 `APP_ACCESS_TOKEN`。需要从公网访问时，应由 Caddy、Nginx 或托管平台终止 TLS，并限制日志记录请求头。

数据保存在 `deepseek_data` 命名卷中。升级前可用 `docker compose down` 停止服务，但不要添加 `-v`，否则会删除数据卷。

## iOS 生成、编译与个人签名

基础客户端需要 macOS、Xcode 16+；要编译 AlarmKit 分支需 Xcode 26 SDK。工程用免费的 [XcodeGen](https://github.com/yonaskolb/XcodeGen) 生成。XcodeGen 只生成工程，不进入 App 二进制，也不是付费依赖。

```bash
brew install xcodegen
cd ios
xcodegen generate
xcodebuild -project PersonalDeepSeek.xcodeproj -scheme PersonalDeepSeek \
  -destination 'platform=iOS Simulator,name=iPhone 16' test
```

随后在 Xcode 打开工程，在 App 和 Widget 两个 target 选择同一 Team。把 `local.personal.deepseek`、`local.personal.deepseek.widgets` 和 App Group `group.local.personal.deepseek` 改成你账号下唯一值，并同步修改两个 entitlements、`AppGroupSnapshotStore.suiteName` 与后端 `APNS_TOPIC`。启用 App Groups、Push Notifications 和 Live Activities 所需 capability；免费个人 Team 可能不提供 APNs，其他本地功能仍可运行。连接设备后 Run。聊天、知识库和研究无需电脑在线；云端任务服务必须部署在手机可访问的 HTTPS 地址，局域网临时调试可填写 Mac 的局域网地址。

AlarmKit 只在 iOS 26+ 调用。一次性任务使用固定日期；每周强提醒只接受小时、分钟和星期均为具体值的 cron，且任务时区必须与当前设备时区一致。不支持时 App 会显示明确错误，服务器权威调度不受影响。

在设置页分别保存 DeepSeek Key、Brave Search Key、云端任务服务地址和 `APP_ACCESS_TOKEN`；密钥与令牌均写入 Keychain。聊天与研究使用端上密钥直连，定时任务由云端服务使用其环境变量中的 `DEEPSEEK_API_KEY` 执行。不要把 `.env`、Xcode Scheme 环境变量或 `data/store.json` 提交到版本库。

## API 与调度语义

接口见 [shared/api.md](shared/api.md)，任务契约见 [shared/task.schema.json](shared/task.schema.json)。时区必须是 IANA 名称；`once` 使用未来 ISO-8601 时间；cron 为五字段表达式并按任务时区计算（支持 `*`、列表、范围和步长）；RRULE 支持 MINUTELY/HOURLY/DAILY/WEEKLY/MONTHLY/YEARLY 的间隔调度并强制至少一小时。复杂 RRULE 的 `BY*` 日历规则留给后续生产调度器。

运行历史可通过 `GET /v1/tasks/:id/runs` 获取，也可在任务列表点时钟按钮查看；打开历史页会将已展示结果标记为已读，从而重置连续未读计数。

任务历史中的 `notificationStatus` 为 `not_requested`、`not_configured`、`no_devices`、`sent` 或 `failed`。APNs `.p8` 只应放服务端环境变量；Live Activity 更新路由按 `operationId` 查找已注册 token 并发送 ActivityKit `content-state`。Widget/Live Activity 只读 App Group 快照，不在扩展内联网。

## 安全说明

后端只将不透明 `user_id` 发给 DeepSeek。网页工具没有配置时绝不执行。服务仅默认绑定回环地址；若暴露到局域网或公网，应在前面增加 TLS 与真正的身份认证。JSON 文件不应包含 API Key。测试中的 `test-placeholder` 只注入模拟网络客户端，不是可用令牌。
