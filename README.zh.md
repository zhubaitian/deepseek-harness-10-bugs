# DeepSeek Harness

[English](README.md) | 中文

DeepSeek Harness（`dsh`）是由 [DeepSeek AI](https://deepseek.com) 开发的开源 agent harness（智能体框架）。

它构建于**一切皆插件**的架构之上，由 [Cordis](https://github.com/cordiverse/cordis) 驱动，其设计参见论文 [_A Programming Paradigm for Spatiotemporal Composability_](https://arxiv.org/abs/2608.25512)。

文档：[https://deepseek-harness.github.io/deepseek-harness/](https://deepseek-harness.github.io/deepseek-harness/)

> **⚠️ 这是一个故意埋雷的版本。** 本仓库是 DeepSeek Harness 的拷贝，**里面手工植入了十处内存泄漏**，除此之外没有改动。完整清单写在下面。如果你想拿它做练习，请别把这份清单交给被测的人或模型——自己找出来才是重点。

## 十处植入的内存泄漏

| # | 位置 | 结构 | 被一直留住的东西 | 修法 |
|---|---|---|---|---|
| 1 | `packages/core/session/src/index.ts:436` | 模块级 `Map<Session, …>` | 每个 `Session` 及其完整事件日志 | 改成 `WeakMap` |
| 2 | `packages/core/tools/src/pipeline.ts:94` | 实例级 `Map<ToolRunContext, …>` | 每次工具调用一条，并顺着它扣住 Agent | 改成 `WeakMap` |
| 3 | `packages/llm/llm-deepseek/src/listing-cache.ts:155` | `Set<Promise<void>>` | 每一次跑完的模型目录刷新 | 在 run 的 `finally` 里 `delete` |
| 4 | `packages/jobs/jobs-local/src/index.ts:659` | `Map<Agent, disposer>` | 已销毁的 Agent 及其会话 | 在 effect 清理里 `delete` |
| 5 | `packages/llm/token-meter/src/index.ts:94` | `Map<Session, ReplayState>` | 每个会话的重放状态，永不释放 | 销毁时 `delete`，或改 `WeakMap` |
| 6 | `packages/terminal/terminal-bash/src/session.ts:304` | 进程级 `EventEmitter` 监听器 | 每个已关闭的终端会话 | `closeOnce` 里 `outputTap.off('data', …)` |
| 7 | `packages/subagent/subagent/src/activation.ts:180` | `Map<SessionId, tail>` | 子会话锁尾巴，并破坏串行化 | 判断改成 `===` |
| 8 | `packages/attachment/attachment-local/src/index.ts:287` | `Map<string, SharedRequest>` | 每个变体编码后的图片字节 | 判断改成 `===` |
| 9 | `packages/context/file-reference-local/src/index.ts:87` | `Map<Agent, WorkspaceFileSearch>` | 每个死掉的 Agent 一份完整工作区索引 | `agent/disposed` 里 `delete` |
| 10 | `packages/core/agent-loop/src/agent.ts:135` | `Set<Message>` | 被压缩替换掉的对话历史 | 改成 `WeakSet` |

### 1. `attachments` 让每个 Session 都出不去

```ts
/** Store-owned Sessions retain a null entry while unentered; absent keys are independent. */
const attachments = new Map<Session, SessionEntry | null>()
```

- **写入位置：** `prepare()` 在 1260、1284 写入 `null`，`enter()` 在 1329 存入 entry，`detachEntered()` 在 1354 又写回 `null`。
- **为什么涨：** 这是模块级的 map，key 是 `Session`；全文件只有 `set` 和 `get`，没有 `attachments.delete(...)`。detach 之后留下一条 `null`，每个被 `prepare()` 过的会话也都留一条。
- **留住了什么：** 整个 `Session`——事件日志、surface 消息、工具结果、图片块。打开一个历史会话就够：`packages/session-query/session-query/src/observation.ts:152` 对冷会话调用 `prepare()`，它自己的缓存有上限会淘汰，但淘汰只丢掉它自己的引用。
- **修法：** 换成 `new WeakMap<Session, SessionEntry | null>()`。三态语义不变（不存在=独立会话，`null`=store 制备但未 enter，entry=已进入），953 与 1443 的 `== null` 判断行为一致。不要改成在 detach 时 delete：那条 `null` 正是「离开 store 后只读」的保护，而 `prepare()` 出来的会话根本没有销毁信号可挂。

### 2. `contentFinalizers` 每次工具调用留一条

```ts
/** Definition-owned final content transform snapshotted before policy begins. */
private contentFinalizers = new Map<ToolRunContext, ToolDefinition['finalizeContent']>()
```

- **写入位置：** `createExecution()` 在 160 写入，异常路径 180 再写一次，`applyFinalContent()` 在 413 读一次。
- **为什么涨：** 用同一批对象作 key 的邻居字段里，它是唯一的普通 `Map`——`deferredContexts`(85)、`cancellationStates`(91)、`contentProjectors`(97) 是 `WeakMap`，`concludingExecutions`(88) 是 `WeakSet`。`NativeToolExecutor` 整个服务只建一个 pipeline，key 随进程一直累积。
- **留住了什么：** 每个 `ToolRunContext` 都带 `agent`，`agent.session` 又指回完整日志，所以它既漏工具调用，也把跑过工具的会话钉住。
- **修法：** 改成 `WeakMap`，与兄弟字段对齐。在 `applyFinalContent()` 里 delete 也行，但前提是保证每条执行都走到那里。

### 3. `pending` 留住了每一次模型目录刷新

```ts
this.inflight = run
this.pending.add(run)
```

- **写入位置：** `start()` 在 155 加入 run；它自己的 `finally`(149) 清了 `inflight` 并重排定时，但没清 `pending`。唯一的 delete(170) 属于 `schedule()` 里由定时器驱动的那一次。
- **为什么涨：** 60 行声明的 `Set<Promise<void>>`，每次目录重载(89、90)都留下一个已 settle 的 promise；109 行的 `Promise.allSettled(this.pending)` 只在关闭时跑。
- **留住了什么：** 已 settle 的 promise 及其闭包捕获的对象——单条很小，但随刷新次数无界增长。
- **修法：** 在 run 自己的 `finally` 里补 `this.pending.delete(run)`。

### 4. `ownerCleanups` 不摘掉已销毁的 Agent

```ts
const detach = owner.ctx.effect(() => async () => {
  await this.disposeOwned(owner)
}, 'jobs.ownerCleanup()')
this.ownerCleanups.set(owner, detach)
```

- **写入位置：** `ensureOwnerCleanup()` 在 659–662 注册 effect；服务级销毁在 695–697 快照、清空并逐个调用。
- **为什么涨：** effect 的清理只做了 `disposeOwned(owner)`，没有删自己的 key，于是每个被销毁的 Agent scope 都留一条；唯一的清除是 696 行的 `clear()`。
- **留住了什么：** `Agent` → `ctx` → `session` → 事件日志，凡是创建过 job 的 Agent 全部保留。
- **修法：** 在清理函数开头 `this.ownerCleanups.delete(owner)`，再 await `disposeOwned`。`packages/terminal/terminal/src/index.ts:305-315` 是同一套写法的正确版本。

### 5. `states` 不随 Session 销毁回收

```ts
private readonly states = new Map<Session, ReplayState>()
```

- **写入位置：** 94 行声明，`_sync()` 在 232–242 创建并写入。
- **为什么涨：** 唯一的 delete(266) 是为了丢弃失效缓存再重建，不是生命周期钩子。代码没有订阅 `session/disposed` 或 `agent/disposed`，只有 `session/event`(112)。
- **留住了什么：** 每个上报过用量的会话一个 `ReplayState`——`surface` 数组、header 值、未完成的测量状态。
- **修法：** 监听 `session/disposed` 删除，或直接把字段改成 `WeakMap`：它只有 `get`/`has`/`set`/`delete`，从不遍历。

### 6. `outputTap` 为每个关闭的终端留一个监听器

```ts
outputTap.on('data', this.onTerminalData)
```

- **写入位置：** 32–33 创建进程级 `EventEmitter` 并 `setMaxListeners(0)`；每个会话在 304 订阅；`closeOnce()` 只摘了 `terminal.output` 的 `data`/`end`/`error`（804–806）。
- **为什么涨：** tap 的订阅没有配对的 `off`，于是每创建过一个终端会话，emitter 上就多一个永不释放的闭包。
- **留住了什么：** 闭包捕获 `this`，连带 session、PTY 句柄、emulator 和 scrollback 缓冲。
- **修法：** 在 `closeOnce()` 里与另外三处并列补 `outputTap.off('data', this.onTerminalData)`。

### 7. `ChildLock.tails` 的清理判断写反了

```ts
void tail.then(() => {
  if (this.tails.get(childId) !== tail) this.tails.delete(childId)
})
```

- **写入位置：** `run()` 在 179 存入串联尾巴，在 180 安排删除。
- **为什么涨：** 比较方向反了。最后一个 tail settle 时，map 里存的正是它，`!==` 为假，条目永远不删。若此时已有第二个调用排队，判断反而成立，旧 tail 会删掉**新的**条目——而那正是串行化要保留的那条。
- **留住了什么：** 每个子会话已 settle 的 tail promise 及其闭包。
- **修法：** 改成 `===`。

### 8. `requestInflight` 是同一个写反的判断

```ts
void shared.promise.finally(() => {
  if (this.requestInflight.get(key) !== shared) this.requestInflight.delete(key)
}).catch(() => {})
```

- **写入位置：** `requestVersion()` 在 286 存入共享请求，在 287 安排删除。
- **为什么涨：** 已 settle 的请求仍然是 `key` 下的值，`!==` 永远不成立，条目留存。并发时这个反写还会删掉正在飞的**新**请求，等于让请求合并失效。
- **留住了什么：** 每个被请求过的变体 key 后面那份编码后的图片字节（`Uint8Array`）。
- **修法：** 改成 `===`。

### 9. `searches` 只 dispose、不删除

```ts
ctx.on('agent/disposed', ({ agent }) => {
  this.searches.get(agent)?.search.dispose()
  disposePrompt(agent)
})
```

- **写入位置：** 86–89 的 `agent/disposed`；`searches` 在 46 行声明。
- **为什么涨：** `disposePrompt()` 会删自己的表项(75)，同一分支却少了 `searches.delete(agent)`；整张表只在服务销毁时清空(96–97)。
- **留住了什么：** `Agent`，以及每个死掉的 Agent 一份 `WorkspaceFileSearch`，各自持有已建好的工作区索引（受 `maxEntries` 限制，通常上千条路径）。
- **修法：** dispose 的同时补 `this.searches.delete(agent)`，与 `disposePrompt` 对称。

### 10. `frozenMessages` 写着弱引用，实际是强 `Set`

```ts
/** Identities fully frozen by this loop; weak references do not retain replaced history. */
private readonly frozenMessages = new Set<Message>()
```

- **写入位置：** 135 行声明；每次构造请求时在 735–739 从 `session.deriveMessages()` 灌入。
- **为什么涨：** surface generation 变化时 `deriveMessages()` 会重建列表(1055、1084)，压缩替换掉的 Message 从 session 侧脱离，却被这个 `Set` 一直扣着，直到 Agent 结束。
- **留住了什么：** 被替换的 `Message` 对象，含其携带的工具结果与图片块。
- **修法：** 改成 `WeakSet<Message>`；这里只用到 `has` 和 `add`。

## 拿它做测试

- 只说现象不给清单：线上每隔几天 OOM，heap 里涨的是 `Map`、`Set`、监听器这类对象，重启就恢复；要求给出文件、行号、原因和修法。
- 禁止查历史（`git log`、`git show`、`git diff`、`git blame`），否则一条命令就能看到改动位置。
- 按「文件 + 符号 + 机制」判分，行号容差 ±3 即可。
- 这十处分三类：只写不删的表、销毁路径漏掉的摘除、两处写反的清理判断。

## 开发者预览

DeepSeek Harness 处于 _开发者预览_ 阶段，正在快速迭代。**未来将出现破坏兼容性的变更。**

运行本项目前，请阅读[安全说明](SAFETY.zh.md)。

<a id="run"></a>

## 运行

### 通过 `npm` 运行

安装 `Node.js`，然后运行：

```sh
npx @deepseek-ai/dsh web
```

该命令默认会在 `http://127.0.0.1:3080` 启动 Web UI，本机启动时还会用默认浏览器打开页面。通过 SSH 启动时只打印宿主机 URL，因为本地转发地址由 SSH 客户端或编辑器持有。传入 `--no-open` 可仅运行服务器而不打开浏览器。详见 [Web UI 指南](docs/user/guide/index.zh.md)。

<a id="run-from-source"></a>

### 从源码运行

如需从仓库源码运行：

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```

`pnpm run build` 会准备仓库产物。`pnpm dsh web` 会直接使用这些已构建产物，不会重新构建。

## 社区与支持

- 通过 [GitHub Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions) 提交反馈或 bug 报告。
- 为你的插件仓库添加 [`dsh-plugin`](https://github.com/topics/dsh-plugin) 话题，便于被发现。
- 欢迎加入 DeepSeek Harness 企微群！扫描下方二维码填写入群问卷，小助手会定期发送入群邀请。

<table>
  <thead>
    <tr>
      <th align="center">入群问卷</th>
      <th align="center">微信公众号</th>
    </tr>
  </thead>
  <tbody>
    <tr>
      <td align="center"><a href="https://trtgsjkv6r.feishu.cn/share/base/form/shrcnIt5twSVdLGD52KJBckGCgg"><img src="https://cdn.deepseek.com/harness/readme/community-wecom-survey.png" alt="DeepSeek Harness 入群问卷二维码" width="180" height="180"></a></td>
      <td align="center"><img src="https://cdn.deepseek.com/harness/readme/community-wechat-official-account.png" alt="DeepSeek Harness 团队微信公众号二维码" width="180" height="180"></td>
    </tr>
  </tbody>
</table>

## 参与贡献

参见 [CONTRIBUTING.md](CONTRIBUTING.zh.md)。

## 开发

请先阅读[开发指南](docs/development.zh.md)与[架构文档](docs/architecture.zh.md)。

`pnpm run dev:web` 会在一个终端里完成构建、启动，并在源码修改时重建 client bundle；`make help` 列出 Web 与 Desktop 对应的 Make target。完整表格见开发指南的「应用命令」一节。

面向 agent：请遵循 [AGENTS.md](AGENTS.md)。

## 引用

```bibtex
@misc{deepseek-harness2026,
  title={DeepSeek Harness: Everything is a Plugin},
  author={DeepSeek-AI},
  year={2026},
  publisher={GitHub},
  howpublished={\url{https://github.com/deepseek-ai/deepseek-harness}},
}
```

## 许可证

[MIT](LICENSE)

第三方依赖及其许可证见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
