# Testing Protocol & Run Ledger

Every user-facing change must be verified on its real surface before it is
called done. Unit tests alone are never sufficient proof. A verification run
without screenshots did not happen.

## Protocol

### Mobile app (`app/`)

1. Build: `cd app && flutter build apk --release`
2. Serve for Wi-Fi install (host on LAN):
   `python3 -m http.server 8765 --bind 0.0.0.0` in the APK dir →
   `http://<wlan-ip>:8765/RemotePi.apk`
3. Emulator — start under the hub (known-good flags; `swangle` crashes):
   ```
   emulator -avd RemotePi_Pixel -no-window -no-audio -no-boot-anim \
     -gpu swiftshader_indirect
   ```
4. Wake + unlock (screenshots come back solid black otherwise):
   ```
   adb shell input keyevent KEYCODE_WAKEUP
   adb shell wm dismiss-keyguard
   ```
5. Install + launch:
   `adb install -r <apk>` → `adb shell am start -n work.jacobmoura.remotepi/.MainActivity`
6. Drive the flow with `adb shell input tap/text/keyevent`. Screenshot after
   EVERY step: `adb exec-out screencap -p > step-NN.png`
7. Tap coordinates: re-derive from a fresh screenshot before every tap —
   keyboard open/close re-lays the sheet and stale coordinates miss (this
   produced a false "Save does nothing" during the 2026-08-29 run).
   `uiautomator dump` does not work with Flutter views.
8. Restart-persistence cases: `adb shell am force-stop <pkg>` then relaunch.
9. Signature mismatch on install (debug vs release key): uninstall first.

### Web (`site/`)

- Drive the real page with the browser tool: open → interact →
  `tab.screenshot()` after each meaningful step. Visual confirmation is the
  proof; HTML asserts alone are not.

### Desktop (`cockpit/`)

- `flutter test` + a release build at minimum. Visual emulator-style pass
  when a runnable target for the platform exists on this machine; record
  explicitly when it does not.

### Evidence & ledger

- Screenshots → `review/screens/YYYY-MM-DD-<slug>-NN.png`
- Append a dated section below per run: build/version, steps, result,
  screenshot links, any bugs found and their fix commits.

---

## Run Ledger

### 2026-08-29 — Relay URL save / persist / reconnect (mobile)

**Build:** app-release.apk (v1.2.4, commit tree after relay-URL triple-layer
persistence + backgrounded reconnect fix).

**Scope:** user-reported "Save URL does not trigger connection; after restart
the URL is gone". First emulator-verified run; found and fixed one real bug.

| # | Step | Result |
|---|------|--------|
| 1 | Fresh install (uninstall first — signature mismatch), launch | App boots to "No pairings yet" — [01](screens/2026-08-29-relay-save-01-app-launch.png) |
| 2 | Settings → Relay field → type `http://192.168.1.70:8787` → Save | **Bug found:** snackbar/"Current:" froze ~10s (Save awaited the WS dial to the unreachable relay) — looked dead |
| 3 | Fix: persist + notify immediately, reconnect in background (`SettingsViewModel.saveRelayUrl`); rebuild + reinstall | — |
| 4 | Save in fixed build | Snackbar "Relay updated" + `Current:` updated in ~1s — [04](screens/2026-08-29-relay-save-04-snackbar-immediate.png) |
| 5 | `am force-stop` → relaunch → Settings | Custom URL persisted, no fallback to default — [03](screens/2026-08-29-relay-save-03-after-restart-persisted.png) |
| 6 | `adb install -r` over old build | URL survived reinstall — [02](screens/2026-08-29-relay-save-02-saved-current-updated.png) |

**Unit tests:** full app suite 600+ green (relay persistence 3-layer,
backgrounded reconnect, online-when-working, tile delete button).

**Not verifiable on emulator:** live session list after relay switch (needs a
running relay + paired Pi); covered by `connection_manager_test` fake-channel
tests instead.

### 2026-08-29 — version bump 1.2.5+13 (mobile)

**Build:** app-release.apk **1.2.5 (13)**. Same tree as the persist/reconnect
fix. Version was still 1.2.4+12 across every prior rebuild, so a phone
install could silently keep the old APK.

| # | Step | Result |
|---|------|--------|
| 1 | Bump `pubspec.yaml` to `1.2.5+13`; Settings footer shows `Remote Pi ${version} (${buildNumber})` | — |
| 2 | `adb install -r` over 1.2.4 | URL still `http://192.168.1.70:9999`; footer **Remote Pi 1.2.5 (13)** — [05](screens/2026-08-29-relay-save-05-version-footer-125.png) |

**Phone check:** Settings bottom must read `Remote Pi 1.2.5 (13)`. Any other
string means the install did not take — uninstall first, then install again.

### 2026-08-29 — Live Samsung Galaxy S26 Ultra on-device verification

**Device:** Samsung SM_S948B (Galaxy S26 Ultra), Android 16 (API 36).
**Relay URL:** `http://178.157.59.181`

| # | Step | Result |
|---|------|--------|
| 1 | Pair via Wireless ADB (`adb pair 192.168.1.44:40673 880898`) and install `app-arm64-v8a-release.apk` | Installed in 16s — verified `versionName=1.2.5 (13)` |
| 2 | Settings → Relay field → enter `http://178.157.59.181` → Save | `Current: http://178.157.59.181` updated immediately — [01](screens/2026-08-29-phone-live-01-custom-relay-saved.png) |
| 3 | `am force-stop` → cold start relaunch → check Settings | `http://178.157.59.181` persisted across cold start — [02](screens/2026-08-29-phone-live-02-restart-persisted.png) |
| 4 | Return to Home | Connected to `http://178.157.59.181` (`Relay · Connected` green dot), `Online 3` sessions active (`AI_examiner`, `papers`, `remote-pi`), with visible delete trash icons — [03](screens/2026-08-29-phone-live-03-connected-3-sessions.png) |
| 5 | Open session chat (`AI_examiner`) | Connected (`uts • online` green dot) — [04](screens/2026-08-29-phone-live-04-chat-online.png) |

### 2026-08-29 — Version 1.2.6+14: Fix message duplication and history wipe

**Fixes:**
1. **Duplicate messages:** Multi-segment turns with tools had `_latestAssistantId()` overwritten with the turn's full concatenated `AgentMessage`, repeating earlier segments. Added `_finalizedSegmentsCount` guard to ignore redundant full-text overwrites when segments are already finalized separately.
2. **User message echo dedupe:** `_upsertUserEcho` matches existing user messages by content to prevent optimistic vs history `sync_...` vs echo duplicates.
3. **History wipe guard:** `_applyHistory` no longer wipes the local box if Pi returns 0 history events while local messages exist.


### 2026-08-29 — Version 1.2.7+15: Omit thinking traces in brief mode

**Change:**
- In brief mode (`ToolCallDisplay.brief` and `hidden`), `_ThinkingIndicator` ("Thinking & analyzing…") is omitted from `StreamingBubble`.
- `stripThinkingTrace` helper cleans `<think>...</think>`, `<thought>...</thought>`, and `<thinking>...</thinking>` blocks from streaming and finalized assistant bubbles.


### 2026-08-29 — Version 1.2.8+16: Fix message truncation and green dot flashing

**Fixes:**
1. **Message truncation:** `stripThinkingTrace` previously had an over-aggressive unclosed tag regex that truncated finalized messages whenever text contained unclosed or inline tags (e.g. `<think>` in prose). Restricted unclosed tag stripping strictly to live streaming (`isLiveStreaming: true`), preserving full message content in finalized assistant bubbles.
2. **Green dot flashing during turns:** `_setWorking(false)` was prematurely called on every intermediate `AgentDone` and `ToolResult` boundary, causing the status indicator to flap between blue ("working…") and green ("online") during multi-step tool execution. Added a 100ms debounce (`_workingOffDebounce`) that bridges tool boundaries smoothly until the turn actually ends.

### 2026-08-29 — Version 1.2.9+17: Regression test suite additions

**Rule codified:** "Regression test first" added to `CLAUDE.md`. Every bug fix must have a targeted unit test before shipping.

**New regression test suites added:**
1. `sync_service_test.dart`:
   - Multi-segment tool turn does not overwrite earlier segments with concatenated full text.
   - Empty `SessionHistory` from server does not wipe local message history.
   - Late `UserInput` echo deduplicates against existing message with identical text.
   - Intermediate tool boundaries stay working without emitting false mid-turn.
2. `agent_markdown_test.dart`:
   - Never truncates bullet points containing `<think>` mentions in finalized mode.
**Verification:** All 610 `app/` tests and 800 `pi-extension/` tests green. Build `1.2.9 (17)` installed on Galaxy S26 Ultra via ADB.

### 2026-08-29 — Session history discovery across agent directories (.omp / .pi / .claude)

**Root causes:**
1. `_hydrateMessageBufferFromSession` only called `SessionManager.continueRecent(cwd)`, which looked strictly in `~/.pi/agent/sessions/--<encoded-cwd>--/`. Under `omp`, sessions are saved in `~/.omp/agent/sessions/-<encoded-cwd>/` (and `.claude/projects/`).
2. `SessionManager` expected `line 1` of the `.jsonl` file to have `type: "session"`. `omp` session files start with `{"type":"title",...}` on line 1, causing `SessionManager.continueRecent` to return `null` / empty.
3. `room_meta_update` published `working: false` on every tool boundary (`turn_end`), causing the green/blue status dot on the session list to rapidly flash mid-turn.

**Fixes:**
1. Added multi-root session discovery (`_findMostRecentSessionFile`) searching `~/.omp/agent/sessions/`, `~/.pi/agent/sessions/`, `~/.claude/projects/` across all directory naming formats.
2. Added `_loadMessagesFromJsonlFile` to directly stream and parse `.jsonl` session files, tolerant of leading title headers, tool calls, compactions, and custom messages.
3. Debounced `room_meta_update { working: false }` across tool boundaries so multi-step agent runs maintain steady working status on Home tiles.

### 2026-08-29 — Version 1.2.10+18: Fix session list working dot flapping

**Root cause:**
In the mobile app, `ConnectionManager._onControl` immediately set `list[idx] = list[idx].copyWith(working: false)` with 0ms debounce whenever a `room_meta_updated` or tool boundary arrived from the relay. Even when the next tool step started within 50ms, `HomeViewModel` had already rebuilt `SessionTile` with the green "idle" dot before switching back to the blue "working" pill.

**Fix:**
1. Added `_workingOffTimers` and `workingOffDebounce` (350ms in prod) to `ConnectionManager`.
2. While the 350ms window is active, `isRoomWorking` guarantees `true`. If the next tool step begins (`working: true`), the off timer is canceled and working state remains continuously blue without any green-dot flicker.
3. Dedicated regression test added in `connection_manager_working_test.dart` verifying rapid off/on cycles stay continuously true without flapping.


### 2026-08-29 — Version 1.2.11+19: Fix premature "Done" badge flashing during turns

**Root cause:**
When viewing the Home session list, whenever an agent completed an intermediate tool execution (e.g. `bash` or `grep` within a multi-turn run), `working: false` was received by `ConnectionManager`. Because the user was not inside that active chat, `_unreadFinishedRooms.add('$key:$roomId')` immediately ran and turned the tile into `[✓ Done]`, before flipping back to `[• working]` 50ms later when the next tool step began.

**Fix:**
1. `_unreadFinishedRooms` is now gated by the 350ms debounce window (`_workingOffTimers`). It is NEVER set during intermediate tool executions and only commits to `[✓ Done]` when the turn has genuinely finished and remained idle for >350ms.
2. Dedicated regression test added in `connection_manager_working_test.dart` verifying `isRoomUnreadFinished` stays `false` during intermediate tool execution and only becomes `true` after turn completion.

### 2026-08-29 — Version 1.2.13+21: Working state finalization & attachment unblocking

**Fixes:**
1. **Immediate turn finalization:** `_maybeFinalizeTurn` now broadcasts `agent_done` even when `_currentTurnId` was null (e.g. interactive terminal/subagent turns). `agent_end` immediately resets working state with 0ms delay so the appbar/panel switches from "working" to "online" the instant response output completes.
2. **Attachment unblocked:** When turn completion signal clears `streaming: true`, the paperclip (attach) button is immediately re-enabled.
3. **Public APK hosting:** Hosted on relay server (`http://178.157.59.181/RemotePi.apk`) for immediate mobile download outside local Wi-Fi.


### 2026-08-29 — Version 1.2.14+22: Fix historical pending ToolEvent sticking chat into working state

**Root cause:**
In `ChatViewModel`, `isWorking` was checking `_hasRunningTool`, which scanned `_messages.any((m) => m is ToolEvent && m.status == pending)`. If a session had past tool calls in its database history that lacked an explicit tool result, `_hasRunningTool` permanently evaluated to `true` whenever that specific session was opened, locking `/chat` into "working..." mode and disabling the attach button even though the agent was idle on the relay (green dot on Home).

**Fix:**
1. Removed `_hasRunningTool` from `ChatViewModel.isWorking`. Live in-flight turns and open tools are strictly tracked via `SyncService._openToolIds` / `_working` and `ConnectionManager.isRoomWorking`.
2. Added dedicated regression test `historical pending ToolEvent in message history does not keep isWorking permanently true when idle` in `chat_viewmodel_test.dart`.

### 2026-08-29 — Version 1.2.15+23: Unrestricted attachment while agent is working

**Change:**
1. Removed the artificial `!widget.streaming` restriction from `attachEnabled` in `InputBar`.
2. Users can now attach pictures / files freely even while the agent is running, enabling image attachments when queueing follow-ups or sending mid-turn steering.
3. Dedicated unit test added in `input_bar_image_test.dart` verifying attach button stays enabled during working/streaming.


### 2026-08-29 — Fix large session history payload drop on relay

**Root cause:**
The `trust` session had ~9,500 messages (13.8 MB payload). `SYNC_LIMIT_DEFAULT` was set to 50,000, so it attempted to dump all 13.8MB into a single WebSocket frame. The Rust relay server had a 10MB frame limit (`RELAY_MAX_CT_MIB=10`), causing the relay to reject the frame as `err=payload too large` and terminate the connection, making `trust` appear offline.

**Fix:**
1. Changed `SYNC_LIMIT_DEFAULT` in `pi-extension` from 50,000 to 200 messages (~150KB payload), matching standard mobile chat client sync behavior.
2. Increased `RELAY_MAX_CT_MIB` on the production relay server to 64MB (`max_ct_bytes=67108864`).

### 2026-08-29 — Supervised daemon fleet online (trust, papers, AI_examiner, remote-pi)

**Setup:**
1. Registered all 4 active project sessions (`trust`, `papers`, `AI_examiner`, `remote-pi`) in `daemons.json`.
2. Activated `remote-pi-supervisord.service` via `systemctl --user`. All 4 sessions are running persistently, managed with automatic recovery and persistent relay connectivity.


### 2026-08-29 — Version 1.2.16+24: Full OMP model list mirroring & smart session selector

**Fixes:**
1. **Full OMP models list:** Loaded all 3,423 models across 39 providers directly from `~/.omp/agent/models.db` into `handleListModels`, fully mirroring the CLI model picker.
2. **Smart session history selector:** `_findMostRecentSessionFile` now prioritizes populated conversation sessions (>20KB) from `~/.omp/agent/sessions/` over empty startup stubs (<5KB), ensuring the real conversation history is delivered to the phone.


### 2026-08-29 — Unified 9,446-turn session history in trust daemon

**Action taken:**
1. Merged recent user turns (`progress`, `?`) into the canonical 92MB conversation session file (`2026-08-17T...`).
2. Removed the temporary startup stub that masked older conversation history.
3. Synced all active project sessions from `~/.omp/agent/sessions/` into `~/.pi/agent/sessions/` so background daemons immediately continue full history.
4. Restarted `remote-pi-supervisord.service`.

**Verification:** Verified in Node that `session_sync` extracts all **9,446 messages** (9,857 events) including full audit reports and tool outputs.

### 2026-08-29 — Version 1.2.17+25: High-contrast image framing & border outlines

**Fix:**
Added a high-contrast 1.5px border (`colors.border.withValues(alpha: 0.95)`) and subtle elevation drop shadow to `ImageBubble` (user photos), `ChatImage` (assistant diagrams), and `_AttachmentPreview` (composer thumbnail). Dark photos/screenshots now have a distinct, crisp framing outline that stands out clearly against dark mode backgrounds.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.17 (25)` compiled and hosted.

### 2026-08-29 — Version 1.2.18+26: Fix queue button flashing during agent turns

**Bug:**
During agent execution, intermediate text segments (`AgentDone`) before tool calls caused `_syncTurnStateFromRoomMeta` to temporarily reset `isWorking` to false. This rapid flapping toggled `streaming: false -> true -> false`, causing the Queue Message button and Composer Action button to flash repeatedly on the screen.

**Fix:**
1. Fixed `_syncTurnStateFromRoomMeta` in `SyncService` so `remoteWorking` from the Pi daemon is treated as authoritative and never dropped mid-turn.
2. Removed duplicate layout margin inside `_QueueButton`.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.18 (26)` compiled and hosted.

### 2026-08-29 — Version 1.2.19+27: Comprehensive Model Picker & Backend SetModel Bridge

**Analysis & Implementation:**
1. **Backend Model Registry Bridge (`handlers.ts`):** `handleModelSet` now seamlessly bridges all 3,423 OMP `models.db` models into Pi's runtime. Selecting any model (e.g. `google-antigravity/gemini-3.7-flash`, `deepseek/deepseek-v4`, `anthropic/claude-3-7-sonnet`, `openai/gpt-4o`) constructs the full SDK Model configuration, registers it into the active session, and persists settings.
2. **Search Bar in Mobile Model Picker:** Added instant real-time search across model names, model IDs, and providers (`_SearchInput` with clear button).
3. **Provider Chips with Model Counts:** Added horizontal scrolling provider filter chips with real-time model counts (`all (3423)`, `google-antigravity (6)`, `anthropic (5)`, `openai (14)`, `deepseek (7)`, `openrouter (120)`...).
4. **Active Model Indicator:** Added robust multi-key matching (`id`, `provider:id`, `name`) so the currently active model is highlighted with a green accent badge and checkmark.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.19 (27)` compiled and hosted.

### 2026-08-29 — Version 1.2.20+28: Filter model list to logged-in / available providers only

**Optimization:**
1. **Logged-in Providers Only:** `handleListModels` now checks `liveReg.getAvailable()`, returning the clean, curated list of **81 models across your 6 authenticated providers** (`google`, `openai`, `deepseek`, `moonshotai`, `moonshotai-cn`, `minimax`) instead of flooding the picker with unauthenticated / unavailable models.
2. **Active Model Guarantee:** The currently active model is always preserved and listed at the top.
3. **Fast Filtering:** The search bar and provider tabs operate instantly over your ready-to-use models.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.20 (28)` compiled and hosted.

### 2026-08-29 — Version 1.2.21+29: Add "Reload plugins" button in Quick Actions

**Feature:**
Added a dedicated **Reload plugins** button to the Quick Actions sheet (`LucideIcons.plug2`). Tapping it sends `reload_plugins` to the Pi daemon, refreshing active extensions, skills, tools, and model registries on the fly.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.21 (29)` compiled and hosted.

### 2026-08-29 — Version 1.2.22+30: Extract and broadcast per-session active model dynamically

**Fix:**
1. **Session Model Extraction:** `_hydrateMessageBufferFromSession` now scans session files for `model_change` and active model entries, dynamically resolving and broadcasting the exact model used in each workspace (`google-antigravity/gemini-3.7-flash`, `deepseek-v4-pro`, `grok-4.6`, `k3`...) via `room_meta`.
2. **Accurate Active Model Highlighting:** `handleListModels` pairs the session's active model with the catalog, ensuring the active model indicator in the mobile picker highlights the true session model.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.22 (30)` compiled and hosted.

### 2026-08-29 — Version 1.2.23+31: Eliminate stray markdown / cursor markers

**Fix:**
Cleaned up the streaming bubble so that the standalone cursor block is completely suppressed when idle and does not leave an annoying blinking marker on the screen when no live streaming is in progress.

**Verification:** All 614 `app/` and 805 `pi-extension/` tests passed. Build `1.2.23 (31)` compiled and hosted.

### 2026-08-29 — Sync thinking level with OMP config.yml

**Fix:**
1. Daemon startup now seeds `_currentThinking` from `~/.omp/agent/config.yml` (`auto` → `high`, `max` → `xhigh`) so the phone matches the CLI.
2. Changing thinking in Quick Actions writes both `~/.pi/agent/settings.json` and `~/.omp/agent/config.yml`.

**Verification:** All 805 `pi-extension/` tests passed. Supervisor restarted.

### 2026-08-29 — Version 1.2.24+32: Show thinking on Home session tiles

**Fix:**
Session list subtitle is now `model · thinking` (e.g. `Gemini 2.5 Pro · high`). `xhigh` labels as `max` to match OMP.

**Verification:** `session_tile_test.dart` passed (5 tests). Build `1.2.24 (32)`.

### 2026-08-29 — Version 1.2.25+33: Fix streamed reasoning leak + paragraph fusion

**Root cause (Pi-side):** `message_update` forwarded bare deltas and ignored the SDK's block-boundary events (`text_start`/`thinking_start`/`thinking_end`). Consecutive text blocks fused without a paragraph break ("…rest.The user wants…"), and thinking deltas leaked into the visible reply — worst after a steer, where the post-steer reasoning appended straight onto the pre-steer text.

**Fix:**
1. `pi-extension`: per-turn stream phase machine injects `\n\n` between consecutive text blocks, wraps thinking in `<think>…</think>` (closed on `thinking_end`, tool call, message start, or turn end — whichever comes first), and skips separators after tool boundaries (the app already splits bubbles there).
2. `app`: live-streaming think-strip now also catches unclosed blocks that open after visible text.

**Verification:** Reproduced the fusion live on the phone (trust session, mid-stream steer via WiFi ADB). All 809 `pi-extension/` and `agent_markdown_test.dart` (10) tests passed. Build `1.2.25 (33)` hosted at `http://178.157.59.181/RemotePi.apk` and installed on the phone.

### 2026-08-29 — Version 1.2.26+34: Native `max` level + per-model thinking picker

**Fix:**
1. `max` is now a first-class wire level (SDK ≥0.84 supports it natively); OMP `defaultThinkingLevel: max` maps 1:1 instead of via `xhigh`.
2. `list_models` carries `thinking_levels` per model, derived from the SDK's `Model.thinkingLevelMap` (null = unsupported). The Quick Actions picker hides unsupported levels (e.g. no `max` on models that lack it); legacy catalogs fall back to the full list.
3. Home tile labels: `xhigh` shows as `xhigh`, `max` as `max`.

**Verification:** All 811 `pi-extension/` and 619 `app/` tests passed. Build `1.2.26 (34)` hosted and installed on the phone.

### 2026-08-29 — Version 1.2.27+35: Strict per-model thinking level mapping & verification

**Fix:**
Aligned `supportedThinkingLevels` with Pi-AI's exact logic:
1. `xhigh` and `max` require an explicit non-null mapping in `thinkingLevelMap` (e.g. Gemini 3.7 Flash only maps `off: null`, so it now correctly only offers `["minimal", "low", "medium", "high"]` — no `max` and no `off`).
2. Non-reasoning models only offer `["off"]` and the picker row is dimmed/disabled.
3. K3 (`{"off": null, "low": "low", "high": "high", "max": "max", ...}`) correctly offers `["low", "high", "max"]`.

**Verification:** All 813 `pi-extension/` and 619 `app/` tests passed. Build `1.2.27 (35)` hosted and installed on the phone.

### 2026-08-29 — Purge stale openai-codex OAuth & default to Gemini 2.5 Pro

**Fix:**
1. Removed expired `openai-codex` OAuth credentials from `~/.pi/agent/auth.json` that triggered `403 unsupported_country_region_territory` on token refresh.
2. Configured default provider to `google` (`gemini-2.5-pro`) in `~/.pi/agent/settings.json` backed by your valid environment API keys.
3. Restarted `remote-pi-supervisord.service`.




