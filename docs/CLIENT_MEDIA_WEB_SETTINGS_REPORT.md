# CLIENT-001 — 图片 / 官方网页 API / 设置页

日期：2026-10-18（Asia/Hong_Kong）。状态：代码及 Simulator/真实 API 验证通过；原照片和真机界面交互待复测。

## 范围与交付位置

- 基线：canonical `593f106f69e44e170d00fdcaf08b43df0b3488f4`。
- 工作分支：`codex/client-media-web-settings`。
- 工作目录：`D:/daifuku/.worktrees/client-media-web-settings`。
- 最终已验证源码：`f17143c8bb208e050eac237e3bfcefba1c3f2877`；后续提交仅包含报告证据。
- Deep Search 后续开发按用户要求暂停；DS-003D3 未开始。原有单次研究功能没有被重构或接入新研究引擎。
- 没有 SwiftData schema 变更、真实数据库迁移、Memory/Profile 语义调整、后端部署、canonical/main 合并或 IPA 打包。

## 图片诊断：已知与未知

截图本身不能证明唯一根因，原始 `camera.jpg` 未提供。没有上传用户截图或私人照片到测试接口。

使用已有预设 Key 对程序生成的公开数字图片做了四次最小真实请求：PNG 开/关思考、JPEG + SSE + 历史消息、JSON 斜杠转义差异，均识别出 742。因此没有证据把原问题归因于 Base64 语法、SSE、思考开关或斜杠转义，也不能排除当时服务状态或原图片特性。

代码审计发现的实际缺陷：

1. 相册读取使用 `try?` 且转换失败直接跳过，用户看不到失败原因。
2. 图片异步准备尚未完成时仍可发送，可能先发送文字，图片随后才进入输入框。
3. 小尺寸图片原先可绕过重新栅格化，没有统一相机方向、透明度和输出色彩范围。

## 图片改动

- `AttachmentPicker.swift`：统一栅格化为标准 SDR、无透明度的正向 JPEG；单边最多 1600，质量递减且压缩结果不超过 1.2 MB。转换失败不返回伪图片。
- `ChatView.swift`：图片读取期间显示准备状态并阻止发送；保留成功图片、提示失败数量；相机转换失败在相机关闭后提示，不把取消拍照当错误。
- `ChatImageUpload.swift`：校验真实可解码字节和格式；调用官方 `/files`，明确请求 `purpose=user_data` 及 3600 秒有效期；验证 file_id、返回有效期和可用的 bytes 字段。每 APIClient 实例保留有界、按 Key+图片区分的短期缓存，不存入数据库或日志。
- `APIClient.swift`：上传成功后将当次图片序列化为 `file` / `file_id` 内容块。模型能力、数量和请求体检查在上传前执行；失败不降级为纯文字回答；继续使用同一个 SSE/parser/agent 协议。
- 不持久化图片正文到 ChatMessage，没有新增完整附件历史或 Files 管理页。

官方依据：[Vision](https://api-docs.deepseek.com/guides/vision/)、[Files API](https://api-docs.deepseek.com/guides/files_api/)。

## DeepSeek 官方网页接口

- `DeepSeekWebService.swift`：真实 `POST /v1/tools/search`、`POST /v1/tools/fetch`，不是要求聊天模型模拟搜索。
- 普通查询最多 128 字符，最多三个来源；读取具体 HTTPS URL 时直接 Fetch，避免额外搜索。保留标题、URL、摘要和有界 Markdown 正文。
- 固定官方主机携带 Key，外部网页不接收 Key；使用既有 noRedirect HTTP 抽象。无有效 Key、401/402/403/429、无效数据会明确失败；429/5xx 至多三次有界尝试。普通抓取失败可保留明确的摘要来源，直接 URL 抓取不伪造正文。
- 现有 `web_search` 原生工具改用可配置普通联网适配器；只读工具名称、AgentRunner、tool_call_id、SSE parser 保持不变。新增“读取网页/总结网页”等明确意图，并说明工具可直接接收 HTTPS URL。
- Deep Search 的 LocalResearchService admission、规划、台账、覆盖诊断和迭代组件没有切换 provider 或推进开发。LocalResearchService 仅增加一个 provider 枚举值供普通联网结果标注。
- 搜索和抓取具有独立 API 配额/可能的费用，本轮未将其并入旧模型成本估算或云端任务预算。响应体大小检查沿用已取回数据后的本地上限，并非新的全链路下载内存硬限制。

官方依据：[Search](https://api-docs.deepseek.com/api/search/)、[Fetch](https://api-docs.deepseek.com/api/fetch/)。

## Key 默认值与设置交互

真实 Key 不进入源码、安装资源、UserDefaults 或报告。保留原有 Keychain 账号，更新采用 SecItemUpdate，避免旧的先删后存导致失败时丢失旧值。

| 凭据 | 用途 / 默认行为 |
|---|---|
| 聊天与图片 Key | 现有聊天 Key，图片上传/识别及既有记忆调用沿用它 |
| DeepSeek 网页 Key | 新独立 Keychain 项；默认复用已保存聊天 Key；未保存独立值时编辑器预填聊天 Key，保存后切换为独立模式 |
| Brave Key | 只在选择 Brave 时使用旧 Brave 存储项，不会把 DeepSeek Key 当 Brave Key |
| 云端任务令牌 | 保留现有服务令牌，不与 DeepSeek Key 混用 |

升级且已有 Keychain 凭据时无需重复填写。完全全新安装且没有任何已有 Keychain Key 时仍需保存一次；没有把 Windows 上的预设 Key 文件硬编码到公开工程。已保存的预设 Key 用于本轮本地公开接口诊断，未打印其内容。

设置页现在支持：按用途的掩码卡片；当前搜索 provider 和实际生效 Key；独立/复用模式；点入查看、编辑、删除确认；全部凭据折叠总览（含备用项）；按 Bundle 显示真实版本；旧 none 推理强度兼容修正；切换凭据后清除旧连接测试状态。历史记忆导入保留在独立页面，开发诊断折叠，仅 DEBUG 可见。没有虚构账号、CloudKit、StoreKit 或 Share Extension 设置。

## 验证

第一轮 39082564017 在新测试的原始字符串夹具上编译失败：Markdown 的 `#` 与 `#"..."#` 终止符相撞。仅修复测试分隔符并保留失败历史。被后续源码取代的排队/取消运行不算通过。

中间源码 `6cf9bb8` 的 [CI 39083036023](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/39083036023) 成功：370 项普通 XCTest，17 项 opt-in 跳过，0 失败；迁移通过；实际 UIKit 生成 JPEG 经真实 Files API 和 Chat SSE，答案 742；官方 Search/Fetch 返回一个实际网页正文来源。

最终 [CI 39084088088](https://github.com/ShiroDaifuku/PersonalDeepSeek-iOS/actions/runs/39084088088) **SUCCESS**：Xcode 16.4 / iOS 18.5 Simulator 实际构建成功；**371 项 XCTest，354 通过、17 项 opt-in 跳过、0 失败**。ClientWebServiceTests、ClientImageTests 和 ClientImageTransportTests 均通过；八个既有 Research 合约 suite 的 discovery guards 均通过。生成旧库的专项迁移 **1/1 PASS（0.565 秒）**，不是用户设备数据库的迁移声明。

独立开启的真实 smoke **1/1 PASS**：UIKit 图片经过标准 SDR/JPEG 处理后，实际 `/files` 上传并通过 file_id 进入真实 Chat SSE，模型回答 **742**；官方搜索返回一个来源，官方 Fetch 返回该来源正文。来源为 `https://api-docs.deepseek.com/updates`。这一结果不是 mock 回答。只上传程序生成的公开测试图；没有上传用户原图、截图或私人相册。

新增测试覆盖官方请求/响应 schema、独立 Key 头、直接 URL 仅 Fetch、128 字符与空值边界、权限/余额错误不伪成功、429 有界重试、取消、默认凭据策略、掩码、相机输出可解码、multipart 过期字段、file_id 单次替换、上传失败无纯文字补发、无效图片/模型上传前失败和文件缓存复用。

保留既有诊断：MemorySemanticPrecisionEvaluation.swift:343 未使用变量；Widget CFBundleVersion 1 与主 App 17 不一致。中间构建还记录了未链接 AppIntents 的 metadata extraction skipped。没有观察到新增 Swift 6 concurrency 编译错误/警告；不是 warning-free 声明。Simulator 的 eligibility/AppGroup/launch measurement 日志不被误称为用户设备错误。

`docs/evaluations/client-001/` 保存最终公开 smoke JSON 和验证摘要，不保存真实 Key、请求头、原图或上传二进制。原始完整日志在对应 CI artifact。没有改写首次失败或取消的 CI 结论，也没有把 fixture 测试当作新多轮研究的真实质量验收。

这是 macOS/Xcode Simulator 的实际执行，不是 Windows 上推断通过。也不是相机硬件、真实相册/iCloud 读取、设置页触控、原私人照片或设备 Keychain 迁移的真机验收。

## 等待真机复测的项目

1. 原 camera.jpg / 相同拍摄场景，在 Flash 下询问内容。
2. 竖拍、横拍、HDR、相册多图；准备中不能提前发送，失败有提示。
3. 旧 Key 掩码能显示；独立网页 Key 保存后实际生效；切回复用时跟随聊天 Key；删除需确认。
4. “联网搜索…”和“读取网页 https://…”能得到真实引用。
5. 图片发送中停止、切换会话、重新打开 App 的现有行为；本轮没有新增图片历史持久化或恢复能力。

未经用户再次明确要求，不生成 IPA。功能分支保持独立，原工作区和 canonical 研究工作区未被覆盖；本轮未擅自合并 canonical/main。后续若要求测试包，应使用本修复分支/已验证源码，而非旧历史工作区。
