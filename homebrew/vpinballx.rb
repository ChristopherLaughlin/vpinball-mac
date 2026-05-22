cask "vpinballx" do
  version "10.8.1"
  sha256 :no_check

  url "https://github.com/ChristopherLaughlin/vpinball-mac/releases/download/v#{version}/VPinballX-#{version}-macOS.dmg"
  name "VPinballX"
  desc "Open-source pinball table simulator for macOS"
  homepage "https://github.com/ChristopherLaughlin/vpinball-mac"

  depends_on macos: ">= :sonoma"

  app "VPinballX_BGFX.app"

  zap trash: [
    "~/Library/Application Support/VPinballX",
    "~/Library/Preferences/org.vpinball.VPinballX_BGFX.plist",
  ]

  caveats <<~EOS
    Tables (.vpx files) can be downloaded from https://www.vpforums.org

    Controls:
      Left/Right Shift — Flippers
      Enter — Launch ball
      F12 — Settings
      Escape — Exit table
  EOS
end
