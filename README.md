# Codex Pulse

![Codex Pulse](preview.png)

Codex Pulse is a dependency-free Windows widget for ChatGPT/Codex subscription usage.

- Reuses `%USERPROFILE%\.codex\auth.json`; no second login or API key.
- Detects Plus, Pro 5×, Pro 20×, Business, Enterprise, and Free where exposed.
- Displays every quota window returned by Codex, with remaining percentage and reset countdown.
- Shows local token telemetry and a clearly-labelled rough token-equivalent remainder.
- Uses the live usage service with an automatic fallback to Codex's latest local rate-limit snapshot.
- Keeps the access token local and sends it only to `chatgpt.com`.

Double-click `Start Codex Pulse.vbs`. It launches the included `CodexPulse.ps1` without a console window. Keep the two files together.

OpenAI does not define subscription allowance as a single fixed token bucket. Usage percentages and reset timestamps are authoritative; the remaining-token figure is an estimate.
