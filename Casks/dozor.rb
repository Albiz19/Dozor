cask "dozor" do
  version "0.4.1"
  sha256 "defb54c2c613e5b7b86cb56f5499aaec5311d49bb5e38b86d77e239ef0f8eba2"

  url "https://github.com/Albiz19/Dozor/releases/download/v#{version}/Dozor-#{version}-macOS-arm64.zip"
  name "Dozor"
  desc "Monitor trusted VPN exits and pause selected macOS apps on route changes"
  homepage "https://github.com/Albiz19/Dozor"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Dozor.app"
end
