cask "dozor" do
  version "0.4.2"
  sha256 "b7977068242cece4f22022e715e0e8fac851c161bc06418f01364b4712d0c649"

  url "https://github.com/Albiz19/Dozor/releases/download/v#{version}/Dozor-#{version}-macOS-arm64.zip"
  name "Dozor"
  desc "Monitor trusted VPN exits and pause selected macOS apps on route changes"
  homepage "https://github.com/Albiz19/Dozor"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Dozor.app"
end
