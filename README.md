# DeepSeek Harness

English | [中文](README.zh.md)

DeepSeek Harness (`dsh`) is an open-source agent harness developed by [DeepSeek AI](https://deepseek.com).

It is built on an **everything-is-a-plugin** architecture and powered by [Cordis](https://github.com/cordiverse/cordis), whose design is described in [_A Programming Paradigm for Spatiotemporal Composability_](https://arxiv.org/abs/2608.25512).

Documentation: [https://deepseek-harness.github.io/deepseek-harness/](https://deepseek-harness.github.io/deepseek-harness/)

> **⚠️ This is a deliberately bugged build.** This repository is a modified copy of DeepSeek Harness: **ten memory leaks were planted by hand** and nothing else was changed. The complete list is published below. If you want to use it as an exercise, keep the list away from the person or model under test — finding them unaided is the point.

## The ten planted leaks

| # | Location | Structure | What stays reachable | Fix |
|---|---|---|---|---|
| 1 | `packages/core/session/src/index.ts:436` | module-level `Map<Session, …>` | every `Session` and its full event log | use a `WeakMap` |
| 2 | `packages/core/tools/src/pipeline.ts:94` | instance `Map<ToolRunContext, …>` | one entry per tool call, and the owning Agent through it | use a `WeakMap` |
| 3 | `packages/llm/llm-deepseek/src/listing-cache.ts:155` | `Set<Promise<void>>` | every finished catalog-refresh run | `delete` in the run's `finally` |
| 4 | `packages/jobs/jobs-local/src/index.ts:659` | `Map<Agent, disposer>` | disposed Agents and their sessions | `delete` inside the effect cleanup |
| 5 | `packages/llm/token-meter/src/index.ts:94` | `Map<Session, ReplayState>` | per-session replay state, forever | `delete` on disposal, or a `WeakMap` |
| 6 | `packages/terminal/terminal-bash/src/session.ts:304` | process-wide `EventEmitter` listener | every closed terminal session | `outputTap.off('data', …)` in `closeOnce` |
| 7 | `packages/subagent/subagent/src/activation.ts:180` | `Map<SessionId, tail>` | child-lock tails, and broken serialization | invert the guard to `===` |
| 8 | `packages/attachment/attachment-local/src/index.ts:287` | `Map<string, SharedRequest>` | encoded image bytes for every variant | invert the guard to `===` |
| 9 | `packages/context/file-reference-local/src/index.ts:87` | `Map<Agent, WorkspaceFileSearch>` | a full workspace index per dead Agent | `delete` in `agent/disposed` |
| 10 | `packages/core/agent-loop/src/agent.ts:135` | `Set<Message>` | the message history compaction replaced | use a `WeakSet` |

### 1. `attachments` pins every Session in the process

```ts
/** Store-owned Sessions retain a null entry while unentered; absent keys are independent. */
const attachments = new Map<Session, SessionEntry | null>()
```

- **Where:** `prepare()` sets `null` at 1260 and 1284, `enter()` stores the entry at 1329, and `detachEntered()` writes `null` back at 1354.
- **Why it grows:** the map is module level and keyed by `Session`; the file contains `set` and `get` and no `attachments.delete(...)`. A detached session leaves a `null` entry behind, and every session that was ever `prepare()`d leaves one too.
- **What stays reachable:** the whole `Session` — event log, surfaced messages, tool results, image blocks. Opening one archived conversation is enough: `packages/session-query/session-query/src/observation.ts:152` calls `prepare()` for cold sessions, and its own cache is bounded and evicts, but eviction only drops *its* reference.
- **Fix:** `new WeakMap<Session, SessionEntry | null>()`. The three states stay distinct (absent = independent session, `null` = store-owned but unentered, entry = entered), and the `== null` checks at 953 and 1443 behave the same. Do not delete on detach instead: that `null` entry is what keeps a session read-only after it leaves the store, and a `prepare()`d session has no disposal signal to hook.

### 2. `contentFinalizers` accumulates one entry per tool call

```ts
/** Definition-owned final content transform snapshotted before policy begins. */
private contentFinalizers = new Map<ToolRunContext, ToolDefinition['finalizeContent']>()
```

- **Where:** written in `createExecution()` at 160 and on the error path at 180, read once in `applyFinalContent()` at 413.
- **Why it grows:** it is the only plain `Map` among neighbours keyed by the same objects — `deferredContexts` (85) and `cancellationStates` (91) are `WeakMap`, `concludingExecutions` (88) is a `WeakSet`, `contentProjectors` (97) is a `WeakMap`. `NativeToolExecutor` builds one pipeline for the life of the service, so keys accumulate for the life of the process.
- **What stays reachable:** every `ToolRunContext` carries `agent`, and `agent.session` leads back to the full log, so this leaks tool calls *and* the sessions that ran them.
- **Fix:** `WeakMap`, matching the siblings. Deleting inside `applyFinalContent()` also works, but only if every execution is guaranteed to reach that call.

### 3. `pending` keeps every catalog refresh promise

```ts
this.inflight = run
this.pending.add(run)
```

- **Where:** `start()` adds the run at 155; its `finally` at 149 clears `inflight` and reschedules, but not `pending`. The only `delete` (170) belongs to the timer-driven run created in `schedule()`.
- **Why it grows:** `Set<Promise<void>>` declared at 60; every catalog reload (89, 90) leaves a settled promise behind. `Promise.allSettled(this.pending)` at 109 only runs at close.
- **What stays reachable:** settled promises and whatever their closures captured — small per entry, unbounded across refreshes.
- **Fix:** `this.pending.delete(run)` inside the run's own `finally`.

### 4. `ownerCleanups` never removes a disposed Agent

```ts
const detach = owner.ctx.effect(() => async () => {
  await this.disposeOwned(owner)
}, 'jobs.ownerCleanup()')
this.ownerCleanups.set(owner, detach)
```

- **Where:** registered by `ensureOwnerCleanup()` at 659–662; the service-wide teardown snapshots, clears, and invokes the entries at 695–697.
- **Why it grows:** the effect cleanup disposes the owner's jobs but never removes its own key, so the map keeps one entry per Agent scope that was ever torn down. Only `this.ownerCleanups.clear()` (696) removes anything.
- **What stays reachable:** `Agent` → `ctx` → `session` → event log, for every agent that ever created a job.
- **Fix:** `this.ownerCleanups.delete(owner)` at the top of the cleanup, before awaiting `disposeOwned`. `packages/terminal/terminal/src/index.ts:305-315` is the same pattern done correctly.

### 5. `states` never drops a disposed Session

```ts
private readonly states = new Map<Session, ReplayState>()
```

- **Where:** declared at 94, created and stored in `_sync()` at 232–242.
- **Why it grows:** the single `delete` (266) discards an invalidated cache so it can be rebuilt — it is not a lifecycle hook. Nothing subscribes to `session/disposed` or `agent/disposed`; the only listener is `session/event` (112).
- **What stays reachable:** one `ReplayState` per session that ever reported usage — its `surface` array, header values, and pending measurement state.
- **Fix:** delete on `session/disposed`, or make the field a `WeakMap`: it is only touched through `get`, `has`, `set`, and `delete`, and never iterated.

### 6. `outputTap` keeps a listener per closed terminal

```ts
outputTap.on('data', this.onTerminalData)
```

- **Where:** the process-wide `EventEmitter` is created at 32–33 with `setMaxListeners(0)`, each session subscribes at 304, and `closeOnce()` unsubscribes only from `terminal.output` — `data`, `end`, `error` at 804–806.
- **Why it grows:** the tap subscription has no matching `off`, so one closure stays on the emitter per terminal session ever created, for the life of the process.
- **What stays reachable:** the listener closes over `this`, so it holds the session, its PTY handle, the emulator, and the scrollback buffer.
- **Fix:** `outputTap.off('data', this.onTerminalData)` in `closeOnce()`, next to the other three removals.

### 7. `ChildLock.tails` has its cleanup guard inverted

```ts
void tail.then(() => {
  if (this.tails.get(childId) !== tail) this.tails.delete(childId)
})
```

- **Where:** `run()` stores the chaining tail at 179 and schedules this removal at 180.
- **Why it grows:** the comparison is backwards. When the last tail settles the map still holds exactly that tail, so `!==` is false and the entry is never deleted. With a second caller queued the test flips: the older tail then deletes the *newer* entry, which is the one the lock must keep to serialize work.
- **What stays reachable:** every settled tail promise and its closure, per child session.
- **Fix:** compare with `===`.

### 8. `requestInflight` has the same inverted guard

```ts
void shared.promise.finally(() => {
  if (this.requestInflight.get(key) !== shared) this.requestInflight.delete(key)
}).catch(() => {})
```

- **Where:** `requestVersion()` stores the shared request at 286 and schedules this removal at 287.
- **Why it grows:** the settled request is still the value under `key`, so `!==` never holds and the entry survives. Under concurrency the inversion also removes a newer in-flight request, which drops request coalescing.
- **What stays reachable:** the encoded image bytes (`Uint8Array`) behind every variant key that was ever requested.
- **Fix:** compare with `===`.

### 9. `searches` is disposed but never removed

```ts
ctx.on('agent/disposed', ({ agent }) => {
  this.searches.get(agent)?.search.dispose()
  disposePrompt(agent)
})
```

- **Where:** `agent/disposed` at 86–89; `searches` is declared at 46.
- **Why it grows:** `disposePrompt()` removes its own map entry (75), but the sibling branch never calls `searches.delete(agent)`. The map is only cleared when the service itself is disposed (96–97).
- **What stays reachable:** the `Agent`, plus one `WorkspaceFileSearch` per dead agent, each holding a settled workspace index (bounded by `maxEntries`, typically thousands of paths).
- **Fix:** `this.searches.delete(agent)` alongside the disposal, mirroring `disposePrompt`.

### 10. `frozenMessages` claims weak references but is a strong `Set`

```ts
/** Identities fully frozen by this loop; weak references do not retain replaced history. */
private readonly frozenMessages = new Set<Message>()
```

- **Where:** declared at 135 and filled on every request build at 735–739 from `session.deriveMessages()`.
- **Why it grows:** `deriveMessages()` rebuilds its list when the surface generation changes (1055, 1084), so compaction replaces message objects — the session drops them and this `Set` keeps them for as long as the Agent lives.
- **What stays reachable:** the replaced `Message` objects, including the tool results and image blocks they carry.
- **Fix:** `WeakSet<Message>`; `has` and `add` are the only operations used.

## Running it as an exercise

- Describe the symptom, not the list: repeated OOM every few days, heap growth is `Map`, `Set`, and listener objects, a restart clears it. Ask for file, line, cause, and fix.
- Forbid history lookups (`git log`, `git show`, `git diff`, `git blame`), or the answer is one command away.
- Score by file, symbol, and mechanism; a tolerance of ±3 lines is enough.
- The planted set mixes three families: tables that only ever grow, teardown paths that miss a removal, and two cleanup guards written backwards.

## Developer preview

DeepSeek Harness is in _developer preview_ and iterating rapidly. **THERE WILL BE COMPATIBILITY-BREAKING CHANGES.**

Review the [safety notice](SAFETY.md) before running the project.

## Run

### Run from `npm`

Install `Node.js`, then run:

```sh
npx @deepseek-ai/dsh web
```

The command starts the Web UI at `http://127.0.0.1:3080` by default and opens it in the default browser for a local launch. An SSH launch only prints the host URL because the SSH client or editor owns the local forwarded address. Pass `--no-open` to run the server without opening a browser. See [Web UI guide](docs/user/guide/index.md).

### Run from source

To run from a repository checkout:

```sh
git clone https://github.com/deepseek-ai/deepseek-harness.git
cd deepseek-harness
pnpm install
pnpm run build
pnpm dsh web
```

`pnpm run build` prepares the repository artifacts. `pnpm dsh web` uses those built artifacts without rebuilding.

## Community and support

- Submit feedback or bug reports through [GitHub Discussions](https://github.com/deepseek-ai/deepseek-harness/discussions).
- Add the [`dsh-plugin`](https://github.com/topics/dsh-plugin) topic to your plugin repository for discoverability.
- Join <a href="https://discord.gg/4MrtZUhpxg">DeepSeek Harness Discord community</a>.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Development

Start with the [development guide](docs/development.md) and [architecture documentation](docs/architecture.md).

`pnpm run dev:web` builds, serves, and rebuilds client bundles on source edits in one terminal, and `make help` lists the matching Make targets for Web and Desktop; the guide's application commands section owns the full table.

For agents, follow [AGENTS.md](AGENTS.md).

## Citation

```bibtex
@misc{deepseek-harness2026,
  title={DeepSeek Harness: Everything is a Plugin},
  author={DeepSeek-AI},
  year={2026},
  publisher={GitHub},
  howpublished={\url{https://github.com/deepseek-ai/deepseek-harness}},
}
```

## License

[MIT](LICENSE)

Third-party dependencies and their licenses are disclosed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
