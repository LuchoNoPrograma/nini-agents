[English](README.md) | [Español](README.es.md) | [العربية](README.ar.md) | [中文](README.zh.md) | [Русский](README.ru.md) | **עברית**

<div dir="rtl">

# multi-cli

**הפעלת מספר פרופילי חשבון של כלי תכנות מבוססי AI בו-זמנית.**

פרופיל schema-v2 מבודד את אישורי החשבון ואת זהות המכסה, תוך שיתוף המצב הרגיל של הכלי — שיחות, תצורה, סוכנים, מיומנויות ותוספים — במקומות שבהם הספק חושף גבול בטוח. מוצרים שמשלבים אימות עם סשנים או עם מצב קבוע של צרור המפתחות מסומנים כניסיוניים או כלא נתמכים, במקום לקבל טענת בידוד שגויה. אף מתאם עדיין לא עבר את שער האימות של שני חשבונות בו-זמנית; ראו [מטריצת התמיכה](docs/support-matrix.md) לסטטוס המדויק לפי מוצר, פלטפורמה ומצב אימות.

פרופילי schema-v1 קיימים נשארים פרופילים מדור קודם בעלי שורש מלא עד שיועברו — ראו [פרופילים מדור קודם](#legacy-profiles).

[![GitHub repository](https://img.shields.io/badge/GitHub-Repository-blue?logo=github)](https://github.com/Spielewoy/multi-codex)
[![GitHub profile](https://img.shields.io/badge/GitHub-Spielewoy-lightgrey?logo=github)](https://github.com/Spielewoy)
[![GitHub stars](https://img.shields.io/github/stars/Spielewoy/multi-codex?style=social)](https://github.com/Spielewoy/multi-codex/stargazers)
[![Platform](https://img.shields.io/badge/platform-macOS%20%7C%20Linux%20%7C%20Windows-lightgrey)](#install)
[![License](https://img.shields.io/badge/license-MIT-green)](#license)

---

## כלים נתמכים

המאגר כולל 17 מתאמים. הסטטוס נקבע לכל מערכת הפעלה בנפרד: `experimental` פירושו שקיים גבול מועמד מתועד אך אימות מלא של שני חשבונות עדיין לא עבר, ו-`unsupported` פירושו ש-multi-cli מסרב לטעון לבידוד חשבונות. דבר עדיין לא אומת. המקור הסמכותי הוא [docs/support-matrix.md](docs/support-matrix.md).

| כלי | סוג | Windows | macOS | Linux |
|------|------|---------|-------|-------|
| [Claude Code](claude-cli/) | CLI | ניסיוני | לא נתמך (OAuth מאוחסן) | ניסיוני |
| [OpenAI Codex CLI](codex/) | CLI | ניסיוני | ניסיוני | ניסיוני |
| [Gemini CLI](gemini-cli/) | CLI | ניסיוני | ניסיוני | ניסיוני |
| [OpenCode](opencode/) | CLI | לא נתמך | לא נתמך | לא נתמך |
| [Command Code](commandcode/) | CLI | לא נתמך | לא נתמך | לא נתמך |
| [Cursor Desktop](cursor/) | IDE | לא נתמך | לא נתמך | לא נתמך |
| [Cursor CLI](cursor-cli/) | CLI | ניסיוני | ניסיוני | ניסיוני |
| [Antigravity](antigravity/) | IDE | ניסיוני | לא נתמך | לא נתמך |
| [AGY CLI](agy-cli/) | CLI | ניסיוני | לא נתמך | לא נתמך |
| [Kiro](kiro/) | IDE | ניסיוני | לא נתמך | לא נתמך |
| [Zed](zed/) | IDE | לא נתמך | לא נתמך | ניסיוני |
| [Devin Desktop / Windsurf](windsurf/) | IDE | ניסיוני | לא נתמך | לא נתמך |
| [GitHub Copilot CLI](copilot-cli/) | CLI | ניסיוני | ניסיוני | ניסיוני |
| [Copilot ב-VS Code](copilot-vscode/) | IDE | ניסיוני | לא נתמך | לא נתמך |
| [Kimi Code CLI](kimi-cli/) | CLI | ניסיוני | ניסיוני | ניסיוני |
| [Codex Windows App](codex-gui/) | IDE | לא נתמך | לא נתמך | לא נתמך |
| [Grok Build CLI](grok-cli/) | CLI/TUI | ניסיוני | ניסיוני | ניסיוני |

לכל כלי תיקייה משלו בשורש המאגר עם קובץ `adapter.json` שמתאר את גבול החשבון, את המצב הרגיל המשותף ואת הראיות הנדרשות לקידום לסטטוס מאומת.

---

<a id="install"></a>

## התקנה

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.sh | bash
```

**Windows** — פתחו PowerShell:

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/install.ps1 | iex
```

> לאחר ההתקנה, **הפעילו מחדש את הטרמינל** כדי ששינויי ה-PATH ייכנסו לתוקף.

### מקוד המקור

```bash
git clone https://github.com/Spielewoy/multi-codex.git
cd multi-codex
./scripts/install.sh --local        # macOS/Linux
.\scripts\install.ps1 -Local        # Windows
```

> לאחר ההתקנה, **הפעילו מחדש את הטרמינל** כדי ששינויי ה-PATH ייכנסו לתוקף.

> [jq](https://jqlang.github.io/jq/) **מותקן אוטומטית** על ידי תוכנית ההתקנה בכל הפלטפורמות — אין צורך בהגדרה ידנית.

---

## התחלה מהירה

```bash
# Create a profile
multi-cli new claude-cli/work

# Launch it
multi-cli launch claude-cli/work

# Or use the shorthand
multi-cli claude-cli/work
```

כל פרופיל מקבל כינוי shell אוטומטי:

| פלטפורמה | מיקום |
|----------|----------|
| macOS / Linux | `~/MultiCliProfiles/bin/` (הוסיפו ל-`PATH`) |
| Windows | קיצורי דרך בתפריט ההתחלה נוצרים אוטומטית |

---

## פקודות

### ניהול פרופילים

| פקודה | תיאור |
|---------|-------------|
| `multi-cli new <tool>/<name>` | יצירת פרופיל מבודד חדש |
| `multi-cli new <tool>/<name> --shared` | פרופיל קל (הגדרות משותפות, אימות מבודד) |
| `multi-cli new <tool>/<name> --from <tpl>` | יצירה מתבנית שמורה |
| `multi-cli <tool>/<name>` | הפעלת פרופיל (קיצור) |
| `multi-cli launch <tool>/<name>` | הפעלת פרופיל |
| `multi-cli list [<tool>]` | הצגת כל הפרופילים |
| `multi-cli status` | הצגת מצב ריצה, סוג, שימוש אחרון וגודל |
| `multi-cli clone <tool>/<src> <tool>/<dest>` | העתקת פרופיל קיים |
| `multi-cli rename <tool>/<old> <tool>/<new>` | שינוי שם של פרופיל |
| `multi-cli delete <tool>/<name>` | מחיקת פרופיל וכל הנתונים שלו |

### אימות חשבונות והעברה

| פקודה | תיאור |
|---------|-------------|
| `multi-cli auth set <tool>/<profile>` | שמירת אישור הסוד התהליכי של הפרופיל במאגר האישורים של מערכת ההפעלה (שואל באופן אינטראקטיבי או קורא שורה אחת מ-stdin) |
| `multi-cli auth status <tool>/<profile>` | דיווח האם מאוחסנים אישורים עבור הפרופיל |
| `multi-cli auth clear <tool>/<profile>` | הסרת האישורים המאוחסנים |
| `multi-cli migrate <tool>/<name> [--dry-run] [--prefer-profile]` | העברת פרופיל schema-v1 מדור קודם ל-schema-v2 |

`auth` חל רק על מתאמים המשתמשים במנגנון `processSecret` ‏(`cursor-cli`, `copilot-cli`, `kimi-cli`, `grok-cli`). ההפעלה נשארת מושבתת עד שמאוחסנים אישורים. ראו [פרופילים מדור קודם](#legacy-profiles) לגבי `migrate`.

### תבניות

| פקודה | תיאור |
|---------|-------------|
| `multi-cli template save <tool>/<profile> <name>` | שמירת פרופיל כתבנית לשימוש חוזר |
| `multi-cli template list` | הצגת תבניות שמורות |
| `multi-cli template delete <name>` | הסרת תבנית |

### גיבוי והעברה

| פקודה | תיאור |
|---------|-------------|
| `multi-cli export <tool>/<name> [path]` | ארכוב פרופיל ל-`.tar.gz` ‏(`.zip` ב-Windows) |
| `multi-cli import <archive> <tool>/<name>` | שחזור פרופיל מארכיון |

### סשנים

| פקודה | תיאור |
|---------|-------------|
| `multi-cli continue <tool> <src> <dest>` | העתקת מצב השיחה (סשנים/תמלילים/היסטוריה) מפרופיל אחד לאחר — אישורים לעולם אינם מועתקים |
| `multi-cli continue <tool> <src> <dest> --no-merge` | דריסת קבצי היעד במקום שמירת החדשים יותר |
| `multi-cli continue <tool> <src> <dest> --dry-run` | תצוגה מקדימה של מה שיועתק, ללא שינוי דבר |

`base` עובד כשם פרופיל בכל אחד מהצדדים ומשמעותו תיקיית הבית האמיתית של הכלי (`~/.codex`, `~/.claude`, …). נתמך עבור `codex`, `claude-cli`, `gemini-cli` ו-`commandcode`. ראו [המשך שיחה בין חשבונות](#continue-a-chat-across-accounts).

### כלי עזר

| פקודה | תיאור |
|---------|-------------|
| `multi-cli tools` | הצגת כל הכלים הנתמכים וסטטוס ההתקנה שלהם |
| `multi-cli stats` | הצגת שימוש בדיסק לכל פרופיל |
| `multi-cli doctor` | אבחון הסביבה שלך |
| `multi-cli completion {bash\|zsh\|powershell}` | הגדרת השלמה אוטומטית ל-shell |
| `multi-cli help` | הצגת עזרה |
| `multi-cli version` | הצגת גרסה |

---

## איך הבידוד עובד

מתאמי schema-v2 מצהירים על מנגנון חשבון בנפרד מהמצב הרגיל:

| מנגנון | איך זה עובד |
|-----------|--------------|
| `fileOverlay` | האישורים נשארים בתוך הפרופיל; המצב הרגיל המוצהר מקושר לבית המשותף המקורי של הכלי. |
| `processSecret` | אישור ייחודי לפרופיל, בעל קדימות עליונה, מוזרק רק לתהליך הבן. ההפעלה נשארת מושבתת עד שמוגדר אחסון סודות מאובטח. |
| `osUserCredentialStore` | זהויות קבועות של צרור המפתחות מופרדות באמצעות משתמש מערכת הפעלה בבעלות multi-cli. נשאר מושבת עד שאומתו הבעלות והניקוי. |
| `inseparable` | הספק משלב אימות ומצב רגיל; הפעלה תקינה נכשלת באופן סגור והמגבלה מוצגת. |

פרופילי גרסה 1 שומרים על התנהגות השורש המלא הקודמת (`env`, `userDataDir`, `redirectHome`, `appdata` ו-`sandboxUser`) לצורך תאימות. כל `<id>/adapter.json` מציין את יכולות המוצר/הפלטפורמה ואת דרישות הראיות.

---

<a id="continue-a-chat-across-accounts"></a>

## המשך שיחה בין חשבונות

נתקלתם במגבלת קצב בחשבון A באמצע שיחה? עברו לפרופיל המחובר לחשבון B והמשיכו את השיחה מהנקודה שבה היא נעצרה. `multi-cli continue` מעתיק את מצב השיחה הנייד — סשנים, תמלילים, היסטוריה — בין פרופילים. **אישורים לעולם אינם מועתקים.**

```bash
# You were working in codex/work (account A) and got rate-limited.
# codex/personal is logged into account B.
multi-cli continue codex work personal          # copy the conversation state
multi-cli continue codex work personal --dry-run  # preview first, if you like

codex-personal                                  # launch account B's profile
codex resume <session-id>                        # resume the same chat (codex ≥ 0.30)
```

הריצו `codex resume` ללא ארגומנט כדי לפתוח בורר אינטראקטיבי של סשנים קודמים, כך שלעולם לא תצטרכו לחפש מזהה. אם בכל זאת צריך, מזהה הסשן הוא ה-UUID בשם קובץ ה-rollout תחת `sessions/YYYY/MM/DD/`.

`base` הוא שם פרופיל חוקי בכל אחד מהצדדים ומתייחס לתיקיית הבית האמיתית של הכלי (`~/.codex`, `~/.claude`, …), כך שאפשר להמשיך אל ההתקנה ברירת המחדל או ממנה.

כברירת מחדל, הקבצים **ממוזגים** — הקבצים החדשים יותר ביעד נשמרים. העבירו `--no-merge` כדי לדרוס את היעד במקום, או `--dry-run` לתצוגה מקדימה ללא שינוי דבר.

לאחר ההעתקה, המשיכו בתוך פרופיל היעד עם הפקודה של הכלי עצמו:

| כלי | פקודת המשך |
|------|----------------|
| codex | `codex resume <session-id>` ‏(≥ 0.30) |
| claude-cli | `claude --resume <session-id>` (להריץ מאותה תיקיית פרויקט) |
| gemini-cli | `gemini --resume` (הסשן האחרון שנשמר אוטומטית) או `/chat resume <tag>` לנקודות ביקורת שמורות |
| commandcode | הפעלה מאותה תיקיית עבודה |

**לא נתמך:** `opencode` (סשנים ואישורים חיים במסד נתונים SQLite משותף אחד) ו-`cursor` (שיחות מאוחסנות ב-SQLite עם מפתח לפי נתיב סביבת העבודה).

> פרופילים חדשים נזרעים מ-`base` כברירת מחדל — מצב השיחה, ובנוסף נכסי מיומנויות/תצורה עבור פרופילים מלאים. העבירו `--no-seed` ל-`multi-cli new` כדי להתחיל ריק.

---

## סוגי פרופילים

| דגל | משמעות |
|------|---------|
| *(ללא)* | **מלא** — מבודד לחלוטין. אימות חדש, תצורה חדשה. |
| `--shared` | **משותף** — קישורים סימבוליים להגדרות/תוספים מההתקנה הראשית. האימות נשאר מבודד. |
| `--cli` | **CLI** — מסמן את הפרופיל להפעלה מטרמינל בלבד (מדלג על זיהוי GUI). |
| `--from <tpl>` | שיבוט מתבנית שמורה. |

---

## משתני סביבה

| משתנה | ברירת מחדל | מטרה |
|----------|---------|---------|
| `MULTICLI_HOME` | `~/MultiCliProfiles` | היכן מאוחסנים כל הפרופילים |
| `MULTICLI_OVERRIDE_BINARY` | *(לא מוגדר)* | כפיית נתיב בינארי ספציפי להפעלה הבאה |
| `MULTICLI_REPO` | *(לא מוגדר)* | כתובת Git להתקנה מרחוק |
| `MULTICLI_PLATFORM` | *(אוטומטי)* | עקיפת זיהוי הפלטפורמה (`darwin`, `linux`) |

---

<a id="legacy-profiles"></a>

## פרופילים מדור קודם

פרופילים שנוצרו לפני schema-v2 הם פרופילים מדור קודם בעלי שורש מלא: הם שומרים על ההתנהגות הקודמת של `env`, `userDataDir`, `redirectHome`, `appdata` ו-`sandboxUser` לצורך תאימות. תיקיית פרופיל ללא קובץ `.profile.json` נחשבת לדור קודם.

`multi-cli migrate <tool>/<name>` ממיר פרופיל מדור קודם ל-schema-v2: האישורים המוצהרים עוברים לתוך הפרופיל, והמצב הרגיל המוצהר מקושר לבית המשותף של הכלי. השתמשו ב-`--dry-run` כדי לראות את תוכנית ההעברה מבלי לשנות דבר, וב-`--prefer-profile` כדי להחליף קבצים משותפים מתנגשים בעותק של הפרופיל — יעדי אישורים לעולם אינם נדרסים. אחסון הפרופילים ושורש המצב המשותף חייבים להיות באותו כרך, מכיוון שההעברה משתמשת בהעברות אטומיות בתוך אותו כרך.

---

## אבחון

```bash
multi-cli doctor
```

בודק שאחסון הפרופילים קיים, שתיקיית הכינויים נמצאת ב-PATH, ושהבינארי של כל כלי מזוהה (או מציג רמז להתקנה).

---

## השלמה אוטומטית ל-shell

```bash
multi-cli completion bash   # or zsh, powershell
```

עקבו אחר ההוראות כדי להוסיף זאת ל-`.zshrc`, ל-`.bashrc` או ל-`$PROFILE` של PowerShell.

---

## הסרת התקנה

**macOS / Linux**

```bash
curl -fsSL https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.sh | bash
```

**Windows**

```powershell
irm https://raw.githubusercontent.com/Spielewoy/multi-codex/main/scripts/uninstall.ps1 | iex
```

תישאלו אם להסיר את נתוני הפרופילים — דבר לא נמחק ללא אישור.

---

## קישורים

- [מטריצת תמיכה](docs/support-matrix.md) — סטטוס בידוד לפי מוצר ומערכת הפעלה, ושער האימות
- [מדיניות אבטחה](SECURITY.md)
- [רישיון](LICENSE)
- [מאגר GitHub](https://github.com/Spielewoy/multi-codex)

---

## קרדיטים

- **יוצר** — [Spielewoy](https://github.com/Spielewoy)

---

<a id="license"></a>

## רישיון

[MIT](LICENSE)

</div>
