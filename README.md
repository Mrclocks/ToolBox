# 🧡 MrClock ToolBox

ایمن‌سازی سرور VPN — **Ubuntu 22–26** و **Debian 12–13**

## 🚀 نصب

```bash
curl -fsSL https://github.com/Mrclocks/ToolBox/releases/latest/download/install.sh | sudo bash
```

بعدش فقط:

```bash
sudo mrclock
```

## ✨ قابلیت‌ها

- 🔄 آپدیت سیستم
- 🌐 DNS با تست سرعت واقعی روی سرور تو
- ⚡ BBR و تیونینگ شبکه
- 🛡️ UFW + Fail2Ban + SSH
- 🚫 بلاک رنج abuse *(اختیاری)*
- 🔒 خاموش کردن IPv6 *(اختیاری)*
- 🧹 پاک‌سازی لاگ Ubuntu / Docker
- ♻️ بازگردانی تغییرات قبلی (DNS/MTU/SSH/UFW/…)

گزینه ۱: **Automatic** (فقط UFW و IPv6 پرسیده می‌شود) یا **Customize**.

## ⚠️ نکته

بعد از عوض کردن پورت SSH، اول از ترمینال جدید وصل شو — سشن فعلی را نبند.

---

MIT © MrClock
