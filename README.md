<div align="center">

# Need More Tokens

### *Because you always do.*

[![License: MIT](https://img.shields.io/badge/License-MIT-2da44e.svg)](LICENSE)
&nbsp;![macOS 26 Tahoe](https://img.shields.io/badge/macOS-26_Tahoe-000000?logo=apple&logoColor=white)
&nbsp;![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)
&nbsp;![Liquid Glass](https://img.shields.io/badge/UI-Liquid_Glass-9b8cff)
&nbsp;![Native HTTPS clients](https://img.shields.io/badge/clients-native_HTTPS-2da44e)

**A tiny menu-bar gauge for your Claude · Codex · Gemini runway.**

</div>

---

You wired up [lord-claude](https://github.com/aylee1024/lord-claude), so Claude is busy handing work off to Codex and Gemini while three usage meters you can't see tick quietly toward empty. **This is the gauge for that.** It lives in your menu bar and tells you, at a glance, how much runway is left before something says *"limit reached."*

Native macOS 26. Real **Liquid Glass** — no Electron, no web view, no external CLI dependency. It uses native direct-HTTPS clients for Claude, Codex, and Gemini; your token anxiety stays between you and your laptop.

### What you see

Each tool's **5-hour** and **weekly** limits — down to the fiddly bits, like Claude's Sonnet weekly and Gemini's **Antigravity** weekly/5-hour quota — plus your **monthly plan** and any **pay-as-you-go credits**, and the exact wall-clock time each window resets. The number in your menu bar is whatever's closest to running out, colored green → amber → red as the runway shrinks.

Letters too small? Tap **A+**. The whole UI scales — *crisply*, because it's real type, not a blurry zoom — and remembers your size. (macOS has no Dynamic Type, so this one's hand-built.)

The dollar figures are honest *estimates* — tokens × list price, labeled as such, not a bill. It won't do your taxes. It'll just nudge you before you hit a wall.

### Install

```sh
git clone https://github.com/aylee1024/need-more-tokens
cd need-more-tokens && xcodegen generate && open NeedMoreTokens.xcodeproj
```

Needs macOS 26 (Tahoe) and Xcode 26. Build & run — it tucks itself into your menu bar.

---

<div align="center">

Lives quietly in your menu bar.<br>
Companion to **[lord-claude](https://github.com/aylee1024/lord-claude)** · MIT

</div>
