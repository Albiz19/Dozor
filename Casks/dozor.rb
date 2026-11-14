cask "dozor" do
  version "0.4.0"
  sha256 "fde68e8865de757af2248a79be5aab61d9899988e7f6c137559079b9d6d863a7"

  url "https://github.com/Albiz19/Dozor/releases/download/v#{version}/Dozor-#{version}-macOS-arm64.zip"
  name "Dozor"
  desc "Monitor trusted VPN exits and pause selected macOS apps on route changes"
  homepage "https://github.com/Albiz19/Dozor"

  depends_on arch: :arm64
  depends_on macos: :ventura

  app "Dozor.app"
end
