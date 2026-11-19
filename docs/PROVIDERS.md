# Providers

How Allowance Bar reads each provider, and how to set up the ones that need
a key or a proxy. For several accounts of one provider, see
[MULTIPLE_ACCOUNTS.md](MULTIPLE_ACCOUNTS.md); for Codex accounts in detail,
see [CODEX_ACCOUNTS.md](CODEX_ACCOUNTS.md).

## How usage is read

| Provider | Source | How usage is read |
|----------|--------|-------------------|
| **Codex** (`Cx`, `CxW`, …) | Your own Codex CLI via its app-server protocol; session logs as offline fallback | Live limits, plan, and signed-in email, polled every 5 minutes through a ~1-second `codex app-server` call. **Multiple accounts**: sign in extra Codex homes and each gets its own meter. Optional subscription renewal-date tracking with reminders. See [CODEX_ACCOUNTS.md](CODEX_ACCOUNTS.md). |
| **Cursor** (`Cu`) | `cursor.com/api/usage-summary` | Uses the session token Cursor stores locally; included/auto/API usage + billing reset. Team/enterprise pools supported. |
| **Claude** (`Cl`) | `api.anthropic.com/api/oauth/usage` | Uses the Claude Code OAuth token (credentials file or Keychain via Apple's `security` tool); 5h and weekly limits, plus each model's own weekly limit (Fable). Can ask a [CLIProxyAPI](#cliproxyapi) server instead when that token has expired. |
| **Claude API** (`ClA`) | Anthropic organization Usage & Cost API | Paste an organization reporting key; shows current UTC calendar-month spending and input/output/cache tokens. Prepaid credits are unavailable via the public API; a link opens Console billing. |
| **Gemini** (`Ge`) | Cloud Code quota API | Uses the Gemini CLI OAuth token (`~/.gemini/oauth_creds.json`); Pro/Flash/Flash-Lite daily quotas. |
| **Muse Code** (`Mu`) | Your own Muse Code CLI via its `muse serve` protocol | Meta's coding agent. Shows the subscription's 5-hour and weekly limits and plan, read every 5 minutes through a ~1-second `muse serve` call that spends no prompt. Muse Code reads its own Meta login; Allowance Bar never sees it. Only subscriptions report limits: an API key or pay-as-you-go account shows a message instead, because Meta has no balance API. |
| **Antigravity** (`Ag…`) | Cloud Code quota summary, through [CLIProxyAPI](#cliproxyapi) | Only for Antigravity logins on a CLIProxyAPI server; 5-hour and weekly limits for each model group. |
| **OpenRouter** (`OR`) | `openrouter.ai/api/v1/credits` + `/api/v1/key` | Connect via OAuth (provisions a dedicated, revocable key) or paste a key; shows account credits when permitted, otherwise the key's limit/remaining balance or current-month spend. |
| **DeepSeek** (`DS`) | `api.deepseek.com/user/balance` | Paste an API key; shows prepaid balance. |
| **Kimi** (`Ki`) | `api.moonshot.ai/v1/users/me/balance` | Paste an API key; shows available balance. |
| **Z.ai** (`Zg`) | `api.z.ai` quota API | GLM Coding Plan only: paste the plan's API key to show time/token quota percentages. Z.ai does not expose standard pay-as-you-go balance via a public API. |
| **Venice** (`Ve`) | Venice billing / key rate-limit APIs | Paste an Inference or Admin API key; shows USD/DIEM balance. Admin keys use the richer billing endpoint, while safer Inference keys use the rate-limits balance fallback. x402 wallet balances are not supported. |

Subscription-style providers show percent-of-limit meters; pay-as-you-go
(API-key) providers show reported balance or spending, since there is no limit
percentage to measure.

Each provider can be set to **Auto** (show only if detected on this machine),
**On**, or **Off** in Settings, and shown or hidden in the menu bar
independently. Refresh runs every 30s/1m/5m (configurable); Codex also
refreshes instantly after CLI activity via a file watcher, and the app
refreshes on wake.

## Claude API setup

In **Settings → Providers → Claude API**, save an organization Admin API key
or an eligible personal/service-account key that is not scoped to a workspace.
Allowance Bar stores the key in its own macOS Keychain item and only sends read-only
report requests to Anthropic. Ordinary workspace keys and individual accounts
cannot use the reporting API. These reports cover the organization, not just
requests made with the saved key. Claude Code subscription limits remain in the
separate **Claude** entry.

Spending covers the current calendar month in UTC, excludes Priority Tier
costs, and may lag the Anthropic website. Allowance Bar shows the returned report
cutoff and flags when today's totals are not yet fully reported. "Last checked"
means when Allowance Bar fetched the report, not how current Anthropic's data is.
Reports are cached for five
minutes during automatic polling. The Refresh button and `allowancebar refresh`
bypass that cache; after an API failure, retries wait one minute. Input tokens
exclude cache reads and cache creation, which have their
own rows. **Prepaid credits are not inferred from spending**: use the billing
link to see the actual credit balance. See Anthropic's
[Usage & Cost API](https://platform.claude.com/docs/en/manage-claude/usage-cost-api)
and [API billing guide](https://support.claude.com/en/articles/8977456-how-do-i-pay-for-my-claude-api-usage).

## CLIProxyAPI

If you pool accounts in
[CLIProxyAPI](https://github.com/router-for-me/CLIProxyAPI), Allowance Bar
shows every Claude, Codex, Antigravity and Gemini login on the proxy, each as
its own row. Nothing else to set up per account:

1. In **Settings → Providers → CLIProxyAPI**, enter the server address
   (default `http://127.0.0.1:8317`) and the proxy's management key
   (`management.secret-key` in its config). The key is saved in Allowance
   Bar's own Keychain item.
2. Each turned-on login appears as a row such as `Codex — you@example.com`,
   next to that provider's other accounts. Antigravity rows follow Gemini.
   Logins you add or remove on the proxy appear or disappear on the next
   refresh. Each ChatGPT workspace of one email gets its own row. Proxy rows
   stay out of the menu bar title until you turn them on there, unless no
   other row is in it. Each row shows its plan: Claude's from the login's
   profile, Gemini's and Antigravity's from Google's tier name (asked every
   few hours), Codex's from the login list.
3. A login with the same email as an account on this Mac shows only once,
   through the local account (for Codex, the plan must match too). If the local account has no data or keeps
   failing for 10 minutes, the proxy row shows instead. Set a proxy row to **On** to always show both.
4. Each account shows its place among its provider's logins in the proxy's
   order of use, from the login priorities: **Proxy #1** next to the plan, **#1** in the compact and
   nano panels. The proxy sends new requests to the highest priority first,
   and equal priorities share a place. Accounts on this Mac show the place
   of the proxy login with the same email. It appears when the proxy has more
   than one login of a provider with different priorities. Turn it off in
   **Settings → Display**, for all views or only for the nano window.
5. To use a proxy on another Mac, set `management.allow-remote: true` in the
   proxy's config. Use an `https` address or the proxy Mac's Tailscale name
   (ending in `.ts.net`). Allowance Bar refuses plain `http` to other hosts,
   including raw `100.x` addresses, because the key could cross a network
   unencrypted.

The proxy's
[management API](https://github.com/router-for-me/CLIProxyAPI/blob/main/internal/api/handlers/management/api_tools.go)
sends each usage request with the login's token on the proxy's machine, so
Allowance Bar never receives a token. These are the same requests the proxy's
own dashboard makes: ChatGPT's Codex usage, Google's Antigravity quota summary,
the Gemini CLI quota and Anthropic's Claude usage. Proxy rows ask at most every
two minutes; the Refresh button asks right away. If the proxy rejects the key,
Allowance Bar stops asking it until you change the key or address, so a wrong
key can't get your Mac banned by the proxy.

**Claude Code through the proxy.** When Claude Code sends its requests
through CLIProxyAPI (`ANTHROPIC_BASE_URL` points at the proxy), it stops
renewing its own login, and its token expires after a few hours. The
**Claude** rows for accounts on this Mac then read their usage through the
proxy login with the same email. If the emails differ, pick the proxy login
for each account in the same Settings section.
