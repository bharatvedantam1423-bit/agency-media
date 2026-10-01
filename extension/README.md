# Agency Signal Lens (Chrome extension)

Labels posts while you browse **X, Instagram and Contra**, and auto-scrolls **any website** in timed sets.

## Labels

| Label | Meaning |
|---|---|
| 🔥 Trending | Gaining engagement much faster than the posts you've seen (top 10%, or 400+ per hour) |
| 🚀 Next trend | Under 6 hours old and already faster than 75% of posts you've seen |
| ✅ Good post | Specific and concrete (real numbers, names, work) |
| ⚠️ Weak | Vague and generic |
| 🤖 AI slop | Reads like generic AI filler |
| 🎨 Design/agency | About design agencies, studios or personal-brand designers |

Hover any label to see why it was given. Labels show instantly from quick text rules, then Laya's answer replaces them a moment later.

## Install (2 minutes)

1. Unzip the folder.
2. Open `chrome://extensions` and turn on **Developer mode** (top right).
3. Click **Load unpacked** and pick the `extension` folder.
4. Pin **Agency Signal Lens** to the toolbar.

## Turn on Laya (free, recommended)

In Terminal:

```bash
pip install "laya[serve]"
laya-serve
```

Leave it running while you browse. Then open the extension's **Settings** and click **Test Laya**.

## Send posts to the dashboard (optional)

Go to **Settings** and tick "Send posts I see to the dashboard". Then paste in your Supabase publishable key and your worker token. The fresh X, Instagram and Contra posts you scroll past will then appear in Agency Signal.

## Auto-scroll

Click the extension icon, set the minutes per set (default 30), the number of sets, the break between sets and the speed, then click **Start**. It works on any website. To stop, press **Esc** or click the timer in the bottom-right corner.

Auto-scrolling social sites for long stretches can look automated to them. Keep the speed normal, and use a secondary account if you're worried.
