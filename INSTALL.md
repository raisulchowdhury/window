# Install Window

Window is free. You download it from the Window website and install it yourself. It takes about two minutes.

You need a Mac with macOS 26 or later.

## 1. Download

Download the Window zip file from the [Window website](https://raisul.xyz/window) or the [latest release on GitHub](https://github.com/raisulchowdhury/window/releases/latest). It's named like `Window-1.0.0.zip`.

If you want to check the file (step 6), keep the zip. Safari unzips downloads by itself and then removes the zip. To keep it, turn off Safari > Settings > General > Open "safe" files after downloading before you download.

## 2. Unzip

Double-click the zip in your Downloads folder. You get `Window.app`. If Safari already unzipped it, `Window.app` is in Downloads.

## 3. Move it to Applications

Drag `Window.app` to the Applications folder in the Finder sidebar. Do this before you open it.

## 4. Open it the first time

Double-click Window in Applications. macOS shows a warning that it can't check Window for malicious software. The exact words depend on your macOS version. Click **Done**. Don't click Move to Trash.

Right-clicking the app and choosing Open no longer gets past this warning on recent macOS. Use System Settings, as in the next step.

## 5. Allow it in System Settings

These are Apple's steps from its support page [Open an app by overriding security settings](https://support.apple.com/guide/mac-help/mh40617/26/mac/26) (macOS Tahoe 26):

1. "On your Mac, choose Apple menu > System Settings, then click Privacy & Security in the sidebar. (You may need to scroll down.)"
2. "Go to Security, then click Open." You'll see a line about Window there.
3. "Click Open Anyway." Apple notes: "This button is available for about an hour after you try to open the app." If it's gone, open Window again (step 4) and come back.
4. "Enter your login password, then click OK."

Window opens. It lives in the menu bar at the top right of your screen, not in the Dock. From now on it opens like any other app.

## Why the warning appears

macOS checks apps from the internet with Apple. A developer pays for an Apple Developer membership, signs the app, and sends it to Apple to scan. That's called notarization. Window is a free side project, and this version isn't notarized, so macOS can't vouch for it and asks you to decide.

You don't have to take Window on trust. The source code is public at https://github.com/raisulchowdhury/window. Anyone can read what it does or build it themselves. Window has no account, no analytics and no server. Your places and times stay on your Mac.

Only download Window from the Window website or its GitHub releases page, and check the file if you're unsure (next step).

## 6. Check the download (optional)

The GitHub release has a SHA-256 checksum next to the download, in the file [`Window-1.0.0.zip.sha256`](https://github.com/raisulchowdhury/window/releases/latest/download/Window-1.0.0.zip.sha256). It's a fingerprint of the file. If yours matches, you have the exact file that was published.

Open Terminal (in Applications > Utilities) and run:

```sh
cd ~/Downloads
shasum -a 256 Window-1.0.0.zip
```

Use your file's real name. Compare the long code it prints with the one in `Window-1.0.0.zip.sha256`. They must match exactly.

If you also downloaded `Window-1.0.0.zip.sha256` into the same folder, this checks it for you:

```sh
shasum -a 256 -c Window-1.0.0.zip.sha256
```

It prints `Window-1.0.0.zip: OK` when the file matches. If it doesn't match, delete the zip and don't open the app.

## What the download doesn't include

- **The desktop widget.** The widget and the app need a shared space to pass the plan between them. macOS only gives that to apps signed with an Apple developer team, so the widget is left out of this download. If you build Window from source with your own team, you get the widget. A signed download may add it later.
- **Automatic updates.** To update, download the new version and replace the old one in Applications. macOS may ask you to allow it again (steps 4 and 5).

The first time you start a watch, macOS asks whether Window can send notifications. Allow them to get the wrap-up and leave alerts.

## Uninstall

1. Click Window in the menu bar, click the gear at the bottom left of the panel, and choose **Quit Window**. If Open at Login is ticked in that menu, untick it first.
2. Drag Window from Applications to the Trash.
3. To remove your saved places and settings too, in Finder choose Go > Go to Folder, enter `~/Library/Containers/xyz.raisul.window.taras`, and move that folder to the Trash.
