# Dozor for macOS

[Русский](README.md) · [Releases](https://github.com/Albiz19/Dozor/releases/latest) · [MIT license](LICENSE)

A VPN reconnect can change your public IP in the middle of a work session. Dozor checks the observed exits against your trusted IPs and can suspend selected apps and their children when a route changes. This helps reduce unexpected IP changes seen by online services. Each service makes its own account security decisions.

Dozor 0.2 runs on Apple Silicon with macOS 13 or later. Its UI is in Russian. It includes a menu bar IP monitor, latency history, Telegram notifications for freeze/resume events, a restricted launcher for Claude Code, and source for an optional macOS network filter.

```sh
brew tap albiz19/dozor https://github.com/Albiz19/Dozor.git
brew trust --cask albiz19/dozor/dozor
brew install --cask albiz19/dozor/dozor
```

Alternatively, clone the repository and run `./build.sh` with the Apple Command Line Tools installed. The public bundle is ad hoc signed. Gatekeeper may block downloaded builds. Enabling the optional system extension requires a properly provisioned Developer ID build.

Add your VPN's trusted exit IPs before enabling protection. Configure the local HTTP proxy port and VPN service ID. Auto-resume requires fresh route checks and a connected system VPN service. With a proxy-only VPN, previously frozen processes stay frozen. Process suspension alone cannot guarantee zero packet loss or prevent direct traffic before detection. For the CLI launcher, the local proxy must route protected destinations exclusively through the intended tunnel.

Check for a stable release from Settings → Updates, or run `brew update` followed by `brew upgrade --cask albiz19/dozor/dozor`. The app stores configuration outside its bundle. See the [setup guide](docs/GUIDE.md) for proxy, Telegram and signing details.
