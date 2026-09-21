# AirToggle

Switch your AirPods between **Noise Cancellation**, **Transparency**, **Adaptive** and **Off**
with one global keyboard shortcut on your Mac. Default shortcut: **⌃⌥A** (Control + Option + A).

A tiny menu bar app: one Swift file, no dependencies, under 1 MB, no Dock icon.
Works on macOS 14 and later, Apple silicon and Intel. Tested on macOS 27 with AirPods Pro.

## Install (beta)

**Option 1 — one line in Terminal** (downloads the latest release, installs to /Applications, opens it):

```bash
curl -fsSL https://raw.githubusercontent.com/ben-medpro/AirToggle/main/install.sh | bash
```

**Option 2 — manual.** Download `AirToggle-<version>.zip` from the
[Releases page](https://github.com/ben-medpro/AirToggle/releases), unzip, and drag `AirToggle.app`
to Applications. Because this beta is not notarized by Apple, the first open needs one extra step:
**right-click AirToggle.app → Open → Open**. (If macOS only offers "Move to Trash", open
System Settings › Privacy & Security, scroll down, and click **Open Anyway**.)

### First launch

AirToggle asks for a single permission, **Accessibility** (called *Device Control and Data Access*
on macOS 27). A welcome window explains it and opens the right Settings pane; switch AirToggle on
there and the window closes by itself. That is all the setup.

Why this permission: macOS offers no API for AirPods listening modes, so AirToggle operates
Control Center's Sound menu for you, the same clicks you would make by hand, only instant.
You will see the Sound popover flash for a fraction of a second when you toggle.

## Use

- Press **⌃⌥A** to toggle. A small HUD shows the new mode.
- Click the **ear icon** in the menu bar to pick a mode directly, change the shortcut
  (*Shortcut › Change Shortcut…*, then just press the keys), choose which modes the shortcut
  cycles through, or enable *Launch at Login*.
- **Settings window:** double-click AirToggle in Finder while it is running. Handy if a menu bar
  manager hides the icon.
- Scriptable while running (Raycast, Shortcuts, Keyboard Maestro):

  ```bash
  /Applications/AirToggle.app/Contents/MacOS/AirToggle --toggle
  ```

  Other commands: `--anc`, `--transparency`, `--adaptive`, `--off`, `--status`, `--settings`.

Log file: `~/Library/Logs/AirToggle.log`.

## Known issues (beta)

- **Bartender 7 on macOS 27** hides the AirToggle icon while Bartender is running. The hotkey and
  the settings window (double-click the app) keep working. Reported to Bartender; details in
  [BARTENDER-REPORT.md](BARTENDER-REPORT.md).
- English macOS only for now: modes are matched by their Control Center labels.
- If the Sound item is hidden from your menu bar, AirToggle goes through the main Control Center
  item instead; that path is slower and less tested.

## Build from source

Requires Xcode Command Line Tools (`xcode-select --install`).

```bash
./build.sh --install     # build for this Mac, install to ~/Applications, launch
./build.sh --release     # universal, ad-hoc-signed zip in ./dist for distribution
```

Local builds are ad-hoc signed, which makes macOS treat every rebuild as a new app for the
Accessibility permission. Run `./make-signing-cert.sh` once to create a local signing certificate;
`build.sh` then signs with it and the permission survives rebuilds.

## How it works

Everything is in [`Sources/main.swift`](Sources/main.swift): a Carbon global hotkey, an
Accessibility-API driver for Control Center's Sound menu (finds the mode buttons by label, reads
which one is checked, presses the target, closes the menu), a HUD, the menu, a settings window, and
a first-launch permission guide.

Private-API routes were investigated and ruled out on macOS 27: IOBluetooth's `setListeningMode:`
is inert (a plain in-memory store), and AVRouting / CoreBluetooth listening-mode setters require
Apple-only entitlements.

## License

MIT — see [LICENSE](LICENSE).
