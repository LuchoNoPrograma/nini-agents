[English](README.md) | [Español](README.es.md) | **العربية** | [中文](README.zh.md) | [Русский](README.ru.md) | [עברית](README.he.md)

<div dir="rtl">

# multi-cli

**شغّل عدة ملفات تعريف لحسابات أدوات البرمجة بالذكاء الاصطناعي في وقت واحد.**

يعزل ملف التعريف schema-v2 بيانات اعتماد الحساب وهوية الحصة، مع مشاركة الحالة العادية للأداة — المحادثات والإعدادات والوكلاء والمهارات والإضافات — حيث يوفر المورّد حدًا آمنًا. أما المنتجات التي تدمج المصادقة مع الجلسات أو مع حالة ثابتة في سلسلة المفاتيح، فتُصنَّف تجريبية أو غير مدعومة بدلًا من إعطائها ادعاء عزل زائفًا. لم يجتز أي محوّل بوابة التحقق من الحسابين المزدوجين حتى الآن؛ راجع [مصفوفة الدعم](docs/support-matrix.md) لمعرفة الحالة الدقيقة لكل منتج ومنصة ووضع مصادقة.

تظل ملفات التعريف schema-v1 الحالية ملفات تعريف قديمة ذات جذر كامل حتى يتم ترحيلها — راجع [ملفات التعريف القديمة](#legacy-profiles).

[![GitHub repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/Spielewoy/multi-codex)
[![GitHub profile](https://img.shields.io/badge/GitHub-Spielewoy-lightgrey?logo=github)](https://github.com/Spielewoy)
[![GitHub stars](https://img.shields.io/github/stars/Spielewoy/multi-codex?style=social)](https://github.com/Spielewoy/multi-codex/stargazers)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#install)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

---

## الأدوات المدعومة

يتضمن هذا المستودع 17 محوّلًا. الحالة لكل نظام تشغيل: `experimental` تعني وجود حد مرشح موثّق لكن التحقق الكامل من الحسابين المزدوجين لم ينجح بعد، و`unsupported` تعني أن multi-cli يرفض ادعاء عزل الحسابات. لا يوجد أي شيء موثَّق حتى الآن. المصدر المعتمد هو [docs/support-matrix.md](docs/support-matrix.md).

| الأداة | النوع | Windows | macOS | Linux |
|------|------|---------|-------|-------|
| [Claude Code](claude-cli/) | CLI | تجريبي | غير مدعوم (OAuth مخزَّن) | تجريبي |
| [OpenAI Codex CLI](codex/) | CLI | تجريبي | تجريبي | تجريبي |
| [Gemini CLI](gemini-cli/) | CLI | تجريبي | تجريبي | تجريبي |
| [OpenCode](opencode/) | CLI | غير مدعوم | غير مدعوم | غير مدعوم |
| [Command Code](commandcode/) | CLI | غير مدعوم | غير مدعوم | غير مدعوم |
| [Cursor Desktop](cursor/) | IDE | غير مدعوم | غير مدعوم | غير مدعوم |
| [Cursor CLI](cursor-cli/) | CLI | تجريبي | تجريبي | تجريبي |
| [Antigravity](antigravity/) | IDE | تجريبي | غير مدعوم | غير مدعوم |
| [AGY CLI](agy-cli/) | CLI | تجريبي | غير مدعوم | غير مدعوم |
| [Kiro](kiro/) | IDE | تجريبي | غير مدعوم | غير مدعوم |
| [Zed](zed/) | IDE | غير مدعوم | غير مدعوم | تجريبي |
| [Devin Desktop / Windsurf](windsurf/) | IDE | تجريبي | غير مدعوم | غير مدعوم |
| [GitHub Copilot CLI](copilot-cli/) | CLI | تجريبي | تجريبي | تجريبي |
| [Copilot في VS Code](copilot-vscode/) | IDE | تجريبي | غير مدعوم | غير مدعوم |
| [Kimi Code CLI](kimi-cli/) | CLI | تجريبي | تجريبي | تجريبي |
| [Codex Windows App](codex-gui/) | IDE | غير مدعوم | غير مدعوم | غير مدعوم |
| [Grok Build CLI](grok-cli/) | CLI/TUI | تجريبي | تجريبي | تجريبي |

لكل أداة مجلد خاص بها في جذر المستودع يحتوي على ملف `adapter.json` يصف حد الحساب والحالة العادية المشتركة والأدلة المطلوبة للترقية إلى حالة موثَّقة.

---

<a id="install"></a>

## التثبيت

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.sh | bash
```

**Windows** — افتح PowerShell:

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.ps1 | iex
```

> بعد التثبيت، **أعد تشغيل الطرفية** لتسري التغييرات على PATH.

### من المصدر

```bash
git clone https://github.com/Spielewoy/multi-codex.git
cd multi-codex
./scripts/install.sh --local        # macOS/Linux
.\scripts\install.ps1 -Local        # Windows
```

> بعد التثبيت، **أعد تشغيل الطرفية** لتسري التغييرات على PATH.

> يتم **تثبيت** [jq](https://jqlang.github.io/jq/) **تلقائيًا** بواسطة المثبِّت على جميع المنصات — لا حاجة لأي إعداد يدوي.

---

## البدء السريع

```bash
# Create a profile
multi-cli new claude-cli/work

# Launch it
multi-cli launch claude-cli/work

# Or use the shorthand
multi-cli claude-cli/work
```

يحصل كل ملف تعريف على اسم مستعار تلقائي في الصدفة:

| المنصة | الموقع |
|----------|----------|
| macOS / Linux | `~/MultiCliProfiles/bin/` (أضِفه إلى `PATH`) |
| Windows | تُنشأ اختصارات قائمة ابدأ تلقائيًا |

---

## الأوامر

### إدارة ملفات التعريف

| الأمر | الوصف |
|---------|-------------|
| `multi-cli new <tool>/<name>` | إنشاء ملف تعريف معزول جديد |
| `multi-cli new <tool>/<name> --shared` | ملف تعريف خفيف (إعدادات مشتركة، مصادقة معزولة) |
| `multi-cli new <tool>/<name> --from <tpl>` | الإنشاء من قالب محفوظ |
| `multi-cli <tool>/<name>` | تشغيل ملف تعريف (صيغة مختصرة) |
| `multi-cli launch <tool>/<name>` | تشغيل ملف تعريف |
| `multi-cli list [<tool>]` | عرض جميع ملفات التعريف |
| `multi-cli status` | عرض حالة التشغيل والنوع وآخر استخدام والحجم |
| `multi-cli clone <tool>/<src> <tool>/<dest>` | نسخ ملف تعريف موجود |
| `multi-cli rename <tool>/<old> <tool>/<new>` | إعادة تسمية ملف تعريف |
| `multi-cli delete <tool>/<name>` | حذف ملف تعريف وجميع بياناته |

### مصادقة الحسابات والترحيل

| الأمر | الوصف |
|---------|-------------|
| `multi-cli auth set <tool>/<profile>` | تخزين بيانات اعتماد السر التشغيلي لملف التعريف في مخزن بيانات الاعتماد الخاص بنظام التشغيل (يسأل تفاعليًا أو يقرأ سطرًا واحدًا من stdin) |
| `multi-cli auth status <tool>/<profile>` | الإبلاغ عما إذا كانت بيانات الاعتماد مخزنة لملف التعريف |
| `multi-cli auth clear <tool>/<profile>` | إزالة بيانات الاعتماد المخزنة |
| `multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]` | ترحيل ملف تعريف قديم schema-v1 إلى schema-v2 |

ينطبق `auth` فقط على المحوّلات التي تستخدم آلية `processSecret` ‏(`cursor-cli` و`copilot-cli` و`kimi-cli` و`grok-cli`). يظل التشغيل معطَّلًا حتى يتم تخزين بيانات الاعتماد. راجع [ملفات التعريف القديمة](#legacy-profiles) للاطلاع على `migrate`.

### القوالب

| الأمر | الوصف |
|---------|-------------|
| `multi-cli template save <tool>/<profile> <name>` | حفظ ملف تعريف كقالب قابل لإعادة الاستخدام |
| `multi-cli template list` | عرض القوالب المحفوظة |
| `multi-cli template delete <name>` | إزالة قالب |

### النسخ الاحتياطي والنقل

| الأمر | الوصف |
|---------|-------------|
| `multi-cli export <tool>/<name> [path]` | أرشفة ملف تعريف إلى `.tar.gz` ‏(`.zip` على Windows) |
| `multi-cli import <archive> <tool>/<name>` | استعادة ملف تعريف من أرشيف |

### الجلسات

| الأمر | الوصف |
|---------|-------------|
| `multi-cli continue <tool> <src> <dest>` | نسخ حالة المحادثة (الجلسات/النصوص/السجل) من ملف تعريف إلى آخر — لا تُنسخ بيانات الاعتماد أبدًا |
| `multi-cli continue <tool> <src> <dest> --no-merge` | استبدال ملفات الوجهة بدلًا من الاحتفاظ بالأحدث |
| `multi-cli continue <tool> <src> <dest> --dry-run` | معاينة ما سيتم نسخه دون تغيير أي شيء |

يعمل `base` كاسم ملف تعريف في أي من الطرفين ويعني مجلد المنزل الحقيقي للأداة (`~/.codex` و`~/.claude` و…). مدعوم لـ `codex` و`claude-cli` و`gemini-cli` و`commandcode`. راجع [متابعة محادثة عبر الحسابات](#continue-a-chat-across-accounts).

### الأدوات المساعدة

| الأمر | الوصف |
|---------|-------------|
| `multi-cli tools` | عرض جميع الأدوات المدعومة وحالة تثبيتها |
| `multi-cli stats` | عرض استخدام القرص لكل ملف تعريف |
| `multi-cli doctor` | تشخيص بيئتك |
| `multi-cli completion {bash\|zsh\|powershell}` | إعداد الإكمال التلقائي للصدفة |
| `multi-cli help` | عرض المساعدة |
| `multi-cli version` | عرض الإصدار |

---

## كيف يعمل العزل

تعلن محوّلات schema-v2 عن آلية حساب منفصلة عن الحالة العادية:

| الآلية | كيف تعمل |
|-----------|--------------|
| `fileOverlay` | تبقى بيانات الاعتماد داخل ملف التعريف؛ وترتبط الحالة العادية المعلنة بمنزل الأداة الأصلي المشترك. |
| `processSecret` | تُحقن بيانات اعتماد خاصة بكل ملف تعريف وذات أولوية قصوى في العملية الفرعية فقط. يظل التشغيل معطَّلًا حتى يتم تكوين تخزين آمن للأسرار. |
| `osUserCredentialStore` | تُفصل الهويات الثابتة في سلسلة المفاتيح بمستخدم نظام تشغيل مملوك لـ multi-cli. يظل هذا معطَّلًا حتى يتم التحقق من الملكية والتنظيف. |
| `inseparable` | يدمج المورّد المصادقة والحالة العادية؛ يفشل التشغيل المتوافق بشكل مغلق وتُعرَض المحدودية. |

تحتفظ ملفات تعريف الإصدار 1 بالسلوك السابق ذي الجذر الكامل (`env` و`userDataDir` و`redirectHome` و`appdata` و`sandboxUser`) للتوافق. يحدد كل `<id>/adapter.json` قدرات المنتج/المنصة ومتطلبات الأدلة.

---

<a id="continue-a-chat-across-accounts"></a>

## متابعة محادثة عبر الحسابات

هل بلغت حد المعدل على الحساب A في منتصف محادثة؟ بدّل إلى ملف تعريف مسجَّل الدخول بالحساب B واستأنف المحادثة من حيث توقفت. ينسخ `multi-cli continue` حالة المحادثة القابلة للنقل — الجلسات والنصوص والسجل — بين ملفات التعريف. **لا تُنسخ بيانات الاعتماد أبدًا.**

```bash
# You were working in codex/work (account A) and got rate-limited.
# codex/personal is logged into account B.
multi-cli continue codex work personal          # copy the conversation state
multi-cli continue codex work personal --dry-run  # preview first, if you like

codex-personal                                  # launch account B's profile
codex resume <session-id>                        # resume the same chat (codex ≥ 0.30)
```

شغّل `codex resume` دون وسيطة لفتح منتقي تفاعلي للجلسات السابقة، فلن تحتاج أبدًا إلى البحث عن معرّف. وإذا احتجته، فمعرّف الجلسة هو UUID الموجود في اسم ملف rollout ضمن `sessions/YYYY/MM/DD/`.

`base` اسم ملف تعريف صالح في أي من الطرفين ويشير إلى مجلد المنزل الحقيقي للأداة (`~/.codex` و`~/.claude` و…)، لذا يمكنك المتابعة من تثبيتك الافتراضي أو إليه.

افتراضيًا، يتم **دمج** الملفات — تُحتفظ بالملفات الأحدث في الوجهة. مرّر `--no-merge` لاستبدال الوجهة بدلًا من ذلك، أو `--dry-run` للمعاينة دون تغيير أي شيء.

بعد النسخ، استأنف داخل ملف التعريف الوجهة باستخدام أمر الأداة نفسه:

| الأداة | أمر الاستئناف |
|------|----------------|
| codex | `codex resume <session-id>` ‏(≥ 0.30) |
| claude-cli | `claude --resume <session-id>` (يُشغَّل من نفس مجلد المشروع) |
| gemini-cli | `gemini --resume` (آخر جلسة محفوظة تلقائيًا) أو `/chat resume <tag>` لنقاط التفتيش المحفوظة |
| commandcode | التشغيل من نفس مجلد العمل |

**غير مدعوم:** `opencode` (الجلسات وبيانات الاعتماد في قاعدة بيانات SQLite واحدة مشتركة) و`cursor` (تُخزَّن المحادثات في SQLite مفهرسة بمسار مساحة العمل).

> تُبذَر ملفات التعريف الجديدة من `base` افتراضيًا — حالة المحادثة، بالإضافة إلى أصول المهارات/الإعدادات لملفات التعريف الكاملة. مرّر `--no-seed` إلى `multi-cli new` للبدء فارغًا.

---

## أنواع ملفات التعريف

| العلامة | المعنى |
|------|---------|
| *(لا شيء)* | **كامل** — معزول تمامًا. مصادقة جديدة وإعدادات جديدة. |
| `--shared` | **مشترك** — روابط رمزية للإعدادات/الإضافات من تثبيتك الرئيسي. تبقى المصادقة معزولة. |
| `--cli` | **CLI** — يحدد ملف التعريف للتشغيل من الطرفية فقط (يتخطى اكتشاف واجهة GUI). |
| `--from <tpl>` | الاستنساخ من قالب محفوظ. |

---

## متغيرات البيئة

| المتغير | الافتراضي | الغرض |
|----------|---------|---------|
| `MULTICLI_HOME` | `~/MultiCliProfiles` | مكان تخزين جميع ملفات التعريف |
| `MULTICLI_OVERRIDE_BINARY` | *(غير معيَّن)* | فرض مسار ثنائي محدد للتشغيل التالي |
| `MULTICLI_REPO` | *(غير معيَّن)* | رابط Git للتثبيت عن بُعد |
| `MULTICLI_PLATFORM` | *(تلقائي)* | تجاوز كشف المنصة (`darwin` و`linux`) |

---

<a id="legacy-profiles"></a>

## ملفات التعريف القديمة

ملفات التعريف التي أُنشئت قبل schema-v2 هي ملفات تعريف قديمة ذات جذر كامل: تحتفظ بالسلوك السابق لـ `env` و`userDataDir` و`redirectHome` و`appdata` و`sandboxUser` للتوافق. يُعامَل مجلد ملف التعريف الذي لا يحتوي على ملف `.profile.json` كملف قديم.

يحوّل `multi-cli migrate <tool>/<name>` ملف التعريف القديم إلى schema-v2: تنتقل بيانات الاعتماد المعلنة إلى ملف التعريف، وترتبط الحالة العادية المعلنة بمنزل الأداة المشترك. استخدم `--dry-run` لمعاينة خطة النقل دون تغيير أي شيء، و`--prefer-profile` لاستبدال الملفات المشتركة المتعارضة بنسخة ملف التعريف — لا تُستبدَل أهداف بيانات الاعتماد أبدًا. يجب أن يكون تخزين ملفات التعريف وجذر الحالة المشتركة على نفس وحدة التخزين، لأن الترحيل يستخدم نقلًا ذريًا ضمن نفس وحدة التخزين.

---

## التشخيص

```bash
multi-cli doctor
```

يتحقق من وجود تخزين ملفات التعريف، وأن مجلد الأسماء المستعارة موجود في PATH، وأن ثنائي كل أداة مكتشَف (أو يعرض تلميح تثبيت).

---

## الإكمال التلقائي للصدفة

```bash
multi-cli completion bash   # or zsh, powershell
```

اتبع التعليمات لإضافته إلى `.zshrc` أو `.bashrc` أو `$PROFILE` في PowerShell.

---

## إلغاء التثبيت

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.sh | bash
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.ps1 | iex
```

سُتسأل عمّا إذا كنت تريد إزالة بيانات ملفات التعريف — لا يُحذَف أي شيء دون تأكيد.

---

## روابط

- [مصفوفة الدعم](docs/support-matrix.md) — حالة العزل لكل منتج ونظام تشغيل وبوابة التحقق
- [سياسة الأمان](SECURITY.md)
- [الرخصة](LICENSE)
- [مستودع GitHub](https://github.com/Spielewoy/multi-codex)

---

## شكر وتقدير

- **المؤلف** — [Spielewoy](https://github.com/Spielewoy)

---

<a id="license"></a>

## الرخصة

[MIT](LICENSE)

</div>
