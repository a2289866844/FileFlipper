# Local fork 1.5.1

Based on upstream `v1.5.0` (`3ecf3fe0aa5e5c0d383db899bf77986952d4fe19`).
This is an independent local build, not an upstream release or an Apple-notarized app.
It uses the bundle identifier `com.a2289866844.fileflipper` so existing upstream folder grants are not reused.

## Changes

- Validate ZIP end records, full central/local headers, names, payload boundaries,
  duplicate entries and overlapping local records before reading entry data.
- Bound archive reads to 256 MiB, individual entries to 64 MiB, declared total
  uncompressed size to 256 MiB and entry count to 10,000. ZIP64, encryption and
  multi-disk archives are unsupported. Oversized or malformed packages are rejected.
- Use the macOS system zlib decoder. Require complete deflate streams, exact
  decompressed lengths and CRC32 matches before accepting entry contents.
- Reject XML DTDs/entities, external resources and unsupported encodings. Limit
  XML parts to 16 MiB, nesting to 128 and elements plus attributes to 250,000.
  Ordinary UTF-8 and UTF-16 Office XML remains supported.
- Bound Excel coordinates to the format's limits and rendered tables to 500,000
  cells per workbook. Keep non-finite numbers as text and bound number formatting.
- Clamp Word and PowerPoint indentation to the nine supported list levels.
- Keep App Sandbox and hardened runtime; explicitly disable `get-task-allow`
  and Xcode's injected base entitlements. No network entitlement is added.
- Require Xcode for app builds; remove the fallback that built an unsandboxed app.
  The install script refuses to overwrite an existing application.

## Build and test

Requires Xcode and macOS 14 or later. No third-party runtime package is required.

```sh
swift test
FILEFLIPPER_BUILD_DIR=/tmp/fileflipper-build ./scripts/build-app.sh
```

The application is produced at:

```text
/tmp/fileflipper-build/DerivedData/Build/Products/Release/FileFlipper.app
```

The script verifies code-signature integrity and sandbox/debugger entitlements.
Local signing is ad-hoc; it does not establish an Apple Developer ID or notarization.
Do not change Gatekeeper settings or strip quarantine attributes to distribute this build.

The 25 tests cover malformed and truncated ZIPs, decompression limits, corrupt
checksums, XML limits, unusual Office indices, DOCX/XLSX/PPTX-to-Markdown examples,
and PNG-to-JPEG conversion. They verify that input files and existing outputs remain
unchanged. Fixtures are small synthetic packages; no personal files are used.

## Scope

These changes address the identified input-handling and build-permission issues.
They are not a complete security audit or a guarantee against all malicious files.
System image, media and document importers still process input, and the app should
only receive access to folders needed for conversion. Very large Office documents
may exceed the intentional limits above.

To use the app, open FileFlipper, find its ◎ menu-bar icon, then drag a test file in
Finder while holding Shift. Grant access only to the test folder when prompted.
