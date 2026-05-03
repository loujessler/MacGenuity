# Contributing

Thanks for considering a contribution. The most valuable thing the project needs is **device-profile coverage** — every HyperX product family that has its own protocol quirks deserves its own profile.

This document covers the practical bits. The architecture itself is documented in [README.md](README.md), and the profile-authoring guide lives at [MacGenuity/Infrastructure/HID/Profiles/PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md).

## What we accept

| Kind | Notes |
| --- | --- |
| New device profiles | Highest priority. See [PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md). |
| Protocol fixes | Welcome — include a short note on how you confirmed the new packet shape. |
| UI / UX improvements | Welcome. Keep the menu compact. |
| New features | Open an issue first to discuss scope. |
| Refactors | Smaller is better. Don't bundle refactors with features. |

## Local setup

```bash
git clone <repo>
cd MacGenuity
./build.sh
open build/MacGenuity.app
```

Requires Xcode Command Line Tools only (`xcode-select --install`). No `Package.swift`, no Xcode project — every Swift file under `MacGenuity/` gets compiled by `build.sh`.

If you've already granted Input Monitoring once and want a fresh prompt:

```bash
tccutil reset ListenEvent com.local.macgenuity
```

For development without re-granting on every rebuild, see the **TCC and code signing** section in `README.md` (create a self-signed `MacGenuity Dev` cert in Keychain Access — `build.sh` picks it up automatically).

## Coding conventions

- **Layering.** UI never imports `IOKit` or `CoreAudio`. System APIs live in `Infrastructure/`. Models in `Domain/` are pure values. The view model orchestrates services through protocols.
- **Concurrency.** UI is `@MainActor`. HID I/O lives inside the `HyperXDeviceService` actor and is serialized. Don't introduce parallel HID writes.
- **Errors.** Throw a typed error from `Domain/Errors.swift`, not a stringly-typed one. Add a new case there if needed.
- **Logging.** Use `FileLogger.shared.{debug,info,warning,error}(.channel, "...")`. Don't `print`. Pick the right channel — log lines are filtered by channel in the diagnostics window.
- **No emoji** in code or commit messages unless the user asks.
- **No comments restating WHAT the code does.** Comments explain non-obvious WHY. Name things well instead.
- **No force unwraps** outside test fixtures.

## Submitting

1. Fork the repo, branch off `main`.
2. Make your change.
3. Run `./build.sh`. The build must produce zero warnings.
4. Test manually with your device (and ideally with the device pulled mid-poll — the app should not crash and should resume after replug).
5. Push and open a PR. In the description, include:
   - The device involved (VID/PID, product name).
   - What you tested.
   - A screenshot of **Menu → Diagnostics** showing the resolved profile, if relevant.

## Adding a device profile (5-line summary)

1. Copy `Infrastructure/HID/Profiles/DefaultHyperXProfile.swift` to `MyDeviceProfile.swift`.
2. Adjust packet bytes for your device.
3. Tighten `match(_:)` so it returns > 0.7 for *your* device only.
4. Add `register(MyDeviceProfile())` in `ProfileRegistry.init()`.
5. Open a PR.

The full guide: [MacGenuity/Infrastructure/HID/Profiles/PROFILES.md](MacGenuity/Infrastructure/HID/Profiles/PROFILES.md).

## Code of conduct

Be civil. Disagree about technical things, not about people.

## License

By contributing, you agree to license your contribution under the [MIT License](LICENSE).
