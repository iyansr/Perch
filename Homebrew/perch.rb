cask "perch" do
  # Scripts/render-cask.sh fills in `version` and `sha256`; the release workflow pushes the result to
  # the iyansr/homebrew-perch tap. Edit this file, not the tap's copy. See docs/release.md.
  version "0.0.0"
  sha256 "0000000000000000000000000000000000000000000000000000000000000000"

  url "https://github.com/iyansr/Perch/releases/download/v#{version}/Perch-#{version}.dmg"
  name "Perch"
  desc "Notch command center with search, clipboard history and live activities"
  homepage "https://github.com/iyansr/Perch"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Perch updates itself after the user approves; this makes a plain `brew upgrade` normally skip it.
  # Naming the cask or passing --greedy still upgrades it. See docs/release.md.
  auto_updates true

  depends_on macos: :tahoe

  app "Perch.app"

  # Perch is self-signed, not notarized, so macOS quarantines the download. Clearing the flag on every
  # install and upgrade lets Gatekeeper open it without the user running xattr by hand.
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Perch.app"]
  end

  # Replacing the bundle under a running Perch would leave the old process holding the notch.
  uninstall quit: "id.iyansr.perch"

  zap trash: [
    "~/Library/Application Support/Perch",
    "~/Library/Caches/id.iyansr.perch",
    "~/Library/HTTPStorages/id.iyansr.perch",
    "~/Library/Preferences/id.iyansr.perch.plist",
    "~/Library/Saved Application State/id.iyansr.perch.savedState",
  ]
end
