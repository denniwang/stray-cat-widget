cask "straycat" do
  version "1.0.1"
  sha256 "3b3320d633b5621d36591750abfd4b801611a071bad97b3f327f5bcc4dd3219d"

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
