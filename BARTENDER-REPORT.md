# AirToggle menu bar item disappears while Bartender 7 is running

**Environment:** macOS 27.0 (26A428), Bartender 7.0.4, MenuBarAgent-hosted menu bar.
**App:** AirToggle (bundle id `dev.ben.AirToggle`), an LSUIElement menu bar app with a single
`NSStatusItem` (autosave name `AirToggleItem`, square length, template SF Symbol image).
The app is signed with a local self-signed certificate (no Developer ID / Team ID).

## Symptom
- With Bartender quit, the item is in the menu bar (MenuBarAgent's accessibility tree lists an
  `AXButton` titled "AirToggle").
- With Bartender running, the item is absent from the menu bar and from Bartender's hidden bar,
  while Bartender's settings show it under **Shown Items**. Dragging it to another section in
  Bartender snaps back. The macOS "Allow in the Menu Bar" switch for AirToggle is on.

## What Bartender's data shows
- Catalog identity: `plist:status:AirToggle::AirToggleItem`. Every other app is keyed by bundle id
  (`plist:status:com.google.Chrome::Item-0`), this one by the bare app name. macOS's layout store
  used the same name-based key (`status:AirToggle::…`), so the identity comes from the system.
- Earlier, `GoldenGateMoveFailureLedgerV1` held failed-move records for the item and
  `menuBarAgentPositions` placed it at 5764 on a 5120-pixel-wide display.
- After clearing those records and the three stale `status:AirToggle::*` keys from
  `com.apple.MenuBar.plist`, Bartender re-catalogued the item, recorded no position and no move
  failure, wrote nothing for it into the layout store, and the item still disappears whenever
  Bartender runs.

## Guess
Bartender appears to treat the app as hidden whenever the system identifies the app by name
rather than bundle id (apps without an Apple-trusted signature), while its layout UI treats it as
shown. Reproducible with any locally signed or ad-hoc signed menu bar app.
