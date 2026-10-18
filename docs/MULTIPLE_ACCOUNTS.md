# Multiple accounts per provider

Allowance Bar can track more than one account for every provider: a personal
and a work Claude Code login, two Cursor profiles, or several DeepSeek keys.
Each account is a separate provider with its own meter, its own visibility
setting (Auto/On/Off), its own menu bar toggle, and its own alerts.

Open **Settings → Providers**. Under each provider there is an
**<Provider> accounts** group with **Add account…**.

## Tools that keep their own login (Codex, Claude Code, Gemini, Cursor)

These tools keep one login per folder. A second account gets a second folder,
selected when you sign in. Allowance Bar never signs in for you; it shows the
command, and you run it in Terminal.

| Provider | Default folder | Suggested extra folder | Sign-in command |
|----------|----------------|------------------------|-----------------|
| Codex | `~/.codex` | `~/.codex-work` | `mkdir -p ~/.codex-work && CODEX_HOME=~/.codex-work codex login` |
| Claude Code | `~/.claude` | `~/.claude-work` | `mkdir -p ~/.claude-work && CLAUDE_CONFIG_DIR=~/.claude-work claude auth login` |
| Gemini | `~/.gemini` | `~/.gemini-work` | `mkdir -p ~/.gemini-work && GEMINI_CLI_HOME=~/.gemini-work gemini` (then choose Sign in with Google) |
| Cursor | `~/Library/Application Support/Cursor` | `~/.cursor-work` | `open -na Cursor --args --user-data-dir=~/.cursor-work` (then sign in inside that window) |

Keep using the same variable or flag whenever you use that account, for
example `CLAUDE_CONFIG_DIR=~/.claude-work claude`.

Folders in your home folder that match the suggested pattern and already hold
a login appear as "Found Claude account: work" with an **Add** button.

Where Allowance Bar reads each login:

- **Claude Code**: `<folder>/.credentials.json`, or the Keychain item Claude
  Code creates for that folder (`Claude Code-credentials-` plus a short hash
  of the folder path). The hash naming is not documented by Anthropic, so if a
  new Claude Code version changes it, the account shows "Not signed in".
- **Gemini**: `<folder>/.gemini/oauth_creds.json`.
- **Cursor**: `<folder>/User/globalStorage/state.vscdb`.
- **Codex**: see [CODEX_ACCOUNTS.md](CODEX_ACCOUNTS.md).

**Removing** one of these accounts only forgets the folder. It does not sign
out.

## API-key providers (Claude API, OpenRouter, DeepSeek, Kimi, Z.ai, Venice)

Click **Add account…**, enter a label, and save. The account appears as its
own section below with its own key field (or **Connect…** for OpenRouter).
Each key is stored separately in Allowance Bar's Keychain items.

**Removing** one of these accounts deletes its saved key from Allowance Bar.
It does not revoke the key at the provider.

## How accounts appear

| Where | Default account | Extra account labeled `work` |
|-------|-----------------|------------------------------|
| Dropdown section | "Claude" | "Claude — work" |
| Menu bar | `Cl 12%` | `ClW 40%` (first letter of the label) |
| Snapshot / CLI id | `claude` | `claude:<uuid>` |
