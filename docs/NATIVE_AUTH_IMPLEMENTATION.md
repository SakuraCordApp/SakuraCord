# Native authentication implementation record

Observed and implemented on 17 July 2026. No live Discord credential was entered and no authenticated Discord request was made during automated testing.

## References

- Discord public documentation: API authentication, OAuth2, rate limits, and status/error codes. These documents cover bot/OAuth authorization and shared rate-limit semantics but do not document normal-account password login, fingerprint, MFA-login, or CAPTCHA routes.
- Paicord revision `694761c1938b73bb60bd58942674dfe73aab1135` (14 July 2026): complete native login UI, `LoginViewModel`, `MFAView`, `CaptchaSheet`, `RemoteAuthGatewayManager`, `DefaultDiscordClient`, and `ClientConfiguration` paths were reviewed.
- Swiftcord v1 revision `14465d927ebe1ba34b3befa00f9365fad7b56eb9`: no native password-login flow. It used a nonpersistent `WKWebView` and captured the authenticated web token, so it is recorded only as the legacy behavior SakuraCord removed.
- Current public Discord web build `579073`, build ID `da0a6c522614d5f65e35f81fe0163fa94db26df5`: static production assets show password login, MFA route construction, remote-auth initialize/cancel/login/finish routes, the `/ra/:remoteAuthFingerprint` handoff route, two route-level retries, current response fields, and metadata injection. The current official login page visually exposes QR login. Clean signed/notarized desktop host `0.0.401` was present. The locally launched renderer had third-party modifications and was excluded from request evidence.

## Comparison

| Behavior | Paicord pinned revision | Swiftcord v1 | Current public client assets | SakuraCord |
| --- | --- | --- | --- | --- |
| Pre-login identity | `GET /api/v9/experiments`; persist returned fingerprint | Web page owns it | Metadata layer supplies server-issued fingerprint when available | Same request; persists only the returned fingerprint |
| Password login | `POST /api/v9/auth/login` with `login`, `password`, `undelete: false` | Embedded web login | `POST /auth/login`; also models optional login-source and gift-code fields | Paicord body exactly; optional nil fields are omitted |
| Login headers | Desktop-shaped super properties, user agent, locale/timezone, fetch/origin headers, plus `X-Fingerprint` | Browser-owned | Super properties plus fingerprint and environment metadata when available | Same Paicord header shape with current observed Discord build/version and real Mac environment values; no authorization header |
| MFA | `POST /auth/mfa/totp`, `/backup`, or `/sms`; SMS send route | Browser-owned | Same route family; current payload can include `login_instance_id` | Same routes and ticket/code payload; includes issued `login_instance_id` |
| CAPTCHA | Shared HTTP callback covers both password and QR-ticket requests; user completes hCaptcha; replay with `X-Captcha-Key`, optional session ID and rqtoken, and the existing retry counter | Browser-owned | Challenge fields include `should_serve_invisible`; the shared layer keeps invisible checks out of the visible modal and supplies the solution headers | Same user-completed hCaptcha component for password and QR-ticket exchange; its web view starts invisibly and is revealed in-window only when the SDK emits an interaction event; replay headers, delay, and single challenge replay remain unchanged; no challenge bypass |
| Status retries | 429/500/502/504, at most three retries; header delay only up to six seconds, otherwise no retry; exponential fallback without a header | Browser-owned | Route wrapper shows bounded retries | Same Paicord status set, bounds, ceiling, and fallback |
| Session acceptance | Load current user before adding account | Web token intercepted then validated | Token becomes authenticated session | `GET /users/@me`, then Keychain store and provider bootstrap |
| Desktop QR session | Remote-auth v2 WebSocket; ephemeral RSA-2048 SPKI; OAEP-SHA256 nonce/user/token decrypt; `/ra/{fingerprint}` QR | QR was owned entirely by embedded Discord web login | Current assets expose the `/ra/:remoteAuthFingerprint` handoff and remote-auth route family; the public API docs do not document the WebSocket payloads | Same Paicord v2 opcode/crypto sequence with an ephemeral Security-framework RSA key and no embedded web view |
| QR ticket acceptance | One unauthenticated `POST /users/@me/remote-auth/login`; the shared CAPTCHA callback permits one user-completed replay; decrypt `encrypted_token`, then current-user lookup | Browser-owned | Current assets define the same login route and use the shared challenge layer | Same ticket body and unauthenticated header shape; retains the session RSA key across an interactive challenge, permits one user-completed replay, then uses the same validation and Keychain path as password login |
| QR cancellation/restart | Disconnect and create a new remote-auth session | Browser-owned | The official route family contains cancel | Discard the old socket/key and create a fresh session; cap automatic Paicord-style restarts at two, then require a visible user retry; never reuse a ticket or encrypted token |

## Request budgets

| Case | Expected requests |
| --- | --- |
| Cold successful login | 3: experiments, login, current-user validation |
| Warm successful login | 2: login, current-user validation |
| MFA login | Warm/cold count plus 1 MFA verification; SMS delivery adds exactly 1 explicit request |
| CAPTCHA login | Warm/cold count plus 1 challenge replay after successful user completion; only Paicord's remaining bounded status retries can add requests |
| Retriable 429/500/502/504 | Original plus at most 3 Paicord-policy retries |
| Cancelled/failed CAPTCHA | No replay |
| QR displayed, not scanned | 1 remote-auth WebSocket connection; no REST request |
| QR scanned, waiting for phone approval | Same WebSocket; no REST request from SakuraCord |
| QR approved | 2 REST requests: one ticket exchange and one current-user validation |
| QR approved with CAPTCHA | 3 REST requests: initial ticket challenge, exactly 1 user-completed replay, and 1 current-user validation |
| QR CAPTCHA cancelled or challenged again | Initial ticket request only when cancelled; 2 ticket requests when a completed challenge is rejected; no validation and no further replay |
| QR cancelled/expired | No REST request; at most 2 automatic replacement WebSocket sessions, then each user-visible fresh-code action creates 1 session |

The UI disables duplicate submission while an authentication action is in flight. Password data is encoded for the request and is never written to preferences, logs, fixtures, or Keychain. Only a validated session credential is placed in Keychain.

## Failure, restriction, and rollback

- Paicord's retry status set and delay decisions are the operational baseline. SakuraCord does not retry other statuses or exceed three retries.
- A CAPTCHA solution is generated only by Discord's hCaptcha flow and is replayed with Discord-issued challenge fields. Invisible checks remain attached to the login window without opening an empty sheet; if hCaptcha reports that interaction is required, SakuraCord reveals the same web view in a visible in-window verification panel. This applies to QR ticket exchange as it does in Paicord's shared HTTP client. Cancellation never sends another login request, and a second challenge after the completed replay stops the flow.
- Responses outside the implemented Paicord path are surfaced to the user without speculative probes. Sanitized tests cover method, path, headers, body, request count, challenge replay, and validation.
- After Discord returns a validated credential, an interactive login keeps its existing presentation alive until provider bootstrap finishes. The view therefore cannot cancel its own in-flight bootstrap during a root-state transition; success changes to the workspace once, while bootstrap failure remains visible on the same login screen. This changes no Discord request, header, retry, or request budget.
- QR contract tests use sanitized gateway payload fixtures and a mocked ticket exchange/current-user validation. Automated tests never open the remote-auth WebSocket. Visual testing may open one unauthenticated QR session but must not scan or approve it with an account.
- Rollback is localized: remove the native authenticator/view and restore the signed-out shell. Existing credentials remain isolated behind `CredentialStore` and normal launch still cannot fall back to mock data.
- This remains an unofficial normal-account client. Protocol parity reduces malformed or anomalous traffic but cannot guarantee that Discord will not restrict an account.
