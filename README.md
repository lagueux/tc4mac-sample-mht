# tc4mac MHT plugin (packer sample)

A [tc4mac](https://tc4mac.com) packer plugin for **MHTML** (`.mht`, `.mhtml`)
— a saved web page: the HTML plus every image and stylesheet it needs, in one
MIME document. That makes it an archive in every sense a file manager cares
about, and it needs no third-party code, which is why it is the packer sample.

It reads **and** writes, because a sample that only unpacks teaches the half
of the interface authors get right anyway.

## Build

```
swift build
swift test
```

The only dependency is
[tc4mac-plugin-sdk](https://github.com/lagueux/tc4mac-plugin-sdk).

## What to look at

- `MhtPackerPlugin.swift` — the `PackerPlugin` conformance: capabilities,
  listing, extracting, packing, and content-based detection.
- `MhtArchive.swift` — the format itself: MIME parsing and building, kept
  pure so it is testable without any host.

Two details in the parser are load-bearing and covered by tests:

- The line break **before** a MIME boundary belongs to the boundary, not to
  the file. Keep it and every extracted file gains a stray newline.
- A part's `Content-Location` is stripped to a relative name, so a document
  claiming `../../etc/passwd` cannot write outside where it is extracted.

## Capabilities, and why they are what they are

```swift
[.create, .multipleFiles, .searchable, .detectByContent]
```

No `.modify`: adding a file to an MHT means rewriting the whole document.
tc4mac gates its dialogs on what a plugin declares, so leaving it out means
the user is never offered an "add" that quietly rebuilds their file. Declare
what the format can do, not what would be convenient.

## Installing it

```
./make-plugin.sh
```

That builds `MHT.tcplugin`. In tc4mac open **Configuration ▸ Plugins ▸
Install…**, choose the bundle, then switch it on. `.mht` files then open in
a panel like any other archive, and the Pack dialog can create them.

## Licence

MIT. See `LICENSE`.
