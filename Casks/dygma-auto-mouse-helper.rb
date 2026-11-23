cask "dygma-auto-mouse-helper" do
  version "0.1.1"
  sha256 "937bd1bc7bacf139208ca1df5e224a9e21c024fc5e49a36180fc172d86951175"

  url "https://github.com/harnoldcodes/dygma-auto-mouse-helper/releases/download/v#{version}/Dygma-Auto-Mouse-Helper-#{version}.zip"
  name "Dygma Auto-Mouse Helper"
  desc "Auto-Mouse Layer, Drag Scroll and Toggle Scroll for the Dygma Defy"
  homepage "https://github.com/harnoldcodes/dygma-auto-mouse-helper"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :ventura

  app "Dygma Auto-Mouse Helper.app"

  # The app is signed with the project's own certificate, not an Apple Developer ID, so
  # macOS would refuse to open a downloaded copy. (Install steps run in a sandbox that
  # can't open apps, so the caveat below asks you to.)
  postflight_steps do
    run "/usr/bin/xattr",
        args:         ["-dr", "com.apple.quarantine", "{{appdir}}/Dygma Auto-Mouse Helper.app"],
        must_succeed: false
  end

  uninstall launchctl: "io.github.harnoldcodes.dygma-auto-mouse-helper.login",
            quit:      "io.github.harnoldcodes.dygma-auto-mouse-helper"

  zap trash: [
    "~/.config/dygma-auto-mouse-helper",
    "~/.local/state/dygma-auto-mouse-helper/backup",
    "~/Library/Logs/dygma-auto-mouse-helper.log",
    "~/Library/Logs/dygma-auto-mouse-helper.old.log",
  ]

  caveats <<~EOS
    Open Dygma Auto-Mouse Helper from Applications to start it the first time. It lives in the
    menu bar and starts at login from then on; `brew upgrade` reopens it after updating.
  EOS
end
