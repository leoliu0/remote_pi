// omp plan mode wire frames captured against omp 18.9.2 (scratch session
// 2026-10-12), copied verbatim from the plan-capture contract. The capture
// abbreviates the review id as `plan-review:…` in the answer/close examples;
// here it is spelled out as the id of the captured review request.

const kPlanReviewId = 'plan-review:toolu_019RaxgagFLMnWDaT826y9KG';

/// Plan review request (server → client).
const kPlanReviewRequestFrame =
    r"""{"type":"extension_ui_request","id":"plan-review:toolu_019RaxgagFLMnWDaT826y9KG","method":"select","title":"Plan ready for review: hello-txt","options":["Approve and execute","Approve and compact context","Approve and keep context (~19k / 1m)","Refine plan","Save and quit"],"plan":{"plan_file_path":"local://hello-txt-plan.md","title":"hello-txt","content":"# Create hello.txt\n\n- Create the new file `/tmp/pm-e2e/proj/hello.txt` with the `write` tool. The file does not exist yet, so nothing gets overwritten.\n- Content: exactly `hello plan` plus one trailing newline (`hello plan\\n`), and nothing else.\n- Verify in `/tmp/pm-e2e/proj`: `printf 'hello plan\\n' | cmp - hello.txt` exits 0 and prints nothing.\n","options":[{"action":"approve_execute","label":"Approve and execute"},{"action":"approve_compact","label":"Approve and compact context"},{"action":"approve_keep","label":"Approve and keep context (~19k / 1m)"},{"action":"refine","label":"Refine plan"},{"action":"save_quit","label":"Save and quit"}]}}""";

/// Client answers.
const kPlanApproveExecuteFrame =
    r"""{"type":"extension_ui_response","id":"plan-review:toolu_019RaxgagFLMnWDaT826y9KG","plan":{"action":"approve_execute"}}""";
const kPlanRefineFrame =
    r"""{"type":"extension_ui_response","id":"plan-review:toolu_019RaxgagFLMnWDaT826y9KG","plan":{"action":"refine","feedback":"Also print the file with cat afterwards."}}""";
const kPlanCancelFrame =
    r"""{"type":"extension_ui_response","id":"plan-review:toolu_019RaxgagFLMnWDaT826y9KG","cancelled":true}""";

/// Close of the review (same-id notify).
const kPlanCloseFrame =
    r"""{"type":"extension_ui_request","id":"plan-review:toolu_019RaxgagFLMnWDaT826y9KG","method":"notify","message":"Plan approved."}""";

/// Warning notify: keeps the review open with the message.
const kPlanWarningFrame =
    r"""{"type":"extension_ui_request","id":"plan-review:toolu_019RaxgagFLMnWDaT826y9KG","method":"notify","message":"Plan mode is no longer active","notify_type":"warning"}""";

/// Plan state (server → client).
const kPlanStateReviewFrame =
    r"""{"type":"plan_state","status":"review","plan_file_path":"local://hello-txt-plan.md","title":"hello-txt"}""";
const kPlanStateActiveFrame = r"""{"type":"plan_state","status":"active"}""";
const kPlanStatePausedFrame = r"""{"type":"plan_state","status":"paused"}""";
const kPlanStateIdleFrame = r"""{"type":"plan_state","status":"idle"}""";

/// Plan mode commands (client → server) and their replies.
const kPlanModeEnterFrame = r"""{"type":"plan_mode","id":"<id>","action":"enter"}""";
const kPlanModeExitFrame = r"""{"type":"plan_mode","id":"<id>","action":"exit"}""";
const kPlanModeReviewFrame =
    r"""{"type":"plan_mode","id":"<id>","action":"review"}""";
const kPlanModeOkFrame =
    r"""{"type":"action_ok","in_reply_to":"<id>","action":"plan_mode"}""";
const kPlanModeErrorFrame =
    r"""{"type":"action_error","in_reply_to":"<id>","action":"plan_mode","error":"…"}""";
