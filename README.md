# EML Viewer

Disclaimer: heavly based on ai generated code!

A free, native macOS app to open and preview email files.

- Opens **`.eml`** (RFC 822) and **`.msg`** (Microsoft Outlook / OLE2 compound file)
- Drag-and-drop welcome window; double-click in Finder also works
- Headers (From / To / Cc / Subject / Date), full-headers toggle, raw-source toggle
- Rich HTML rendering via `WKWebView` with a plain-text fallback
- Attachment list with **Save As…** and **Quick Look**
- No telemetry, no accounts, no network calls except what HTML in the message itself triggers
- Distributed **as-is, free of charge**, under the MIT license

---

## Install (Homebrew)

Once a release is published on GitHub:

```sh
brew install --cask longstone/tap/eml-viewer
```

To publish the cask you have two options:


 **Personal tap** https://github.com/longstone/homebrew-tap

## Build from source

Requires macOS with Xcode 26+ installed (Command Line Tools alone are not
enough — the build needs the full Xcode).

```sh
# open in Xcode and press ⌘R
open eml-viewer.xcodeproj

# or from the command line
xcodebuild -project eml-viewer.xcodeproj -scheme eml-viewer \
  -configuration Release -destination 'generic/platform=macOS' build
```

## Cut a release + Homebrew cask

### Locally

```sh
./scripts/build-release.sh 0.1.0
```

This produces:

- `dist/eml-viewer.app` — the signed (ad-hoc) app bundle
- `dist/eml-viewer-0.1.0.zip` — upload this to a GitHub Release
- `dist/eml-viewer-0.1.0.zip.sha256` — paste the hash into
  `Casks/eml-viewer.rb` (l[ongstone/homebrew-tap](https://github.com/longstone/homebrew-tap/blob/main/eml-viewer.rb))

Then update `Casks/eml-viewer.rb`:

```ruby
version "0.1.0"
sha256  "<hash from the .sha256 file>"
```

…and push it to your `homebrew-tap` repo.

### Via GitHub Actions

The workflow in `.github/workflows/release.yml` runs on GitHub-hosted macOS
runners and automates the full release flow:

1. Push your code to `github.com/longstone/eml-viewer-macos`.
2. Tag a release and push the tag:
   ```sh
   git tag -a v0.1.0 -m "v0.1.0"
   git push origin v0.1.0
   ```
3. The workflow runs `test` → `build` → `release`. The `release` job creates
   a GitHub Release with the `.zip` and `.zip.sha256` attached as assets and
   the SHA-256 embedded in the release notes.
4. Copy the SHA-256 from the release notes (or the `.sha256` asset) into
   `Casks/eml-viewer.rb`, then push the updated cask to your
   `homebrew-tap` repo.

You can also trigger the workflow manually via **Run workflow** on the
Actions tab to produce build artifacts without cutting a release.

**Regenerating the app icon**

```sh
swift scripts/generate-icon.swift
```

Re-runs the icon generator and overwrites
`eml-viewer/Assets.xcassets/AppIcon.appiconset/*` plus a 1024×1024 master at
`scripts/icon-master-1024.png`.

> **Note on signing/notarization.** The build script ad-hoc signs the app so it
> launches locally. For a cask that doesn't trigger Gatekeeper warnings on
> other users' machines you'll want a paid Apple Developer ID and
> `xcrun notarytool`. This repo intentionally does **not** bake that in — the
> app is free and distributed as-is.

## Running the tests

```sh
xcodebuild test -project eml-viewer.xcodeproj -scheme eml-viewer \
  -destination 'platform=macOS'
```

## Project layout

```
eml-viewer/
  eml-viewer/                SwiftUI app sources
    eml_viewerApp.swift      @main + DocumentGroup
    ContentView.swift        thin wrapper around EmailView
    EmailView.swift          header card, body, attachments, WKWebView
    EMLDocument.swift        FileDocument for .eml
    EMLParser.swift          self-contained MIME parser (dispatches to MSG on CFB magic)
    MSGParser.swift          MAPI property decoder for Outlook .msg
    CFBReader.swift          OLE2 / Compound File Binary container reader
    WelcomeView.swift        startup drag-and-drop window
    Info.plist               CFBundleDocumentTypes for .eml + .msg association
  eml-viewerTests/           Swift Testing unit tests for the parser
  Casks/eml-viewer.rb        Homebrew cask
  scripts/build-release.sh   one-shot release build + zip + sha256
```

## License

MIT — see `LICENSE`. The app is provided free of charge with **no warranty**.
