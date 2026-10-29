# Development

## Building from source

You need the Swift toolchain (Xcode or the Command Line Tools).

```sh
make install          # builds build/PopMac.app and copies it to ~/Applications
open ~/Applications/PopMac.app
```

The build signs the app with the first "Apple Development" certificate in your keychain.
A stable signature keeps the Accessibility access across rebuilds.
To pick another certificate, set `SIGN_IDENTITY` to its name or SHA-1 hash:

```sh
SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" make install
```

Without a certificate, the build signs ad-hoc.

## Tools

```sh
make lint     # SwiftFormat in lint mode
make format   # apply SwiftFormat
make test     # unit tests for the tiling engine
make build    # debug build
make run      # build the app bundle and open it
.build/debug/PopMac --diagnose   # print displays, Spaces, and windows, then exit
POP_MAC_DEBUG=1 build/PopMac.app/Contents/MacOS/PopMac   # verbose log on stderr
POP_MAC_SHOW_WELCOME=1 build/PopMac.app/Contents/MacOS/PopMac   # show the first-run window
kill -USR1 "$(pgrep -f PopMac.app/Contents/MacOS/PopMac)"   # write the tiling tree to the log
swift scripts/make-icon.swift   # redraw Resources/AppIcon.icns
POP_MAC_SNAPSHOT_DIR=/tmp/shots build/PopMac.app/Contents/MacOS/PopMac   # save images of the settings pages
```

`make prod` installs the Homebrew release as **Pop Mac Prod** in `~/Applications`, next to your development build.
Only one copy can manage windows, so starting a build quits the other one. Pop Mac Prod needs its own Accessibility access.

CI runs on every push and pull request. It checks the formatting with SwiftFormat, lints the
shell script and the workflow, builds with warnings as errors, runs the tests, and builds the app
bundle. The bundle is attached to each run as the `PopMac` artifact.

The code has two parts:

- `Sources/PopCore` is the tiling engine without any AppKit code. It ports Pop Shell's `fork.ts`, `forest.ts`, `auto_tiler.ts`, `focus.ts`, and parts of `tiling.ts`. The tests in `Tests/PopCoreTests` cover it.
- `Sources/PopMac` is the macOS app. It reads and moves windows through the Accessibility API, catches key bindings with a keyboard event tap, and draws the overlay, active hint, stack tabs, and launcher with AppKit.

## License

Pop Mac is a derivative of Pop Shell by System76, and is licensed under the GNU GPL v3. See [LICENSE](LICENSE).
