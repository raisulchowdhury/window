# Changelog

## 1.0.1 (2026-11-28)

Fixes for alerts that didn't arrive and a menu bar title that could disappear.

### Fixed

- Alerts could fail to arrive. macOS refuses alerts to a copy of Window that runs from a temporary folder, which is likely what happens if you open it in Downloads without moving it first. Watch details now says to move Window to Applications and open it again, instead of only "unavailable" or "not set up".
- The menu bar title could disappear from a crowded menu bar. While you wait to leave, it now shows just the leave time, like "17:30", whether alerts are on or off. The drive time is in the panel, and VoiceOver still reads it.
- Waking your Mac inside the leave minute still sends "Time to leave".
- If a check fails when a cue is about to be due, Window retries within 30 seconds instead of waiting for the next check. If Apple Maps is limiting requests, it backs off.
- The "couldn't confirm traffic" warning goes away once traffic is confirmed again, and you get one "Check your departure" per run of failed checks, not one for every sleep or reconnect.
- Wrap-up and leave alerts are removed when the departure they name changes or is withdrawn, when you quit, and when a new watch starts.
- On a full three-hour window, accepting a late recovery no longer blanks the panel or the widget snapshot.
- The journey editor now says when today's departure window has passed, and Save for today still works.
- Watch details: when alerts are denied or not set up, the buttons fit at large text sizes, and "Send test alert" says why it is unavailable.

### Changed

- Labels say what they mean: LEAVE 17:10-17:40 for the leave window, ARRIVE BY for the arrival limit.
- The panel keeps a small margin from the screen edge, and VoiceOver reads the menu bar item as "Window, leave at 17:30, 31 minute drive" and announces "You're on your way" when you leave.

### If you used 1.0.0

Window 1.0.1 has a new app ID, so macOS treats it as a different app from 1.0.0.

- Settings saved by 1.0.0 are not carried over. Set your journey and alerts again.
- macOS asks for notification permission again. Allow it to get alerts.
- The old app stays on your Mac as a separate app, and may still open at login. Quit Window 1.0.0 and delete it. If it was set to open at login, also remove it in System Settings > General > Login Items.

## 1.0.0 (2026-11-25)

First public release.

- Menu bar panel that compares Apple Maps drive times across your leaving window and suggests when to leave.
- Suggestions wait only when waiting saves at least 8 minutes of driving, and pick the earliest time within 2 minutes of the shortest drive.
- Watch mode rechecks traffic every three minutes while the Mac is awake and online, with a wrap-up notification and a leave notification.
- Journey editor for route, earliest and latest leave, arrive by and wrap-up time, for today only or as your usual journey.
- Small and medium desktop widgets showing the last checked plan, when you build from source. The website download leaves the widget out.
- Places and times stay on the Mac. No account, analytics or server.
