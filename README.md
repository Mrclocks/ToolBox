# SecureBox
#
# جعبه‌ابزار ایمن‌سازی و بهینه‌سازی سرور برای استفاده به‌عنوان endpoint انواع VPN
# (WireGuard، OpenVPN، Xray و مشابه) روی Ubuntu و Debian.

![Version](https://img.shields.io/badge/version-0.1.3-orange.svg)
![Status](https://img.shields.io/badge/status-release-brightgreen.svg)
![License](https://img.shields.io/badge/license-MIT-blue.svg)
![Platform](https://img.shields.io/badge/platform-Ubuntu%2022–26%20%7C%20Debian%2012–13-brightgreen.svg)
![Shell](https://img.shields.io/badge/shell-bash-informational.svg)

> **نسخه فعلی: `0.1.3`** — جواب‌های کاربر دقیق رعایت می‌شود؛ لینک نصب ثابت با `releases/latest`.

---

## این ابزار چیست؟

**SecureBox** یک اسکریپت ترمینالی تمیز و ماژولار است که سرور لینوکسی‌ات را برای کار VPN **سخت‌سازی** و **بهینه** می‌کند.

به‌جای چند اسکریپت پراکنده از گیت‌هاب، همه چیز در یک جعبه جمع شده:

- تشخیص خودکار سیستم‌عامل و مسیر واقعی شبکه / DNS
- منوی زیبا در ترمینال
- حالت **اعمال همه فیچرها** یا اجرای **تکی**
- اول همه سوال‌ها، بعد اجرای دقیق بر اساس جواب تو
- اگر جایی خطا خورد، اعلام می‌کند و تا جای ممکن مسیر را قطع نمی‌کند

متن رابط و لاگ‌ها **انگلیسی** است؛ این README برای راحتی به **فارسی** نوشته شده.

---

## سازگاری

| توزیع | نسخه‌ها |
|--------|---------|
| Ubuntu | 22، 23، 24، 25، 26 |
| Debian | 12، 13 |

اسکریپت مسیر درست را خودش پیدا می‌کند:

- **netplan** / **systemd-networkd** / **NetworkManager** / ifupdown
- **systemd-resolved** / resolv.conf / DNS از طریق NM

---

## نصب و اجرا (تک‌خطی)

همیشه **آخرین ریلیز** — لینک ثابت است و لازم نیست هر بار عوض شود:

```bash
curl -fsSL https://github.com/Mrclocks/ToolBox/releases/latest/download/install.sh | sudo bash
```

بعد از اولین اجرا، روی سرور نصب محلی می‌ماند. برای بارهای بعد حتی بدون اینترنت:

```bash
sudo mrclock
```

با فلگ:

```bash
curl -fsSL https://github.com/Mrclocks/ToolBox/releases/latest/download/install.sh | sudo bash -s -- --one-click
```

### روش‌های جایگزین

کلون آخرین تگ ریلیز:

```bash
git clone --branch "$(curl -fsSL https://api.github.com/repos/Mrclocks/ToolBox/releases/latest | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -n1)" https://github.com/Mrclocks/ToolBox.git
cd ToolBox
sudo bash install.sh
```

---

## منوی اصلی

```
1)  Apply All Features      ← همه فیچرها (پیشنهادی)
2)  System Update
3)  Time Sync
4)  DNS Resolver
5)  MTU Tuning
6)  BBR + Network Tuning
7)  Abuse IP Range Block
8)  UFW Autopilot
9)  SSH Port & Hardening
10) Fail2Ban
11) IPv6 Disable
12) Unattended Upgrades
13) Disable Unused Services
14) Status Report
0)  Exit
```

در حالت **Apply All** اول پرسشنامه کامل می‌آید، خلاصه انتخاب‌ها را می‌بینی، تأیید می‌کنی، بعد اجرا شروع می‌شود.

---

## فیچرها به زبان ساده

### ۱) آپدیت سیستم
پکیج‌ها را به‌روز و ارتقا می‌دهد و اگر نیاز به ریبوت باشد خبر می‌دهد.

### ۲) همگام‌سازی زمان
`chrony` را فعال می‌کند تا ساعت سرور برای VPN، TLS و Fail2Ban دقیق باشد.

### ۳) انتخاب DNS
لیستی از بهترین DNSها را نشان می‌دهد؛ یکی را انتخاب می‌کنی:

- Cloudflare  
- Google  
- Quad9  
- OpenDNS  
- AdGuard  
- نگه داشتن DNS فعلی  
- DNS سفارشی  

مسیر واقعی DNS روی همان سرور تشخیص داده می‌شود و تنظیم **درست و پایدار** اعمال می‌شود.

### ۴) تغییر MTU
روی اینترفیس اصلی سرور MTU را عوض می‌کند (زنده + ماندگار).  
برای VPN معمولاً مقادیر ۱۴۰۰ / ۱۴۲۰ / ۱۲۸۰ جلوی fragmentation و جیتر الکی را می‌گیرند.

### ۵) BBR و تیونینگ شبکه
نسخه پایدار کرنلی **BBR** با **fq** — سبک، استاندارد و حس‌شدنی روی پینگ/جیتر — به‌همراه sysctl مناسب ترافیک TCP/UDP و conntrack برای سشن‌های زیاد VPN.

### ۶) بلاک رنج‌های Abuse
لیست CIDRهای curated را **کامل** بلاک می‌کند (ورودی و خروجی) با `nftables` یا `iptables`، به‌همراه کاهش سرویس‌های کلاسیک abuse (مثل رله ایمیل/ریزالور باز در صورت فعال بودن).

فایل لیست: `data/abuse-ranges.txt` (قابل ویرایش و به‌روزرسانی).

### ۷) UFW هوشمند
پورت‌های در حال listen را کشف می‌کند، allowlist می‌سازد، قانون SSH را قبل از فعال‌سازی تضمین می‌کند، و UFW را طبق انتخاب تو روشن/خاموش می‌کند.

### ۸) تغییر پورت SSH + سخت‌گیری
پورت جدید اعمال می‌شود؛ **پورت قدیم تا وقتی از ترمینال جدید وصل نشده‌ای باز می‌ماند** تا قفل نشوی.  
سخت‌گیری‌هایی مثل `MaxAuthTries` و سیاست root/password (با سوال امن) هم هست.

### ۹) Fail2Ban
جلو حملات brute-force روی SSH (با پورت‌های فعلی/جدید).

### ۱۰) IPv6
ازت می‌پرسد؛ اگر بخواهی **کامل** غیرفعال می‌کند (sysctl + UFW + در صورت امکان grub).

### ۱۱) آپدیت امنیتی خودکار
`unattended-upgrades` برای پچ‌های امنیتی.

### ۱۲) خاموش کردن سرویس‌های بلااستفاده
لیست محافظه‌کارانه (avahi، cups، bluetooth و …) — بدون دست زدن اجباری به snapd.

### ۱۳) گزارش پایانی
وضعیت BBR، DNS، MTU، UFW، SSH، Fail2Ban، IPv6 و نتیجه ماژول‌ها.

---

## امنیت و ایمنی طراحی

- بکاپ کانفیگ‌های حساس قبل از تغییر (`/var/backups/securebox/`)
- لاگ کامل هر اجرا (`/var/log/securebox/`)
- تست `sshd -t` قبل از reload
- UFW بدون قانون SSH فعال نمی‌شود
- بلاک CIDRهای خیلی گشاد (مثل `/8`) از لیست فیلتر می‌شود
- خطای یک ماژول کل کار را بدون اطلاع قطع نمی‌کند؛ اول هشدار می‌دهد

---

## ساختار پروژه

```
install.sh          # نقطه ورود
lib/                # هسته، UI، تشخیص OS/شبکه، سوال‌ها، اجرا
modules/            # هر فیچر یک ماژول
data/               # لیست رنج‌های abuse
README.md
```

---

## نکات مهم برای VPN روی Hetzner

1. بعد از عوض کردن پورت SSH، **همین سشن را نبند**؛ از یک ترمینال جدید با پورت جدید تست کن.  
2. MTU سرور با MTU داخل تونل کلاینت فرق دارد؛ اگر کلاینت مشکل داشت، MTU/MSS کلاینت را هم چک کن.  
3. لیست abuse را قبل از اعمال در محیط حساس مرور کن؛ اگر کلاینت‌هایت از بعضی کلادها می‌آیند، همان رنج را از فایل حذف کن.  
4. این ابزار **پنل VPN نصب نمی‌کند**؛ سرور را برای هر استک VPN ایمن و سریع‌تر می‌کند.

---

## مجوز

MIT — آزاد برای استفاده و سفارشی‌سازی.

---

ساخته شده برای ادمین‌هایی که می‌خواهند سرور VPNشان **سریع، مرتب و کمتر دردسر abuse** باشد.
