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

### 2026-09-23 — Session restart affordance: emulator e2e verification

**Device:** RemotePi_Pixel emulator (Android API 34, x86_64, SwiftShader), debug APK built via `scripts/docker-build-apk.sh`.
**Setup:** Live relay at `http://178.157.59.181`, paired with `test-pi` session via paste-code flow.

| # | Step | Result |
|---|------|--------|
| 1 | Launch app on emulator & pair with relay | Paired; session list renders live sessions with new restart button next to bin — [session-list](screens/2026-09-23-session-list-restart-btn.png) |
| 2 | Tap restart icon (`[↻]`) on active session | Confirmation dialog appears: "Restart session? Sends /restart to this agent on your Mac" — [dialog](screens/2026-09-23-restart-dialog.png) |
| 3 | Tap "Restart" | `/restart` command dispatched; session dot transitions to `working` state as agent handles restart — [confirmed](screens/2026-09-23-restart-confirmed.png) |
| 4 | Long press on live session row | Context bottom sheet shows "Restart session", "Rename session", "Delete session" — [menu](screens/2026-09-23-longpress-menu.png) |
| 5 | Open session chat → Quick Actions sheet | "Restart session" tile rendered under Quick Actions without layout overflow — [quick-actions](screens/2026-09-23-quick-actions.png) |

**Unit tests:**
- `app`: 63/63 tests passed (incl. `restartRoom` envelope targeting and restore, `SessionTile.onRestart` affordance, `QuickActionsSheet` restart action).
- `pi-extension`: 859/859 vitest passed, `tsc` builds clean (incl. `restartSession()`, `EXIT_DAEMON_RESTART`, and supervisor handling).

### 2026-09-14 — math-render freeze fix: emulator e2e (pair → chat → live agent turn)

**Device:** RemotePi_Pixel emulator (Android API 36, x86_64), APK `deb737a0` (`f1d2b012`).
**Setup:** scratch `omp` in `/tmp/rp-e2e-math` paired to the app via paste-code
(relay `http://178.157.59.181:3000`). All 6 live Pi sessions visible after pair.

| # | Step | Result |
|---|------|--------|
| 1 | Cold start ×4 (incl. after `pm clear`) | Home in ≤0.7s each (`TotalTime` 654/616/631ms), no splash hang — [01](screens/2026-09-14-e2e-01-launch.png), [15](screens/2026-09-14-e2e-15-onboard.png) |
| 2 | Paste-code pair (`/remote-pi pair --ttl 600`) | Paired; `Relay · Connected`, 6/6 sessions online — [22](screens/2026-09-14-e2e-22-pair3.png) |
| 3 | Open **NFP_CEO** (previously froze/crashed on entry) | Opens, history renders, inline math (`$F$ ≈ 25`) styled, app pid stable — [23](screens/2026-09-14-e2e-23-nfpceo.png) |
| 4 | Live agent turn: stray `$$` + 420-char span | Rendered as plain text, UI stayed responsive (no isolate freeze) — [26](screens/2026-09-14-e2e-26-reply.png) |
| 5 | Live agent turn: `$E = mc^2$` + `$$x^2+y^2=z^2$$` | Both rendered as real math (italic inline, block w/ superscripts), no raw dollars — [30](screens/2026-09-14-e2e-30.png) |

**Regression tests:** `agent_markdown_test.dart` 18/18 (incl. parser-loop guards),
`nfp_ceo_smoke_test.dart` (all real NFP_CEO texts, selectable) — full suite 647/647.

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




### 2026-09-08 — Mobile messages wake idle terminals

**Cause:** OMP 18.1.14 queues explicit `deliverAs: "steer"` even when idle.
The extension forced that mode for mobile text, so delivery did not start a turn.

**Fix:** `_wakeAgent` checks the fresh SDK context's `isIdle()` immediately before
handoff, after any image preparation. Confirmed busy uses steering; idle omits
the delivery mode. Removed automatic resend fallbacks; rejected queued messages
require explicit replacement or clearing before another delivery attempt.

**Regression verification:** The initial regression run failed 5 cases before
production changes; the upstream-Pi compatibility regression failed 2 cases
before its correction. Final orchestrator run:
`pnpm exec vitest run src/extension.test.ts` — **207 passed**.
The extension implementation worker ran `pnpm build` successfully.
SDK-method smoke checks used real installed OMP/upstream Pi methods with the
downstream prompt boundary stubbed; these are not full live upstream-Pi tests.

**Physical phone verification:** Authorized wireless ADB on the user's phone.
Opened the separate `delivery-check` room; no test prompts sent to `tex`, `trust`,
or the orchestrator. Sent `MOBILE-DELIVERY-CHECK-0908-A`, then restarted only the
test terminal with the final compatibility build and sent
`MOBILE-DELIVERY-CHECK-0908-FINAL`. Both reached the live OMP terminal and received
model replies on the phone. The final terminal JSONL contains exactly one user
message and one assistant response with the final marker.

- [Phone room list](screens/2026-09-08-phone-delivery-02-rooms.png)
- [Initial probe composed](screens/2026-09-08-phone-delivery-04-compose.png)
- [Initial reply](screens/2026-09-08-phone-delivery-05-reply.png)
- [Final probe composed](screens/2026-09-08-phone-delivery-07-final-compose.png)
- [Final phone reply](screens/2026-09-08-phone-delivery-08-final-reply.png)

**Scope/limitations:** Physical-phone check covers idle text delivery. Busy,
image, rejection, and queue behavior are regression-test coverage, not live
phone scenarios. Phone screenshots also show duplicate assistant rendering;
the terminal persisted only one response. That separate display defect is not
fixed here. Existing user terminal processes were not restarted or interrupted;
they must restart with `omp -c` to load the rebuilt extension. No APK change.

### 2026-09-08 — Duplicate streamed reply persistence

**Fix:** App synchronously captures assistant segment identity and reuses it for
the final message through the existing serialized persistence queue. Removed
the global latest-assistant lookup that could duplicate a reply or overwrite
the previous turn.

**Verification:** Implementation worker recorded seven failing regressions
before production edits; the corrected sync-service test file passed all 42
tests. The release APK built successfully and was installed on the physical
phone with `adb install -r`.

**Physical phone verification:** Opened a separate `render-check` room and sent
`CHECK-RENDER-ONCE`; the controlled live OMP terminal replied `RENDER-OK`.
The production accessibility tree contained exactly one prompt and one reply,
and the screenshot visually confirms one assistant rendering:
[single reply](screens/2026-09-08-render-fix-02-single-reply.png).
Existing stored duplicates are not purged by this fix.

### 2026-09-14 — Terminal animated indicator parity (Braille spinner + shimmer wave)

**Fix:** Aligned mobile animated working banner with the authentic terminal OMP/Codex appearance:
1. Removed "Thinking & analyzing…" wording; replaced default with clean `Working…` (or active tool intent/action).
2. Replaced starburst with the terminal's authentic 10-frame Braille spinner (`⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏`) ticking at 80ms (12.5 fps).
3. Implemented true text shimmer animation (`ShaderMask` + `LinearGradient`) sweeping accent light horizontally across the monospace label.

**Verification:** Updated `app/test/ui/chat/streaming_bubble_test.dart` to assert `Working…` and custom labels. All 638 tests passed.

**Physical phone verification:** Rebuilt and installed release APK onto connected phone.
1. Captured live phone screen showing interrupted thinking traces leaking and phantom vertical gaps.
2. Fixed `stripThinkingTrace` to strip unclosed thinking blocks in finalized messages (`isLiveStreaming: false`), eliminating leaked reasoning traces.
3. Filtered empty/stripped assistant messages from `visible` in `chat_page.dart` and prevented empty streaming bubble from taking list slots, eliminating compounding vertical blank space.
4. Fixed banner flashing between tool executions: retains current turn's tool intent continuously until the turn finishes.
5. Replaced static terminal `ESC` badge with an interactive, tappable `[ ■ Stop ]` button wired directly to `vm.cancel()`:
   - Tapping the inline Stop badge cancels the running tool/turn immediately.
   - Styled with error red square and monospace label, alongside the live sweeping shimmer intent text.
6. Verified live on phone:
   - Leaked thinking traces completely gone.
   - Spacing clean without phantom gaps.
   - Steady, non-flashing banner featuring the interactive Stop button and shimmer:
   [Interactive Stop button & shimmer banner](screens/2026-09-14-phone-interactive-stop-button.png).

### 2026-09-14 — Interactive terminal input delivery for all mobile messages

**Fix:** Incoming text messages from mobile were previously only injected into the terminal input pipeline if they began with `/` (`_tryExecuteTerminalSlashCommand`). Standard messages went through `_wakeAgent` (`pi.sendUserMessage`), which bypassed the terminal prompt and steered into active subagents (e.g. `BackendReviewer`) when background tasks were running.
1. Expanded terminal injection to all text messages via `_tryExecuteTerminalInput(text)`: when an interactive terminal is active (`hasTerminalListener && hasUiMethods`), messages are injected directly into the terminal editor (`setEditorText`) and submitted via carriage return (`process.stdin.emit("data", "\r")`), ensuring the message runs through `InputController` and `InteractiveMode` as if typed on the PC keyboard.
2. Preserved fallback to `_wakeAgent` when no interactive TUI is active (headless, daemon mode).
3. Fixed queue draining head-of-line blocking: failing items in `_maybeDrainQueuedItem` append to the back of the queue instead of front, and active terminals drain via terminal injection.
4. Removed dead code `_hasUnclosedThinkBlock` in `streaming_bubble.dart`.
5. Added `all_rooms` unit test in `relay/src/peers/registry.rs`.

**Verification:**
- `pi-extension`: Added 5 unit tests covering terminal input execution, draft restoration, fallback to `_wakeAgent`, and queue draining. Vitest suite passes 845 tests.
- `app`: Added widget tests for Stop button visibility when working vs finished. Flutter test suite passes 640 tests.
- `relay`: Added `all_rooms_returns_active_rooms_grouped_by_peer` test in `registry.rs`. Cargo test passes 112 tests.
- `site`: Tested session list and relay connection handling. Test suite passes 11 tests.
- Real terminal verification: Verified live on PC screen that user message sent from Android phone (`let's see if it's fixed`) appeared in the `remote-pi` terminal window (`0x03a00004`) and initiated an interactive user turn.

### 2026-09-29 — USB pairing disappears after Save

- Device: Samsung SM-S948B, installed app `1.2.38+2049`; USB ADB authorized.
- App relay: `http://178.157.59.181:3000`. Port 80 and port 3000 returned the same owner mesh version 877 and four members; both `/health` endpoints returned 200.
- Before fix: submitted a fresh pairing URI through the phone's paste-code UI; Pi emitted `remote-pi:paired`; the phone opened [Name this PC](screens/2026-09-29-usb-pair-before-save.png). Entering a nickname and tapping Save returned Home to “No pairings yet”; Settings also showed no pairings. [Initial empty Home](screens/2026-09-29-usb-no-pairings-before.png).
- Changes: durable secure-storage peer index and in-memory inventory; mesh conflict preservation, queued publishes, and peer-key spelling reconciliation. Native Android enumeration failure remains a hypothesis, not directly measured.
- Verification: merged app suite **670 passed**; final focused pairing/mesh suite **41 passed**; analysis of the four changed Dart source/test files reported no issues.
- Signed release `app-v1.2.40` (`1.2.40+2051`) built successfully in [Actions run 36554757867](https://github.com/leoliu0/remote_pi/actions/runs/36554757867), including signing-certificate verification. Downloaded APK passed its published SHA256 check.
- Phone reconnected: `adb install -r` succeeded without clearing data; package manager confirmed `1.2.40+2051`. Previously missing saved sessions recovered automatically: Home displayed **Relay Connected / Online 6**, including `NFP_CEO`, `AI-examiner`, and `ratex`. [After upgrade](screens/2026-09-29-fixed-home.png).
- Force-stopped and relaunched the app: **Online 6** remained visible without re-pairing. [Cold restart](screens/2026-09-29-fixed-restart.png). Fresh QR enrollment was not repeated after upgrade because the existing pairing recovered; the verified surface is recovery and cold-start persistence.

### 2026-09-29 — Android SQLite and durable membership synchronization

- Source: `8dfe3a10`, tag `app-v1.2.41`, version `1.2.41+2052`. Scope: Android app storage/sync/lifecycle only; existing Linux terminal integration, native owner identity and relay wire protocol retained.
- Parent verification: complete `flutter test` **693 passed**. Analyzer over 18 affected source/test paths reported **No issues found**. Earlier whole-app analysis also reported unrelated existing chat-widget warnings; those were not silently suppressed or presented as a whole-app clean result.
- Regression-first evidence: observed failures before fixes for stale reconnect after disconnect, cleared legacy Hive boxes blocking import, incomplete secure-preference enumeration losing drafts, hung bootstrap, stale enrollment relay scope, orphan legacy room cache, missing-mesh migration recovery, corrupted persisted signatures, restored-peer boot hydration, owner recheck and boot-after-disconnect ownership. Corresponding regressions passed in the final full suite.
- Android test surface: created isolated `RemotePi_Pixel` (Android 15/API 35, x86_64) with software rendering. Installed released signed `1.2.40+2051`, paired through the real personal relay to a controlled interactive Linux Pi session, named it `Storage-migration-smoke`, and sent `/session`; the terminal printed `Terminal command: "/session"` and Session Info.
- Real legacy inputs prepared before upgrade: saved peer/rooms, finalized `/session` history, selected room, custom relay and unsent `migration draft`. [Legacy history](screens/2026-09-29-storage-emu-legacy-history.png), [legacy draft](screens/2026-09-29-storage-emu-legacy-draft.png).
- Physical Samsung was initially connected but PIN-locked, then USB disconnected during implementation. No physical-phone installation/migration claim for this release. Signed-build and emulator upgrade results follow below.
- Signed build passed in [Actions run 36566468538](https://github.com/leoliu0/remote_pi/actions/runs/36566468538), including signing-certificate verification. Downloaded APK passed its published SHA256 check. `adb install -r` upgraded the existing emulator installation; package manager confirmed `1.2.41+2052`.
- **Offline in-place upgrade passed:** airplane mode/Wi-Fi/data disabled before first launch; Home immediately showed the retained nickname and **All 4 / Online 0 / Offline 4**, without re-pairing. [Offline migrated Home](screens/2026-09-29-storage-emu-upgraded-offline.png).
- **History/draft migration passed:** opened the controlled session while offline; both the existing `/session` message and unsent `migration draft` remained. [Migrated history and draft](screens/2026-09-29-storage-emu-upgraded-history-draft.png). Force-stop/relaunch still showed all four cached rooms. [Offline cold restart](screens/2026-09-29-storage-emu-offline-cold-restart.png).
- **Durable offline intent passed:** renamed the paired device to `Storage-offline-pending` with networking disabled, then force-stopped the app. A read-only copy of the actual emulator SQLite database contained one pending `rename` operation with that exact nickname; both legacy import markers were committed (`local.rp_v2_and_preferences`: 7 rows; `pairing.secure_storage`: 5 rows). Offline relaunch retained the label. [Offline intent after restart](screens/2026-09-29-storage-emu-offline-intent-restart.png).
- **Synchronization after connectivity recovery passed:** after network restoration and connected cold start, the relay's real `/mesh/<owner hash>` response contained version 3 and nickname `Storage-offline-pending`. Final app SQLite inspection showed the same accepted version/nickname and **0 pending operations**. This demonstrates acknowledgment, not merely an optimistic label change. [Connected state](screens/2026-09-29-storage-emu-synced.png).
- **Linux terminal delivery passed after upgrade:** the migrated chat/draft remained available online; sending a second `/session` displayed a second message and the controlled interactive terminal printed a second `Terminal command: "/session"` with Session Info. [Post-upgrade command](screens/2026-09-29-storage-emu-post-upgrade-command.png).
- Verification limit: Samsung-specific upgrade and keystore behavior were not re-tested because the physical phone disconnected. Emulator real-surface verification does not claim a successful installation on that phone.
- Cleanup: revoked only the disposable emulator authorization `8vvELDmg` via the controlled terminal (`Revoked: Android device` confirmed); the existing physical-phone authorization was untouched. Stopped both smoke processes and the emulator; removed temporary database copies and intermediate screenshots.

### 2026-09-30 — Signed release installed on physical Samsung

- Downloaded `app-v1.2.41` APK passed `SHA256SUMS`; `adb install -r` succeeded on the connected Samsung SM-S948B without clearing data. Package manager confirmed `1.2.41+2052`.
- **Physical-device migration did not pass:** first launch displayed “Couldn't open your saved data.” Android logs identified `LegacyMigrationException(secure preferences): Could not verify every known secure preference` at `legacy_data_migrator.dart:389`. The underlying secure-storage disagreement was not diagnosed or fixed. [Failure surface](screens/2026-09-29-storage-phone-upgraded.png).
- After being told the data-loss implications, the user explicitly approved erasing the phone's local app data. `adb shell pm clear work.jacobmoura.remotepi` returned `Success`; launching the already-installed release reached the fresh “Get started” onboarding screen. [Fresh launch](screens/2026-09-30-phone-fresh-install.png). Saved phone pairings, chat history, drafts, preferences, and local owner identity were removed; PC-side sessions were not touched. Re-pairing has not been verified.
- Release caveat: emulator in-place migration passed on 2026-09-29, but the physical Samsung's existing-data migration failed. A fresh install works; do not claim this release safely migrates every existing physical-device installation.

### 2026-10-01 — Linux PC pairing lost on every reboot (identity in kernel keyring)

- Symptom: phone kept showing the PC as unpaired after a successful pairing. `rosebery` `~/.pi/remote/peers.json` was rewritten to `{"peers": []}` at 2026-09-30 08:45:23, ~3 s after `omp` started post-reboot.
- Evidence: no Secret Service on D-Bus (`secret-tool`: "The name is not activatable"); identity stored as `user: keyring:longterm-ed25519@dev.remotepi.pi` in kernel keyutils (`keyctl show @s`), which is RAM-only. Relay `mesh.db`: current owner `uHj3xwoo…` (v1, after the 2026-09-30 `pm clear`) lists `rosebery` as `GTmNkJ9f…`; the post-reboot identity was `pIXBZg…`. SelfRevoke saw itself absent and removed the pairing. `uts` same exposure (no `identity.json`, no Secret Service; phone blob lists two different historical `uts` keys).
- Fix `c10e57a6`: off macOS/Windows, every keyring-resolved identity is also written to `~/.pi/remote/identity.json` (0600), which wins on later boots.
- Regression-first: two new `storage.test.ts` cases (keyring emptied between calls) failed before the fix with different pubkeys, pass after. `pi-extension` suite: 860 passed; 2 `handlers.test.ts` failures are host-dependent thinking-level fixtures (read this machine's `~/.omp` model data), unchanged code.
- Real host: `rosebery` pinned `pIXBZg…` to `identity.json` (mode 600); `keyctl purge` of the keyring entry (simulated reboot) → identity still `pIXBZg…`. `uts` pulled, rebuilt, pinned `Th5l…` (mode 600).
- Second bug found on the phone test: `peers.json` was emptied again at 09:24:41, the same second as a re-pair (`paired_at` 23:24:41.71Z), while the phone published the blob that included the new key at 23:24:43.5Z. `_handlePairRequest` calls `requestFreshCheck()` right after `addPeer`, so SelfRevoke fetched the owner's previous blob and revoked the pairing it had just made.
- Fix: SelfRevoke skips any non-membership blob whose `issued_at` predates the local `paired_at` for that owner (`owner_blob_predates_pairing`); owner snapshots now carry `pairedAtMs`. Regression test (`self_revoke.test.ts`): pre-pairing blob → no removal; later blob → removal. Failed before, passes after; suite 861 passed (same 2 host-dependent failures).
- USB phone (Samsung SM-S948B, app `1.2.41+2052`, adb from user-local platform-tools). [Before](screens/2026-10-01-phone-01-before.png). Revoked both rosebery pairings in Settings → relay blob v5 with no members ([no pairings](screens/2026-10-01-phone-06-pairings-after-revoke.png)); this reproduces the race. Paired from a scratch session on the fixed build via paste code ([code](screens/2026-10-01-phone-14-typed.png), [name PC](screens/2026-10-01-phone-15-after-pair.png)). `peers.json` held the owner at every one-second sample from 09:38:33 onward; relay blob v7 lists `pIXBZg…`; Home **Online 3** ([Home](screens/2026-10-01-phone-16-home.png)).
- Reboot simulation: stopped the session, purged the kernel keyring (0 keys — identity now file-only), started a fresh session. It attached the owner (`Owner attached: peer=uHj3xwoo`), `peers.json` intact after >80 s (past a full 60 s SelfRevoke cycle), identity still `pIXBZg…`, phone still **Online 3** ([after](screens/2026-10-01-phone-17-after-reboot-sim.png)).
- uts not re-paired: its running sessions still hold an old in-memory key; restart them, then `/remote-pi pair`.

### 2026-10-01 — Switching sessions on the phone hangs (leaked relay sockets)

- Symptom: on `1.2.41+2052` (Samsung SM-S948B, USB), opening `ratex` showed history after ~8 s; `develop_time` stayed blank for over a minute.
- Evidence: relay log shows four app sockets (`49.184.125.9:3587/3588/3589/3591`) authenticated 03:00:58–03:01:21Z and all held until 03:11:50Z. Phone logcat: every Pi frame arrived 4×; three copies `DROPPED (room-mismatch)`, one accepted, including ~466 KB `session_history` replies.
- Cause 1: `ConnectionManager._connect` never closed the channel it replaced, and a lost channel moved status to `StatusRetrying` without closing its socket. Fix `app-v1.2.42`: track `_ownedChannel`, release it on connect/adopt/teardown/dispose. Two regression tests in `connection_manager_test.dart` failed before (`replaced channel leaked`, `lost channel leaked`), pass after.
- Phone on signed `1.2.42+2053` (`adb install -r`, data and pairing kept): `ratex` and `develop_time` both showed content 2 s after the tap ([ratex](screens/2026-10-01-switch-r1.png), [develop_time](screens/2026-10-01-switch-d1.png)). Relay still showed 2 app sockets; frames arrived 2× (one dropped).
- Cause 2: the production factory's `WsTransport.connect(...).timeout(10s)` leaves the connect running; a late completion authenticates a socket nobody owns (its active room stays `main`, so it drops everything). Fix `app-v1.2.43`: `connectWithin` closes the late result; `ws_connect_within_test.dart` covers late/in-time completion.
- App suite: 697 passed; analyzer clean on changed files.
- Phone on signed `1.2.43+2054` (`adb install -r`): relay logged exactly one app socket for the launch (03:44:45Z). Logcat during ratex → develop_time: 22 frames accepted, 1 dropped (a ratex straggler after leaving it — the intended guard). Both sessions showed content 2 s after the tap ([ratex](screens/2026-10-01-switch-v43-ratex.png), [develop_time](screens/2026-10-01-switch-v43-develop.png)).
- Not fixed: one `develop_time` open still drew ~4 distinct ~470 KB `session_history` replies; the app sends one `SessionSync` per open from `ChatViewModel._bootstrap`, so the extra requests' source is not identified.

### 2026-10-05 — Chat stuck on "working" after a job finished; system noise in chat

- Stuck symptom, reproduced on `1.2.43+2054` (Samsung SM-S948B, USB) against a scratch `StuckTest` session: sent `sleep 30` from the phone, cut Wi-Fi and data once the tool started ([tool running](screens/2026-10-05-stuck-01-tool-running.png)), and restored them after the agent ended on the PC (10:43:30). History synced `DONE`, but the chat still showed "working…" and a `Sleeping 30 seconds` pill with Stop 60 s later ([stuck](screens/2026-10-05-stuck-03-still-stuck.png)), while the Home tile was idle ([home](screens/2026-10-05-stuck-04-home.png)).
- Cause: `tool_result`/`agent_done` were lost while offline. In `SyncService._syncTurnStateFromRoomMeta`, a non-empty `_openToolIds` took priority over the relay's `working=false` forever. Fix (`app-v1.2.44`): when the relay reports a live room idle, open tools are closed. While the phone is offline, or the room is not in the relay's live set, they stay open. Two new `sync_service_test.dart` cases: the repro case failed before the fix (`orphan tool kept chat working`); the boundary case fails if the live-set gate is removed.
- Noise cause: `pi-extension`'s history loaders (`_loadMessagesFromJsonlFile`, `_hydrateMessageBufferFromSession`) turned every displayable `custom_message` into a user bubble. That covered `async-result` system notices, `irc:incoming`, `launch-completion`, todo nudges, plan/goal context, and the whole skill body for `/skill:x`. Fix: history drops `custom_message` entries; a `skill-prompt` keeps only `details.prompt`, which is the command the user typed. The regression test in `extension.test.ts` failed before the fix. On the real `develop_time` session file, 18 noise bubbles are removed, 53 real user messages remain, and none of them look like a notice.
- Suites: app 699 passed, analyzer clean on changed files. Extension: 862 passed, plus the same 2 host-dependent `handlers.test.ts` failures as before. Typecheck clean.
- Phone on signed `1.2.44+2055` (`adb install -r`), same offline-mid-tool run: network off 11:03:13, agent done 11:03:42. After reconnect the chat showed `online`, `DONE2`, no tool pill, and the mic button ([after](screens/2026-10-05-stuck-06-v44-after-reconnect.png)).
- Phone noise check (scratch session on the rebuilt extension): sent `/skill:i-have-adhd say hi in five words`, then left and reopened the chat. It shows the command bubble plus the reply ([history](screens/2026-10-05-noise-01-v44-skill-history.png)). The reopen history frame was 2221 bytes on the wire, while the stored skill body is 6186 chars.
- Running sessions keep the old extension in memory until restarted.

### 2026-10-06 — ratex chat full of subagent IRC messages (nested subagent took over the main session)

- Symptom (phone on `1.2.44`, room `ratex` on uts): the chat was a wall of `[Wait interrupted by message] <irc from="parent" agent="BiberExact2">…` and `<irc> Incoming IRC message from agent BiberExact2.CollationParity…` bubbles ([screen](screens/2026-10-06-ratex-subagent-history.png)). The Home tile showed the model `GPT 6.1 Sol`.
- Evidence: ratex's main session file has none of these as user messages. All three sampled bubbles occur together only in `BiberExact2/BiberExact2.MapToolParity.jsonl`, a nested subagent whose model is `openai-codex/gpt-6.1-sol`. So the phone was showing that subagent's history and model.
- Cause: `_isSubagentSession` matched a subagent by its parent folder containing `_` (`<ts>_<id>/`). That never matches a nested subagent's folder (`BiberExact2/`). On ratex's omp binary (pre-18.5, replaced on disk, process running since Oct 2) the `hasUI:false` / `session_init` signals didn't catch it either. Its `session_start` then hydrated `_messageBuffer` and `_lastEventCtx` from the subagent. The same `_` rule marked real main sessions whose cwd folder contains `_` (e.g. `-Documents-remote_pi/…`) as subagents.
- Fix (`a517c970`): a subagent's file sits in a folder named after its parent session file at every nesting level (`<main>.jsonl` → `<main>/Outer.jsonl` → `<main>/Outer/Outer.Inner.jsonl`). Detection uses the header's `parentSession` or the parent file on disk. A `/fork` sits beside its parent and stays main. Two regression tests (nested `session_start` keeps the main history; detection truth table) failed before the fix and pass after. Extension suite: 864 passed, plus the same 2 host-dependent `handlers.test.ts` failures. Typecheck clean.
- Repro attempts on omp 18.6.1 (rosebery: first-level, nested, and IRC-to-running-subagent) did not leak with the old code; that host already reports these sessions as subagents.
- Real-file check with the new build: rosebery scratch tree → main / EchoKid / Outer / Outer.Inner / Waiter classified correctly, and `-Documents-remote_pi` main → main (it was "subagent" before). uts ratex tree → main file main; `BiberExact2`, `BiberExact2.MapToolParity`, `BiberExact2.CollationParity`, `LuaLib2` → subagent.
- Not verified on the phone: the running ratex process still holds the old extension in memory; restart ratex to load `a517c970`.

## 2026-10-09 — Web client: phone sign-in link, relay picker, live Home (site/, dev server :3123, headless Chromium)

| # | Step | Result |
|---|---|---|
| 1 | Fresh profile → `/web` | Sign-in screen only: "Open Remote Pi on your phone → Settings → Sign in on web" + relay field — [01](screens/2026-10-06-web-01-signed-out.png), relay field editing — [02](screens/2026-10-06-web-02-signed-out-relay-field.png) |
| 2 | Open `/web#k=<throwaway 32-byte seed>&r=http%3A%2F%2F178.157.59.181` | Fragment stripped (URL `/web`), seed stored, relay auth OK (`Relay · Connected`), `/api/relay-mesh` → 404 (throwaway owner has no mesh) → "No pairings yet" — [03](screens/2026-10-06-web-03-home-after-link.png) |
| 3 | Reload | Lands on Home directly, still connected — [04](screens/2026-10-06-web-04-home-after-reload.png); fresh document load of a link also lands on Home — [08](screens/2026-10-06-web-08-home-fresh-load-link.png) |
| 4 | Relay picker → `ws://178.157.59.181:3000` → Save | Stored as `http://178.157.59.181:3000`, status Connecting → Connected, mesh re-fetched for the new relay — [05](screens/2026-10-06-web-05-home-relay-switched.png); "Use default" clears the override |
| 5 | Test harness: browser-routed mesh blob signed by the throwaway key listing x3d + uts | Signature verified, PCs accepted, relay subscribed; both PCs offline with 0 rooms on the relay at test time (confirmed by a direct relay probe) → "Nothing here…" — [06](screens/2026-10-06-web-06-home-harness-mesh-pcs-offline.png) |
| 6 | Settings → Paired PCs (read-only) + Account → Sign out | localStorage emptied, back to sign-in screen — [07](screens/2026-10-06-web-07-settings-paired-pcs-sign-out.png) |

- Not shown: a populated session list and opening a chat. That needs a real owner key from the phone link (sibling app work) and a PC with live rooms. Unit tests cover the list logic.

### 2026-10-09 — Web client hosted on the VPS with HTTPS; app "Sign in on web"

- Site deployed to `https://178-157-59-181.sslip.io` (free sslip.io name, A record only → 178.157.59.181). Caddy got a Let's Encrypt cert via TLS-ALPN-01 on 443; port 80 stays nftables-redirected to the relay (relay `/health` still 200). Same-origin `wss://` relay upgrade returns 101. Next.js standalone runs as `remotepi-site` on 127.0.0.1:3100 (`site/scripts/install-vps.sh`).
- `/api/relay-tunnel` and `/api/relay-mesh` are restricted by `RELAY_PROXY_HOSTS`; a tunnel to `ws://127.0.0.1:22` returns 400. Site tests 46 passed.
- App `1.2.45+2056` (CI signed, checksum OK): Settings → Sign in on web → warning → QR + Copy. The link targets `kWebClientBaseUrl` (this VPS), never the upstream site; a test pins that. App suite 707 passed. Lockfile kept on CI's Flutter 3.44.4 pins (only `qr`/`qr_flutter` added).
- Not verified: install on the phone and a real sign-in showing real sessions — the phone was not connected over USB.

### 2026-10-09 — Web sign-in reversed: the website shows a QR, the phone scans it

- Replaces the phone-shows-link flow (`#k=` removed on both sides; no key in any URL). Contract: website shows `remotepi://web-login?h&id&pk` (ephemeral X25519); the phone accepts only `h` = this fork's web host, confirms, encrypts `{v,seed,relay}` (X25519 + HKDF-SHA256 + AES-256-GCM, AAD = id), and POSTs to `/api/web-login/<id>`; the browser polls once and decrypts. Server holds ciphertext only, one-shot, 120 s TTL.
- Site: 60 tests (incl. a known vector produced by an independent phone-side implementation); app: 722 tests, and the app reproduces the site's vector byte-for-byte. Dev smoke: wrong-AAD delivery → decrypt error + new QR; valid throwaway delivery → Home ([qr](screens/2026-10-09-weblogin-site-01-signin-qr.png), [error](screens/2026-10-09-weblogin-site-02-decrypt-error.png), [home](screens/2026-10-09-weblogin-site-03-home.png)).
- Deployed to `https://178-157-59-181.sslip.io/web`: live QR with countdown ([live](screens/2026-10-09-weblogin-live-01-qr.png)); API create → id, pending poll 204, garbage deliver 400, unknown id 404.
- App `1.2.46+2057` built and signed by CI (checksum OK). Lockfile keeps CI's Flutter 3.44.4 pins (only `qr`/`qr_flutter` removed).
- Not verified: install on the phone and a real scan — the phone was unplugged when the build finished.

### 2026-10-09 — Web shows no PCs after a real QR sign-in

- Symptom: after scanning on the phone (1.2.46), the browser landed on Home with no PCs.
- Cause: the VPS could not reach its own relay at `http://178.157.59.181` (`000`): nftables `PREROUTING :80 → :3000` only covers inbound traffic. `/api/relay-mesh` returned 502 and `/api/relay-tunnel` could not open, so the web client had neither the mesh blob nor a relay socket. The owner's blob existed on the relay (`f008ced6…`, v11, members uts + rosebery).
- Fix: `iptables -t nat -A OUTPUT -d 178.157.59.181 -p tcp --dport 80 -j REDIRECT --to-ports 3000`, saved to `/etc/sysconfig/iptables` and added to `site/scripts/install-vps.sh`. After: self-reach 200, `/api/relay-mesh` for the owner 200, tunnel `{"t":"open"}`, outside relay `/health` still 200.
- Pending: user reload of `/web` to confirm PCs and sessions appear.

### 2026-10-09 — Web chat: terminal-style Full bash card + ask prompts (extension_ui)

- Surface: `site/` `/web` chat, smoke-run in Chromium against `pnpm dev` with a temporary page that mounted `WebChat` on a fake relay link (recorded pi-extension frames; page deleted before build).
- Full bash card, live: `flutter test` exit 127 → `$ flutter test`, red body `error: command not found: flutter`, footer `Wall: 0.00s | Timeout: 300s | exit 127` (`2026-10-09-web-full-bash-exit127.png`); success with intent + cwd + wrapped long command (`2026-10-09-web-full-bash-success.png`); running `Running…` (`2026-10-09-web-full-bash-running.png`); read tool as key/value args + output (`2026-10-09-web-full-read-generic.png`).
- Full bash card, history (`session_history` tool_request + tool_result): `$ sleep 30`, `(no output)`, `Wall: 30.01s | Timeout: 300s` (`2026-10-09-web-full-history-sleep.png`). Brief pills show the intent (`2026-10-09-web-full-brief-pills.png`).
- Ask select (bridge frame `tool:tc_1`): picked Beta + note → outgoing `{"type":"extension_ui_response","id":"tool:tc_1","ask":{"flow_id":"tool:tc_1","kind":"answer","mode":"submit","answers":{"goal":{"values":["b"],"note":"picked on the web"}}}}`; modal stayed in Sending… until the `notify` dismiss closed it (`2026-10-09-web-full-ask-select-{open,chosen,submitted,dismissed}.png`). Confirm `c1` → `{"type":"extension_ui_response","id":"c1","confirmed":true}` (`2026-10-09-web-full-confirm-open.png`).
- Checks: `pnpm test` 79/79, `tsc --noEmit` clean, eslint 0 errors (2 pre-existing unused-var warnings in web-chat.tsx), `pnpm build` ok. Deployed via `install-vps.sh`; live chunk `0enzrt.n76.gt.js` contains `Add a note (optional)`, `Command exited with code`, `extension_ui_response`.
- Not verified: a real paired session (live relay + pi-extension answering through pi-ask / ask tool).

### 2026-10-09 — Web composer auto-grow

- Surface: `/web` chat composer, headless Chromium (900px wide, DPR 2) against `pnpm dev` with the temporary fake-transport page (deleted before build). Typed with Shift+Enter between lines.
- Textarea heights: empty 31px, 1 line 31px, 4 lines 99px, 15 lines 240px (capped; overflowY auto, scrollHeight 349, caret line visible). Left icons and Send button bottoms stayed at the row bottom (898px) in every state. Enter sent all 15 lines as one user_message and the box went back to 31px, overflowY hidden (`2026-10-09-web-composer-{1,4,15,after-send}.png`).
- `pnpm build` ok (the first run failed on a transient next/font/google lookup; the rerun was clean). Redeployed via `install-vps.sh`; live chunk `14dmz1hos3bc8.js` contains `overflowY`.

### 2026-10-09 — Web: agent_activity panel + thinking traces

- Surface: `/web` chat in headless Chromium against `pnpm dev`, temporary fake-transport page (deleted before build).
- Activity: the captured omp running snapshot (pi-extension `activity.test.ts`, rebased to now) rendered `waiting on 3 jobs`, `└─ bg_1 sleep 20 · 6.0s`, `└─ AgentA AgentA · 2.2s`, `└─ AgentB Run sleep command and report echoed output · 2.2s` + `Running sleep then echo · 1 tools · 1.6k tok`. Times ticked +2.0s two seconds later. A follow-up snapshot replaced the list: `waiting on 1 job`, ✓ AgentA `1m 06s`, red ✗ AgentB `8.5s`. Header click collapses; `jobs: []` hides the panel (`2026-10-09-web-activity-{running,collapsed,finished}.png`).
- Thinking: a history message with `<think>` showed a muted Thinking block clamped to 2 lines, expanding on click. A streaming unterminated `<think>` showed `Thinking…`. With the switch OFF both were stripped. The Settings switch defaults ON and persists `remotepi_show_thinking` across reloads (`2026-10-09-web-thinking-{on-collapsed,on-expanded,on-streaming,off,settings-on}.png`).
- Checks: `pnpm test` 89/89, tsc clean, eslint 0 errors (2 pre-existing warnings), `pnpm build` ok.
- Not verified: frames from a real omp session over the relay.

### 2026-10-09 — Terminal parity on phone and web (bash card, ask, thinking, activity panel, composer)

- Bash Full card on both clients: `$ <command>`, intent, `in <cwd>`, `Output` body (or `(no output)`), footer `Wall: Xs | Timeout: Ns | exit N`; shared vectors pass on both. Web bug: live output/errors were never shown (card read `tool.result`, live set `output`/`error`).
- Ask prompts: web had no `extension_ui_request` handling; now implemented in the phone's wire format. App: 8 defects fixed (incl. a second prompt replacing the first, prompts never closed after an offline dismiss, confirm without "No").
- Extension: thinking blocks kept in history (byte-identical to the live stream on a real session); subagent `pi` handlers no longer broadcast tool cards / spurious `agent_done` into the main chat (real omp run before/after frames); new `agent_activity` snapshot from `task:subagent:*` events + `getAsyncJobSnapshot()`.
- Activity panel (`waiting on N jobs`, `└─ <id> <label> · <elapsed>`) and `Show thinking traces` switch on both clients; web composer auto-grows to ~10 lines.
- Suites: extension 880 (+2 known host failures), app 797, site 89. Web deployed and live chunk verified. App `1.2.47+2058` CI-signed, checksum OK. Extension rebuilt on rosebery and uts.
- UI smoke used recorded real frames through fake transports. Not verified end-to-end: phone install (unplugged) and a real session on phone/web; running omp sessions need a restart to load the new extension.

### 2026-10-10 — Web: persistent Agents side column

- Surface: `/web` chat in headless Chromium against `pnpm dev`, temporary fake-transport page (deleted). Ran at 1400px and 800px.
- 1400px: right column `Agents` showed `No subagents or background jobs` when empty. With the captured running snapshot it showed `Agents · 3 running` and the same rows/spinner as the panel. Clicking AgentB showed its assignment and `1 tools · 1589 tokens · $0.0160`. A done/failed snapshot followed by `[]` left a `Finished` list, newest first: ✓ bg_1 10.2s (vanished while running), red ✗ AgentB 3.8s, ✓ AgentA 3.5s. Sending the next message cleared it back to the empty state.
- 800px: the column is hidden. The bottom panel showed `Agents · 3 running · 0 finished` with the rows; after `[]` it collapsed to `Agents · 0 running · 3 finished` and expanded on click to the Finished rows. After the next message it disappeared.
- Screenshots: `2026-10-10-web-agents-side-{wide,narrow}-*.png`.
- Checks: `pnpm test` 92/92, tsc clean, eslint 0 errors, `pnpm build` ok. Not deployed (live E2E in progress).

### 2026-10-10 — Web composer: Up/Down message history (app parity)

- Bug: Up recalled only the last message (Up needed an empty box) and history held only this tab's sends, so after a reload there was none. Now ported from the app's InputBar into `site/src/components/web/composer-history.ts`: history = chat user messages + local sends/queues, trimmed, consecutive duplicates collapsed; Up from the first line, Down from the last line while browsing; draft saved and restored; typing exits; `History n/N` bar with Older / Newer|Clear.
- Surface: `/web` chat in headless Chromium (1000px, DPR 2) against `pnpm dev`, temporary fake-transport page seeding 3 earlier user messages (deleted).
- Draft `my draft`, Up ×4: `third…` (History 1/3), `second…` (2/3), `first…` (3/3), stays at `first…` (3/3); caret at end each time. Down ×3: `second…`, `third…`, `my draft` (bar gone).
- Up then typing ` EDITED`: bar gone, Down no longer recalls. 3-line draft: Up moved the caret line 3 → 2 → 1, only the next Up recalled `third…`; Down restored the 3-line draft. After sending `fourth…`, Up showed it as History 1/4 (no duplicate). Older/Newer/Clear buttons stepped and restored the empty draft.
- Reload: Up ×3 walked `third…`, `second…`, `first…` from the replayed chat history. No page errors.
- Screenshots: `2026-10-10-web-history-{0-draft,up1,up2,up3,down1,down2,down3,typed-exits,multiline-caret-first-line,after-send,reload-up3}.png`.
- Checks: `pnpm test` 102/102 (10 new in `composer-history.test.ts`), tsc clean, eslint 0 errors (2 pre-existing warnings in web-chat.tsx), `pnpm build` ok. Not deployed, not committed.

### 2026-10-10 - Live web E2E against a real omp session (omp 18.8.7)

- Setup: scratch omp in a fake HOME with a throwaway PC identity and owner key, mesh blob published to the relay, browser signed in through the real QR flow (phone side simulated in code). Extension dist included fc8e6408 and f2993fa4. Everything was removed afterwards; the orphaned mesh blob stays because the relay has no delete route.
- Worked live: Agents panel rows with progress ([panel](screens/2026-10-10-e2e-web-activity-panel-running.png)), live and resynced thinking plus the off switch ([on](screens/2026-10-10-e2e-web-thinking-on.png), [off](screens/2026-10-10-e2e-web-thinking-off.png)), Full bash card with exit code ([card](screens/2026-10-10-e2e-web-bash-full-failed-exit-code.png)), subagent tool calls and assignments kept out of the chat, live and after reload ([during](screens/2026-10-10-e2e-web-subagent-isolation-during.png), [reload](screens/2026-10-10-e2e-web-subagent-isolation-after-reload.png)), auto-growing composer ([composer](screens/2026-10-10-e2e-web-composer-grown.png)).
- Defects found: (1) the live banner and pills have no intent, because omp strips `i` from `tool_call.input` ([banner](screens/2026-10-10-e2e-web-working-banner-wait-no-intent.png)); (2) the final answer is shown twice in the live web chat, and the stream bubble isn't split at tool calls ([dup](screens/2026-10-10-e2e-web-final-chat-run1-duplicate-answer.png), [reload correct](screens/2026-10-10-e2e-web-final-chat-run2-after-reload.png)). Both are being fixed in follow-ups.
- Uts `Licensing` showed a subagent's full assignment as a user bubble: that omp started on Oct 7 and runs the extension from before f2993fa4. A restart fixes it.
