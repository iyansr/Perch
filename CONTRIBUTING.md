# Contributing to Perch

Thanks for helping improve Perch. Search existing issues and pull requests before opening a new one. For substantial changes, open an issue first so the approach can be discussed before you invest time in a pull request.

## Development setup

Perch requires macOS 26 or later and Xcode 26 or later. Clone the repository, open `Perch.xcodeproj`, and run the `Perch` scheme. Debug builds use your Apple Development team; see [signing](docs/signing.md) for details. The build runs `Scripts/build-mediaremote-adapter.sh` automatically.

For the marketing site, use `pnpm install` and `pnpm dev` in `web/`. See the [README](README.md#building-from-source) for setup details.

## Pull requests

- Keep changes focused and describe the problem, solution, and any tradeoffs. Link the related issue when there is one.
- Run relevant tests using the `Perch` scheme in Xcode, and exercise the changed behavior in the app. Describe what you tested and any limitations.
- For visual changes, include before-and-after screenshots or a recording. Check both notch and floating-island modes when relevant.
- Update documentation when behavior or setup changes. Follow existing code and UI conventions.
- Complete the [pull request template](.github/PULL_REQUEST_TEMPLATE.md) and review your diff before submitting.

## Reporting bugs and suggesting features

Use the [issue forms](https://github.com/iyansr/Perch/issues/new/choose). For bugs, include reproduction steps, expected and actual behavior, Perch and macOS versions, and screenshots or a recording when useful. Do not include private data in reports.

## Community and license

Follow the [Code of Conduct](CODE_OF_CONDUCT.md). Contributions are licensed under the project's [AGPL-3.0 license](LICENSE).
