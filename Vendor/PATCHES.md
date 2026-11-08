# SeeSound vendored-source notes

The archive URLs, fixed tags and original SHA-256 hashes are recorded in `SOURCE_MANIFEST.json`.
These are source archives, not Git checkouts; no original Git history is claimed.
Runtime source and licenses are preserved. Example applications and large non-runtime assets are not required by this integration.

## Package manifests

- Lottie: removed the unused `airbnb/swift` formatting-package dependency. The original manifest is saved as `Package.upstream.swift.txt`.
- PopupView: changed SwiftUI Introspect to the sibling local source package at version 1.3.0. The original manifest is saved alongside it.
- WhisperKit and swift-transformers: retained runtime library products and changed their dependencies to sibling local packages. Unused command-line and upstream test products are omitted from the active manifests; original manifests are preserved.
- The SeeSound Xcode project links seven local package products. Its Watch target does not link the phone-only model and interface packages.

## WhisperKit tokenizer control

`WhisperKit/Core/WhisperKit.swift` exposes `allowTokenizerDownload`, defaulting to the upstream behavior (`true`).
`Core/Utils.swift` accepts the matching `allowDownload` argument. When it is false, missing or invalid local tokenizer files throw instead of falling back to a network request.
SeeSound enables downloads only during the user's explicit online preparation action, then disables tokenizer download for inference.
No model weights are bundled in this source checkout.

## Vocable data

The Chinese and English phrase strings and category names are derived from Vocable AAC commit `58ba45a978e1ebaeae71d9e88509703a9bd67bd6`.
The original preset mapping, localization strings and MIT license are retained under `References/Vocable/`.
Only the derived 62-phrase catalog is loaded by the application; Vocable's complete application is not integrated.

## Notices

Full runtime licenses and Lottie's embedded-library notices are included in `Resources/ThirdParty-Notices.txt` and displayed inside the app.
`Resources/ListeningPulse.json` is a project-authored vector animation; it is not copied from a commercial asset pack.

## SwiftUI-Flow 3.1.1

Unmodified upstream source and package manifest. The phone app uses the Flow product for HFlow wrapping of event-response phrases and scene controls. Original MIT license is preserved in Vendor and bundled notices. No runtime dependency was added to the Watch target.
