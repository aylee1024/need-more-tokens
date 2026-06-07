# Need More Tokens

*Because you always do.*

You wired up [lord-claude](https://github.com/aylee1024/lord-claude), so now Claude is busy handing work off to Codex and Gemini while three usage meters you can't see quietly tick toward empty. **This is the gauge for that.** It sits in your menu bar and tells you, at a glance, how much runway is left across **Claude, Codex, and Gemini** before something says *"limit reached."*

Native macOS 26. Real Liquid Glass — no Electron, no web view. It reads your usage locally and sends nothing anywhere; your token anxiety stays between you and your laptop.

### What you see
Each tool's **5-hour** and **weekly** limits (down to the fiddly bits — Claude's Sonnet weekly, Gemini's Pro/Flash/Flash-Lite), your **monthly plan**, and any **pay-as-you-go credits**. The number in your menu bar is whatever's closest to running out.

The dollar figures for subscriptions are honest *estimates* (tokens × list price), not a bill — labeled as such. It won't do your taxes. It'll just nudge you before you hit a wall.

### Install
```sh
brew install --cask codexbar    # the engine it rides on
xcodegen generate && open NeedMoreTokens.xcodeproj   # then build it
```
Needs macOS 26 (Tahoe) and Xcode 26.

---

Menu bar today; a desktop widget is next. Companion to **[lord-claude](https://github.com/aylee1024/lord-claude)** · MIT · built on the lovely **[codexbar](https://github.com/steipete/CodexBar)** by [@steipete](https://github.com/steipete).
