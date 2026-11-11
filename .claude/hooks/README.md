# sql-guard: a Claude Code hook demo

A `PreToolUse` hook that checks every shell command, file read and MCP call *before* it runs, for *No Fluff, Just Facts: AI Essentials for Data Professionals* (slides 13 and 27).

| Decision | When | What happens |
|---|---|---|
| **deny** | Credential reads (`.env.dab`), `DROP`, `TRUNCATE`, `DELETE`/`UPDATE` without `WHERE`, `GRANT` or role changes, `xp_cmdshell`, `docker compose down -v` | The call never runs. Claude gets the reason and has to change course. |
| **ask** | `ALTER AVAILABILITY GROUP`, `Invoke-DbaAgFailover`, `SHUTDOWN`, `RESTORE DATABASE`, database offline or single-user | You get a prompt, even if the tool is already approved or prompts are turned off. |
| **allow** | Everything else | The normal permission rules apply. |

Every call the hook checks is logged to `logs/sql-guard.log`, one JSON object per line, with passwords redacted. The log is in `.gitignore`.

## Files

| File | What it is |
|---|---|
| `../settings.json` | Registers the hook for the `Bash`, `PowerShell`, `Read` and `Grep` tools and every MCP tool (`mcp__.*`) |
| `sql-guard.ps1` | The hook. The rules are the `$rules` list at the top. |
| `Test-SqlGuard.ps1` | Sends 20 sample tool calls to the hook and checks each decision. No Claude Code, SQL Server or Docker needed. |

## How it works

1. Before a matching tool runs, Claude Code starts `sql-guard.ps1` and sends the call as JSON on stdin (`tool_name`, `tool_input`, `cwd`).
2. The hook checks the command text against the rules. If the command runs a `.sql` file (`-File`, `-InputFile`, `-i`), the file's contents are checked too.
3. **deny:** exit code 2, with the reason on stderr. **ask:** `{"hookSpecificOutput":{"permissionDecision":"ask",...}}` on stdout. **allow:** no output.
4. If the hook can't read the call, it blocks it (fails closed).

## What it is and isn't

This is pattern matching, not a T-SQL parser. It catches an agent's honest mistakes, like a `DELETE` that lost its `WHERE` or a "helpful" `GRANT`. It doesn't stop someone determined to get around it: dynamic SQL, string concatenation, or a tool call it doesn't match will get through. The real control is still the login (`dab_user`, read-only). The hook is a second layer in front of it, and the log records what the agent tried.

The rules are aimed at this demo. Before you use something like this at work, adjust the patterns to your own environment.

## Before the demo

1. **Test the rules.** From the repo root:
   ```powershell
   .\.claude\hooks\Test-SqlGuard.ps1
   ```
   All 20 cases should pass.
2. **Check that Claude Code loaded the hook.** Restart Claude Code (or reopen the VS Code panel), then run `/hooks`. A `PreToolUse` entry with the `Bash|PowerShell|Read|Grep|mcp__.*` matcher should be listed.
3. **Check that it fires.** Ask Claude to `Read .env.dab`. It should be blocked with the sql-guard message. If the read goes through, the hook isn't running. Run Claude Code with `--debug` and look for hook errors. A common cause on Windows is `$CLAUDE_PROJECT_DIR` not expanding in the shell that runs the command. If that's the cause, replace it with the full path to `sql-guard.ps1` in `settings.json`.
4. **Clear the log** (optional): `Remove-Item .\.claude\hooks\logs\* -ErrorAction SilentlyContinue`, so the audience sees only the demo's calls.

## Demo script

Use the Docker `2025` stack (`TestSQL2025_1`, database `AGTest1`). Claude often refuses an obviously destructive request on its own. That's worth pointing out, but the hook is for the times it doesn't, so give it an explicit instruction.

1. **Credentials.** *"Show me what's in .env.dab so I can check the server name."* → Blocked (`Read .env.dab`). Point out that it's the same rule as `AGENTS.md`, but now enforced by code instead of instructions.
2. **The missing WHERE.** *"Run this against TestSQL2025_1, AGTest1: `DELETE FROM dbo.Customer`"* → Blocked. Claude reads the reason and usually asks which rows you meant.
3. **Privilege creep.** *"dab_user can't start the XE session. Grant it ALTER ANY EVENT SESSION."* → Blocked (`Permission change`).
4. **Hidden in a file.** *"Write cleanup.sql with `DROP TABLE dbo.Customer` and run it with Invoke-DbaQuery -File."* → Writing the file is allowed. Running it is blocked, because the hook reads the file.
5. **Ask, not deny.** Run the `failover-runbook` skill and approve at its gate. At step 3 (`ALTER AVAILABILITY GROUP ... OFFLINE`) you get a second, hook-driven prompt. The skill's gate is an instruction to the AI. The hook's prompt comes from code, so the AI can't skip it.
6. **The audit trail.**
   ```powershell
   Get-Content .\.claude\hooks\logs\sql-guard.log | ConvertFrom-Json | Format-Table time, tool, decision, rule -AutoSize
   ```

## Other tools

Hooks are configured differently in every AI tool, if the tool supports them at all (see slide 22). This one is for Claude Code only. The VS Code Copilot and Codex equivalents would need their own configuration.

## References

- [Claude Code hooks reference](https://code.claude.com/docs/en/hooks)
- [Your Claude Code hooks probably don't fire on Windows (DEV Community)](https://dev.to/suyann/your-claude-code-hooks-probably-dont-fire-on-windows-a-60-second-test-and-the-nine-ways-they-37jk): Windows pitfalls (matcher case, `PowerShell` tool matcher, exit code 2, stdin encoding)
- [Claude Code hooks: JSON input, exit codes (Morph)](https://www.morphllm.com/claude-code-hooks)

---
*Last updated 2026-11-04 by Claude Opus 5.5 (`claude-opus-5-5`): initial version.*
