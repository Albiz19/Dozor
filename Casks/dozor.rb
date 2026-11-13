cask "dozor" do
  version "0.2"
  sha256 "583fd71e16956708111cdb2fd9ab7772b92028262fee11e32b4ab71f41d28bf9"

  url "https://github.com/Albiz19/Dozor/releases/download/v#{version}/Dozor-#{version}-macOS-arm64.zip"
  name "Dozor"
  desc "Monitor trusted VPN exits and pause selected macOS apps on route changes"
  homepage "https://github.com/Albiz19/Dozor"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Dozor.app"
end
