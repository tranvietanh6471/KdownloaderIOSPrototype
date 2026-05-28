# Kdownloader

Kdownloader is an iOS media downloader prototype based on the Palladium core. It runs `yt-dlp`, `ffmpeg`, and Python tooling on-device, then adds a browser-first workflow and an in-app file/player surface.

## What This Build Adds

- Browser tab with video URL detection and a download button.
- Download tab powered by Palladium's existing yt-dlp/ffmpeg pipeline.
- Files tab for `Documents`, `Saved`, and `Temp`.
- Create, rename, move, and delete files or folders inside the app sandbox.
- Integrated AVPlayer/QuickLook previews for downloaded media and documents.
- Share extension and URL scheme updated to `kdownloader://download?url=...`.

## Build

GitHub Actions builds an unsigned IPA artifact from `build_ipa.sh`. Local builds require Xcode on macOS plus the frameworks described in `BUILD.md`.

## Credits

This app is derived from Palladium by TfourJ and keeps the same GPLv3 license requirements.

- Palladium: https://github.com/tfourj/Palladium
- yt-dlp: https://github.com/yt-dlp/yt-dlp
- ffmpeg: https://ffmpeg.org/
- PythonKit: https://github.com/pvieito/PythonKit
- python-apple-support: https://github.com/beeware/Python-Apple-support
- SwiftFFmpeg-iOS: https://github.com/tfourj/SwiftFFmpeg-iOS

## License

GPLv3. See [LICENSE](LICENSE).
