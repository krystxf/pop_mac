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

`make prod` installs the latest release as **Pop Mac Prod** in `~/Applications`, next to your development build.
Only one copy can manage windows, so starting a build quits the other one. Pop Mac Prod needs its own Accessibility access.
It is signed again with the Developer ID certificate in your keychain, if there is one, so the access stays across updates.
It installs only a release that Apple notarized and that the Pop Mac team signed, so it never signs someone else's app.

CI runs on every push and pull request:

| Job | Checks |
| --- | --- |
| Lint | SwiftFormat, ShellCheck, and actionlint. zizmor for security problems in the workflows. The tests of the release scripts. The relative links in the Markdown files. |
| Build and test | A build with warnings as errors, the tests, and the app bundle, which is attached to the run as the `PopMac` artifact. A smoke test of the app. The minimum macOS in `Package.swift`, `Info.plist`, the app, and the cask. `brew style` and `brew audit` on the cask. |
| Smoke test | The app from the build job on macOS 15 and macOS 14, which catches APIs and private symbols that older systems lack. |
| Tests with sanitizers | The tests with the address sanitizer and the thread sanitizer. |
| Swift 6 concurrency report | The warnings that the Swift 6 language mode would turn into errors, in the job summary. It never fails. |
| Release notes | For a pull request into `main` that makes a release: notes in the "Release notes" section, and at most one release label. |

CodeQL checks the Swift code and the workflows every week. The checks run locally too:
`./scripts/test-release-scripts.sh`, `python3 scripts/check-links.py`, and, after `make app`, `./scripts/check-min-macos.sh`.

The code has two parts:

- `Sources/PopCore` is the tiling engine without any AppKit code. It ports Pop Shell's `fork.ts`, `forest.ts`, `auto_tiler.ts`, `focus.ts`, and parts of `tiling.ts`. The tests in `Tests/PopCoreTests` cover it.
- `Sources/PopMac` is the macOS app. It reads and moves windows through the Accessibility API, catches key bindings with a keyboard event tap, and draws the overlay, active hint, stack tabs, and launcher with AppKit.

## Releases

Changes reach `main` through pull requests. When CI passes on `main` after a merge, the Release
workflow releases every pull request merged since the last release tag. It builds the commit that
CI tested, so nothing ships that fails a check, and a failing CI run on `main` stops the release
until a fix merges.

- The labels `release:major`, `release:minor`, and `release:patch` pick the part of the version to bump.
  When several pull requests go into one release, the highest bump wins.
  Without a label, a change to code makes a patch release, and a change to docs or workflows only makes none.
  The label `no-release` skips the release.
- The "Release notes" sections of the pull requests become the notes of the release.
- The Release workflow builds the app, signs it with the Developer ID, notarizes and staples it, and
  publishes the GitHub release with `PopMac.zip`. Publishing the release creates its tag.
  Then it updates the cask in [krystxf/homebrew-tap](https://github.com/krystxf/homebrew-tap)
  from `packaging/homebrew/pop-mac.rb`.
- A release that fails can be re-run from its failed job. A run that GitHub cancels, or one that
  fails before it publishes, loses nothing: the next run releases its pull requests too.

Builds take their version from the latest release tag. The version in `Resources/Info.plist` is only a fallback.

The workflow reads these secrets from the `release` environment, which only `main` can use.
The app builds in a job without secrets. The job with the secrets checks out no code from the
repository and only signs, notarizes, and publishes the built app.

| Secret | Content |
| --- | --- |
| `DEVELOPER_ID_P12` | The Developer ID Application certificate with its private key, as a base64-encoded `.p12` file |
| `DEVELOPER_ID_P12_PASSWORD` | The password of the `.p12` file |
| `NOTARY_KEY` | The App Store Connect API key (`.p8` file) that notarizes the app |
| `NOTARY_KEY_ID` | The ID of that key |
| `NOTARY_ISSUER_ID` | The issuer ID of that key |
| `TAP_DEPLOY_KEY` | The private SSH key of a deploy key with write access to `krystxf/homebrew-tap` |

## License

Pop Mac is a derivative of Pop Shell by System76, and is licensed under the GNU GPL v3. See [LICENSE](LICENSE).
