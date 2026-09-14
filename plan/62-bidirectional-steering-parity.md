# 62 — Bidirectional Steering Parity (Mobile ↔ Terminal)

## Context

When an agent is actively working, the user can steer the turn from either the terminal (CLI) or the mobile app (remote-pi). Currently, the two surfaces behave asymmetrically:

1. **Terminal → Mobile lag:** When the user types a steer in the terminal while a turn is active, `pi.on("input")` in `pi-extension/src/index.ts` encounters `if (_currentTurnId !== null) return;` and drops the input. Connected phones do not see the terminal steer in real time at all — it only surfaces retroactively via `session_sync` after the turn concludes.
2. **Mobile → Terminal lag:** When the user sends a steer from the phone, the extension calls `sendUserMessage(content, { deliverAs: "steer" })`, which queues into the agent loop. However, the terminal CLI does not render an optimistic user bubble on receipt (unlike terminal Enter, which calls `interactiveMode.addMessageToChat()`). The steer only renders in the terminal once the agent loop reaches a step boundary and dequeues it, making it feel "too late to appear".
3. **In-flight turnaround:** A steer queued while the LLM is actively streaming tokens must wait for the model to finish its current block before the steer takes effect unless a soft abort/interrupt is observed.

## Goal

Achieve behavioral and visual parity between mobile and terminal steering:
- Terminal steers typed during an active turn are immediately broadcast to connected mobile apps as `user_message` with `streaming_behavior: "steer"`.
- Mobile steers sent during an active turn are rendered immediately in the terminal TUI on receipt, rather than waiting for agent loop dequeue.

## Non-goals

- Do not alter the core agent loop's LLM generation streaming in `@oh-my-pi/pi-agent-core`.
- Do not change the relay protocol or wire format.
- Do not remove existing `steer_consumed` lifecycle events.

## Structure & Implementation

### 1. Terminal → Mobile Real-Time Mirroring (`pi-extension/src/index.ts`)

In `pi.on("input")`:
- Currently:
  ```ts
  if (_currentTurnId !== null) return;
  const turnId = `local_${randomUUID()}`;
  _currentTurnId = turnId;
  _broadcastToActive({ type: "user_input", id: turnId, text: event.text });
  ```
- Update:
  When `_currentTurnId !== null`, do NOT drop the event.
  Instead, recognize it as an active terminal steer:
  ```ts
  if (_currentTurnId !== null) {
    const steerId = `local_${randomUUID()}`;
    _broadcastToActive({
      type: "user_message",
      id: steerId,
      text: event.text,
      streaming_behavior: "steer",
    });
    return undefined;
  }
  ```
- The mobile app already parses `user_message` with `streaming_behavior: "steer"` and renders it as an optimistic/confirmed steer bubble without resetting the active streaming assistant bubble or changing the turn ID.

### 2. Mobile → Terminal Immediate Rendering (`pi-extension/src/index.ts`)

In `case "user_message"`:
- When `shouldSteer` is true, in addition to calling `_wakeAgent` with `{ deliverAs: "steer" }`:
- Call `_pi.sendMessage(...)` with a visible custom message or trigger optimistic TUI chat rendering so the CLI operator immediately sees the incoming phone steer above the running spinner/stream.
- Ensure the custom message is registered via `registerMessageRenderer` or filtered from subsequent LLM context so it does not duplicate tokens.

### 3. Verification & Regression Tests

- `pi-extension/src/extension.test.ts`:
  - Test: Terminal input while `_currentTurnId !== null` emits `user_message` with `streaming_behavior: "steer"` to peers.
  - Test: Terminal input while `_currentTurnId === null` emits normal `user_input` and sets `_currentTurnId`.
  - Test: Mobile steer message renders in TUI immediately and retains `_pendingSteers` correlation.
- Mobile app:
  - Verify phone receives and renders terminal steers mid-turn in real time.

## Definition of Done

1. Unit tests in `pi-extension` pass with full coverage of the new steering broadcast branches.
2. Typing a steer in the terminal while the agent is streaming renders the steer bubble on the phone immediately.
3. Sending a steer from the phone renders the steer bubble in the terminal CLI immediately upon receipt.
