cask "straycat" do
  version "1.0.2"
  sha256 "a07dae04d17bf1de53644b1df6abae1ddcf9c01ed9f93e42f81c571e8da73987"

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
