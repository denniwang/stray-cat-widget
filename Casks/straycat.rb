cask "straycat" do
  version "1.0.0"
  sha256 "1124cc6df12e3cd748b5e67c0c2bc6e137750c632e3778fbf48e88aad8fb68af"

  url "https://github.com/denniwang/stray-cat-widget/releases/download/v#{version}/StrayCat.zip"
  name "Stray Cat"
  desc "Stray cat that pops into a screen corner and reminds you to take screen breaks"
  homepage "https://github.com/denniwang/stray-cat-widget"

  depends_on macos: ">= :ventura"

  app "StrayCat.app"

  # The app isn't notarized; clear the quarantine flag so macOS doesn't call it damaged.
  postflight do
    system_command "/usr/bin/xattr",
                   args: ["-dr", "com.apple.quarantine", "#{appdir}/StrayCat.app"],
                   sudo: false
  end

  zap trash: [
    "~/Library/Application Support/StrayCat",
    "~/Library/Preferences/local.dennis.straycat.plist",
  ]
end
