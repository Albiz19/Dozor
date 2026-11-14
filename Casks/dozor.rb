cask "dozor" do
  version "0.4.0"
  sha256 "8e7677c540933919de8ad219ea013905d3f022bb4e326f27e352d851fd6ed868"

  url "https://github.com/Albiz19/Dozor/releases/download/v#{version}/Dozor-#{version}-macOS-arm64.zip"
  name "Dozor"
  desc "Monitor trusted VPN exits and pause selected macOS apps on route changes"
  homepage "https://github.com/Albiz19/Dozor"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Dozor.app"
end
