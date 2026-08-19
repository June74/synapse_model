# SB-2026-08-19-005: Antigravity CLI authentication unavailable in sandbox

- **Status:** contained
- **First observed:** 2026-08-19
- **Last observed:** 2026-08-19
- **Symptom:** `agy models` and `agy agents` could not list models. The CLI reported that the user is not logged into Antigravity. Its sandboxed attempt to write application state and logs under `C:\Users\2006i\.gemini\antigravity-cli` was denied.
- **Confirmed:** `agy` is installed at `C:\Users\2006i\AppData\Local\agy\bin\agy.exe`, version `1.1.15`. Model discovery requires an interactive sign-in.
- **Correction:** Perform the Antigravity sign-in from the user's personal PowerShell session, then run `agy models`. Do not change filesystem permissions or place credentials in the repository.
- **Impact:** Google remains disabled in the registry until an exact model ID and a successful smoke test are available.
- **Security:** No credentials or tokens were collected or written to the repository.
