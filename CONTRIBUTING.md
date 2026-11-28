# Contributing

Thanks for helping with Window.

## Build

Follow "Build from source" in the README. Put your team ID and bundle prefix in `Config/Local.xcconfig`, which git ignores. Don't commit signing settings, team IDs or personal places.

## Test

The departure policy, ruler, widget model and watch controller have portable tests that run in Docker on any machine:

```sh
sh scripts/test-linux.sh
```

On a Mac with Xcode 26, also run the native suite:

```sh
xcodegen generate
xcodebuild -scheme Window -destination 'platform=macOS' test
```

To check your change visually, `scripts/capture-states.sh`, `scripts/capture-widgets.sh` and `scripts/capture-screens.sh` render the panel, widget and editor windows from test data into a folder you name. They never query Apple Maps or touch your saved journey.

## Pull requests

- Keep each pull request to one change, and say what it changes for someone using the app.
- Add or update a test for any change to the departure policy or watch logic.
- Include before and after captures for visual changes.
- Use made-up places in fixtures, never real addresses or coordinates.
- Make sure `sh scripts/test-linux.sh` passes.
