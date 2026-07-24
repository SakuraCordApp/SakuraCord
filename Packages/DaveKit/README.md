# DaveKit

DaveKit is SakuraCord's Swift wrapper around the vendored
[Discord Audio and Video End-to-End Encryption (DAVE)](https://github.com/discord/libdave)
and MLS implementations. `MediaPipeline` uses it for voice and video encryption;
the app target does not import DaveKit directly.

Run its package tests with:

```sh
swift test --package-path Packages/DaveKit
```

The upstream libdave and MLS++ sources retain their own READMEs and license
files under `Sources/CLibdave` and `Sources/CMLS`.
