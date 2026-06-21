<div align="center">

# Need More Tokens

### *Because you always do.* 🪫

<img src="assets/gauge.svg" alt="Need More Tokens — a menu-bar gauge for Claude, Codex and Gemini" width="440">

[![License: MIT](https://img.shields.io/badge/License-MIT-2da44e.svg)](LICENSE)
&nbsp;![macOS 26 Tahoe](https://img.shields.io/badge/macOS-26_Tahoe-000000?logo=apple&logoColor=white)
&nbsp;![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
&nbsp;![Liquid Glass](https://img.shields.io/badge/UI-Liquid_Glass-9b8cff)
&nbsp;![No Electron](https://img.shields.io/badge/no-Electron-ff453a)

</div>

A tiny menu-bar gauge for your **Claude · Codex · Gemini** runway. Glance up; see how much you've got left before something says *limit reached.* 📊

Real native macOS 26. Liquid Glass, no Electron, no web view, no CLI. It reads your usage with native HTTPS clients — your token anxiety stays on your laptop. 🔒

### What you see 👀

Every 5-hour and weekly limit, down to the fiddly ones — Claude's Sonnet weekly, Gemini's Antigravity quota. Your monthly plan, pay-as-you-go credits, and the exact time each window resets. The menu-bar number is whatever's closest to empty, green → amber → red as the runway shrinks.

Letters too small? Tap **A+**. It's real type, so it scales crisp, and it remembers. The dollar figures are honest estimates — a nudge, not a bill. It won't do your taxes.

### Run it 🚀

```sh
git clone https://github.com/aylee1024/need-more-tokens
cd need-more-tokens && xcodegen generate && open NeedMoreTokens.xcodeproj
```

macOS 26 + Xcode 26. Build, and it tucks into your menu bar.

<details>
<summary>🔄 Gemini auto-refresh (optional)</summary>

Claude and Codex stay fresh on their own. Gemini's token lasts ~1 hour and only `agy` (Antigravity) refreshes it, so otherwise the card shows *"expired — run agy."* To let NMT do it for you, copy [`gemini-oauth.example.json`](gemini-oauth.example.json) to `~/.config/needmoretokens/gemini-oauth.json` and drop in **agy's own OAuth client** (the one the Keychain token is issued under — capture it from agy's refresh call). No secret ever touches this repo; it lives only on your machine. Skip it and nothing breaks — Gemini just shows "expired" when its token lapses.

</details>

<div align="center">
<br>
Lives quietly in your menu bar. 🛟<br>
Companion to **[lord-claude](https://github.com/aylee1024/lord-claude)** · MIT
</div>
