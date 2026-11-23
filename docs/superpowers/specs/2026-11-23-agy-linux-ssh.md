# Antigravity ACP on Linux SSH projects

Run Google's agy ACP with the connected SSH user via BaoCode's resumable remote process channel. Keep credentials entirely on the server, let the person complete Google's interactive authorization there, and never launch remote projects on the Windows host. Retain existing local kernel behavior and keep Linux preview work isolated from main and the Codex branch.

The project context remains an SSH locator inside BaoCode; agy receives only its host's absolute POSIX path and raw session ID. Catalogs, live sessions and preferences must keep host identities separate. The existing app-owned MCP tools can be reached only through an authenticated per-session loopback forward with clean teardown, not a public listener; tool gates and approval prompts still apply. Existing mobile transport should carry the same kernel, projects, events and images without credentials.

Verify desktop and mobile start/resume, streaming, approval, cancel, SSH interruption and reconnect, attachment and browser screenshot transfer, local regressions, and the Windows artifact. Distinguish scripted ACP fixtures from any real Google, SSH, Windows runtime, or paired phone test. No personal infrastructure is assumed available. Do not promise support for ACP capabilities the official CLI does not expose, such as upstream rewind/fork.
