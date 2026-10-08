# Testing

Keep committed tests selective. They are production code with maintenance,
compile-time and execution costs. Start from the
[ownership map](ARCHITECTURE.md#find-the-owner), then choose the smallest boundary
that proves the important behaviour. [Development](DEVELOPMENT.md#build-and-verification)
lists package/full-validation commands and retained hang diagnostics.

## Choose the verification boundary

| Change | Existing starting point |
| --- | --- |
| REST body, sequence, retry or request budget | [ProviderRequestContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderRequestContractTests.swift) and the relevant [protocol topic](PROTOCOL_BASELINE.md#contract-map) |
| Authentication/bootstrap | [AuthenticationInstallationContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/AuthenticationInstallationContractTests.swift); [ProviderBootstrapContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProviderBootstrapContractTests.swift) |
| Gateway ordering, decoding, lifecycle | [GatewaySessionTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewaySessionTests.swift); [GatewayBacklogTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/GatewayBacklogTests.swift) |
| Inbox/Undo and read boundaries | [InboxContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/InboxContractTests.swift); [AccountReadStateModelTests.swift](../App/Tests/SakuraCordAppTests/AccountReadStateModelTests.swift); [InboxTests.swift](../App/Tests/SakuraCordAppTests/InboxTests.swift) |
| Friends, relationships or CAPTCHA replay | [RelationshipContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/RelationshipContractTests.swift); [FriendsListPolicyTests.swift](../App/Tests/SakuraCordAppTests/FriendsListPolicyTests.swift); [HumanCaptchaTests.swift](../App/Tests/SakuraCordAppTests/HumanCaptchaTests.swift) |
| Onboarding or Guide | [OnboardingContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/OnboardingContractTests.swift); [GuildCustomizationTests.swift](../App/Tests/SakuraCordAppTests/GuildCustomizationTests.swift) |
| Profile/settings edits | [ProfileEditingContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/ProfileEditingContractTests.swift); [ProfileEditorStateTests.swift](../App/Tests/SakuraCordAppTests/ProfileEditorStateTests.swift); [SettingsTransferTests.swift](../App/Tests/SakuraCordAppTests/SettingsTransferTests.swift) |
| Storage or account separation | [DatabaseTests.swift](../Packages/SakuraCordPersistence/Tests/SakuraCordPersistenceTests/DatabaseTests.swift) |
| Upload privacy | [UploadMetadataTests.swift](../Packages/MediaPipeline/Tests/MediaPipelineTests/UploadMetadataTests.swift); [UploadPrivacyContractTests.swift](../Packages/DiscordProtocol/Tests/DiscordProtocolTests/UploadPrivacyContractTests.swift) |
| Voice transport | [VoiceConnectionTests.swift](../Packages/MediaPipeline/Tests/MediaPipelineTests/VoiceConnectionTests.swift); [VoiceTransportTests.swift](../Packages/MediaPipeline/Tests/MediaPipelineTests/VoiceTransportTests.swift) |
| Visual-only change | Rendered app verification in the relevant [offline scene](DEVELOPMENT.md#launch-modes); no committed UI test. |
| Documentation-only change | Check claims against owners, local links/anchors, command syntax and `git diff --check`; no app rebuild solely for prose. |

## Focused protocol run

Run from the repository root. This example builds the protocol test product,
then executes one existing suite with the same cache, operation lock and bounded
diagnostics runner as the package script. Compilation has no three-minute test
execution deadline; the execution phase does.

```sh
bash <<'SH'
set -euo pipefail
source script/runtime.sh
sakuracord_acquire_operation_lock
trap sakuracord_release_operation_lock EXIT
swift build --package-path Packages/DiscordProtocol   --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" --build-tests
python3 script/run_test_diagnostics.py   --label DiscordProtocol --output-dir "$SAKURACORD_RUNTIME_DIR/test-diagnostics"   --events --timeout-seconds 180 --   swift test --package-path Packages/DiscordProtocol   --cache-path "$SAKURACORD_SWIFTPM_CACHE_DIR" --skip-build   --filter InboxContractTests
SH
```

Choose a suite actually declared in the test source, not merely a filename.
Check the executed test count: a successful command with no matched tests is
not verification. `script/test.sh` accepts package selectors, not arbitrary SwiftPM
filter arguments. For App and media packages use that script's staging path;
binary frameworks may need staging before SwiftPM can launch their test host.
Do not run build/test jobs concurrently in the same checkout.

## When to commit tests

Add or materially expand tests only for critical behaviour (credentials,
mutations, protocol, persistence, encryption, concurrency/lifecycle), major new
functionality, or a significant recurring regression with a focused deterministic
case. Search for equivalent coverage first; prefer extending or parameterizing
an existing test. Every case must protect a distinct production failure mode.

Do not commit tests for visual styling, spacing, animation, copy or icons; trivial
mappings/constants; private implementation choreography; mocks rather than real
behaviour; or an invariant already protected elsewhere. A small fix does not
require a new test by default. Temporary UI tests must be removed from the working
tree and index before committing.

## Test design and evidence

Use local sanitized fixtures, injected clocks and explicit synchronization gates.
Isolate filesystem, network and process state. Do not use fixed sleeps as
synchronization, mutable global test state or `nonisolated(unsafe)` fixtures.
Choose representative boundaries rather than every permutation. Delete obsolete
or duplicate coverage instead of perpetually extending it.

Without a new test, still run relevant existing checks or inspect the rendered
result. If automated visual inspection cannot establish correctness, request
user confirmation. Authenticated verification follows the
[protocol verification boundary](PROTOCOL_BASELINE.md#verification-boundary).
Report compilation, tests, packaging/signature checks, live-account behaviour and
visual verification separately; passing one does not establish the others.

## Translation verification

`TranslationTokenTests`, `AppleTranslationCoordinatorTests`, `TranslationFeatureTests`,
and `TranslationSettingsTests` use synthetic input and injected services. They need
no account, downloaded models, permission dialogs, or network translation. Gates
and stored task handles synchronize completions; cancellation-ignoring fakes test
request identity independently of cooperative task cancellation. Run the normal
`./script/code_quality.sh check` and `./script/ci.sh` on the required Xcode toolchain.
A source parse or isolated service test is not an application build or UI test.

For manual verification, build the offline fixture with
`./script/build_and_run.sh --offline`, obtain its exact bundle path from
`./script/runtime.sh`, and use only synthetic messages/drafts. Enable Translation
under Features and test Dutch→English, English→Dutch, Japanese/Korean→a supported
target, and short ambiguous text. Include repeated mentions/custom emoji, links,
code, multiline RTL/Unicode, and spoilers. Check selection, Copy Translation,
links/mentions, spoiler concealment/reveal, accessibility, incoming/outgoing bubbles,
light/dark modes, resizing, and returning to cached conversations. Exercise both
composers, translated edits and toggles, long-draft send validation, dismissal,
settings changes, and repeated same-pair requests.

On a test Mac, use System Settings > General > Language & Region > Translation
Languages to inspect model installation. Verify first-use approval and cancellation,
navigation/window closure during a download, and retry. With models already installed,
disconnect networking and repeat synthetic translation. Check the traditional-model
path on a Mac without Apple Intelligence. Do not remove a user's existing models
merely to run this check. Judge meaningful translation and exact protected-token
integrity, not a permanent golden output from a changing model. Record these runtime
checks separately from fake-based tests in the PR; unavailable checks remain unverified.
