# BlueDuck

Mounts S3 buckets in Finder using Apple's File Provider framework (no kernel extension or macFUSE).
Each bucket appears under **Locations** in the Finder sidebar (`~/Library/CloudStorage/BlueDuck-<name>`).

- Files download on demand when opened; Finder shows cloud/download status.
- Right-click → **Keep Offline** downloads a file or folder (recursively) and keeps it downloaded.
  **Remove Offline Copy** reverts it to on-demand and frees the disk space.
- Finder's built-in **Download Now** / **Remove Download** also work.
- Works with AWS S3 and S3-compatible services (MinIO, Cloudflare R2, Wasabi, SeaweedFS…).

## Layout

| Path | What |
| --- | --- |
| `App/` | Host app: add/edit buckets, store secrets in the Keychain, register File Provider domains, poll for remote changes |
| `FileProviderExtension/` | `NSFileProviderReplicatedExtension`: enumeration, download, upload, rename/move, delete, Finder actions |
| `Packages/BlueDuckKit/` | Shared code: S3 client (SigV4, multipart), config/credential storage, `ItemStore` (stable identifiers + change diffing) |
| `project.yml` | XcodeGen spec; the `.xcodeproj` is generated and not checked in |

## Build and run

Requires Xcode and an Apple Developer team (a free personal team works for local use). macOS will not
load an unsigned File Provider extension.

```sh
brew install xcodegen
echo 'DEVELOPMENT_TEAM = YOURTEAMID' > Config/Local.xcconfig
xcodegen generate
open BlueDuck.xcodeproj   # run the BlueDuck scheme
```

Click **+**, enter the bucket details and credentials, and click **Add**. The bucket appears in the Finder sidebar.

If you change bundle identifiers, keep the app group (`$(TeamIdentifierPrefix)club.vaniti.blueduck`)
identical in both targets' entitlements and Info.plist.

## Tests

```sh
cd Packages/BlueDuckKit
swift test                                   # unit tests
BLUEDUCK_TEST_ENDPOINT=http://localhost:8333 BLUEDUCK_TEST_BUCKET=blueduck-test \
BLUEDUCK_TEST_ACCESS_KEY=... BLUEDUCK_TEST_SECRET_KEY=... swift test   # + live S3 tests
```

Use `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` if `xcode-select` points at the Command Line Tools.

## How it works

- **Identifiers.** S3 addresses objects by key, but File Provider needs identifiers that survive renames.
  `ItemStore` assigns each key a UUID and re-keys records (and descendants) on move/rename.
- **Remote changes.** S3 has no change feed. The working-set enumerator re-lists every folder the system has
  seen and diffs it against the store. The app triggers this every 60 seconds while it is running, and the
  menu bar offers **Check for Changes Now**.
- **Offline pins.** Keep Offline sets the item's `contentPolicy` to `downloadEagerlyAndKeepDownloaded`;
  descendants inherit it. For folders the extension first lists the whole subtree so every file is known
  and downloaded. Pins persist in the store.
- **Partial reads.** The extension implements `NSFileProviderPartialContentFetching`. When an app reads part of a
  file that isn't downloaded (POSIX `read`/`mmap`, e.g. a video player seeking), only that part is fetched with a
  ranged GET, rounded up to 8 MB chunks. Requests carry `If-Match: <etag>` so a file never mixes bytes from two
  versions. Apps that open files through file coordination still download the whole file.
- **Directories** are key prefixes; empty folders are zero-byte `folder/` marker objects.
  `.DS_Store` and `._*` files are never uploaded.

## Limitations

- Remote changes are picked up only while the app is running (or when Finder re-enumerates a folder).
- Last writer wins: concurrent edits from another client are not detected as conflicts.
- Folders cannot be renamed or moved. Files over 5 GB cannot be renamed or moved (CopyObject limit).
- Partial reads apply only when macOS asks for them (POSIX reads); most document apps download the whole file.
