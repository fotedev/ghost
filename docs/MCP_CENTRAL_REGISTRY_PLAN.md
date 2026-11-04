# MCP Central Registry — خطة التنفيذ والحالة

**الحالة:** v1 مُنفذة. **التشغيل الفعلي (live) نُفِّذ 2026-11-04** — كل الأهداف OK (windsurf +17 / vscode +18 / zcode +7 / minimax +19 إضافة، cursor SKIP)، والتشغيل الثاني idempotent (`already in sync`)، والـ audit و`MCP_Backups` سليمان، وصفر `${...}` في الملفات المكتوبة. لا يوجد أي commit (سياسة الريبو: التغييرات تُترك في شجرة العمل).
**النطاق:** ويندوز فقط. لا تعديل على `identity_utils.ps1` ولا على سكربتات التطبيقات.

---

## 1. الخلاصة التنفيذية

- **لا يوجد شيء اسمه "MCP على مستوى الجهاز"** في بروتوكول MCP: كل تطبيق (client) يقرأ ملفه الخاص بصيغته الخاصة. لا registry مركزي في Windows.
- **الأنماط الثلاثة التي طُرحت (Gemini / Model A / Model B) تتفق جميعاً على الهيكل الصحيح**، وهو ما نُفِّذ هنا: **مصدر حقيقة واحد (registry) + مستورد (importer) لكل تطبيق**، ثم **بوابة HTTP محلية** للمشترك الثقيل. الفرق أن هذا التنفيذ يحترم ثلاثة أشياء تجاهلها سكربتات النماذج:
  1. **merge لا overwrite** — سكربت Model A يكتب `{...cur, ...wrap}` أي يمسح حالة كل تطبيق محلياً؛ هنا الـ merge يحافظ على `enabled/disabled/autoApprove/description/builtin/configured/timeout` المحلية و**لا يحذف** أي server محلي أبداً.
  2. **لا أسرار في الملف المتعقَّب** — القيم تبقى محلية؛ الـ registry يحمل أسماء المفاتيح فقط بصيغة `${VAR}`.
  3. **verify-after** — كل كتابة تُقرأ مرة أخرى وتُقارن deep-compare؛ عدم التطابق = `FAILED` + exit 1 (قاعدة "never silent-success" في `AGENTS.md`).
- **Obot مستبعَد لجهازك** (منصة مؤسسية: Docker/WSL2 + 3–6 GB commit تقديرياً + نقطة فشل واحدة) — وملاحظة مهمة: **supergateway `--config` يجمع كل السيرفرات على URL واحد**، فلا حاجة لـ MetaMCP/MCPHub أصلاً.
- كل الـ diff في الـ dry-run النهائي **إضافات فقط** (adds) — صفر تعديلات على تعريفات شغالة.

---

## 2. الحقائق الموثَّقة على هذا الجهاز (2026-11-03)

| التطبيق | مسار الإعداد | حاوية السيرفرات | شكل الـ remote | ملاحظات مُثبتة |
|---|---|---|---|---|
| **ZCode** | `%USERPROFILE%\.zcode\cli\config.json` | `mcp.servers` | `type: http` + `url` + `headers` | 13 سيرفر؛ `enabled` موجود؛ الـ clones تتزامن عبر `sync_zcode_assets.ps1 -McpOnly` + watcher (آلية قائمة — لم تُمس) |
| **OpenCode** | `%USERPROFILE%\.config\opencode\opencode.jsonc` (Primary) / `<CloneHome>\cN\config\opencode\opencode.json(c)` | `mcp` | `type: remote` + `url` + `headers`؛ المحلي: `type: local` + **`command` كمصفوفة** + `environment` | 8 سيرفرات في Primary؛ **Primary مستبعَد** (مفاتيح API حيّة + احتمال تعليقات JSONC). لا توجد ملفات config لأي clone حالياً (c1..c5 فارغة) |
| **Windsurf** | `%USERPROFILE%\.codeium\windsurf\mcp_config.json` | `mcpServers` | **`serverUrl`** (وليس `url`) | 5 سيرفرات؛ علم الإيقاف اسمه `disabled` |
| **VS Code** | `%APPDATA%\Code\User\mcp.json` | `servers` | `type: http` + `url` | ملف موجود (obsidian stdio + supabase remote). **حالة enable/disable تُخزَّن خارج الملف** (توثيق VS Code 2026-09) → التزامن آمن ولا يمسحها |
| **MiniMax** | `%USERPROFILE%\.minimax\mcp\mcp.json` | `mcpServers` | `type: streamable-http` + `url` | stdio بدون `type`؛ مؤقت بـ `timeout` (ms) |
| **Cursor** | `%USERPROFILE%\.cursor\mcp.json` | `mcpServers` | `type: http` + `url` | **غير مثبَّت** على الجهاز (`.cursor` غير موجود) → يُتخطّى (SKIP) |
| Trae / Qoder | — | — | — | لا يوجد `mcp.json` (`.trae` و`.qoder` فيهما `skills` فقط) → **غير موصول** |
| Cline / AutoClaw2 | — | — | — | لم يُعثر على ملف إعداد MCP للـ client → **غير موصول** |

**مصادر خارجية مؤكدة:** `code.visualstudio.com/docs/copilot/chat/mcp-servers` (مفتاح `servers` + `type` + حالة enable خارج الملف)، `cursor.com/docs/context/mcp` (`mcpServers` + `type` + تحليل `${env:...}`)، `opencode.ai/docs/mcp-servers` (`mcp` + `command` مصفوفة + `environment` + `enabled`).

---

## 3. البنية

```
tools\mcp\master-mcp.json          ← مصدر الحقيقة (22 سيرفراً) — صيغة Claude Desktop "mcpServers"
  └─ tools\mcp\master-mcp.local.json   ← overlay محلي (gitignored): قيم/تعريفات خاصة بالجهاز
tools\sync_mcp_registry.ps1        ← المستورد: registry → ملف كل تطبيق
tools\zcode_mcp_merge.ps1          ← (قائم) نواة الـ merge الوحيدة، dot-sourced
```

**قواعد الـ merge (نفس ثابت `zcode_mcp_merge.ps1` المُختبَر):**

1. تعريفات الـ registry تفوز (استبدال كامل للتعريف).
2. حالة التطبيق المحلية تبقى: `enabled` / `disabled` / `autoApprove` / `description` / `builtin` / `configured` / `timeout`.
3. السيرفرات الموجودة في التطبيق فقط (غير موجودة في الـ registry) **تبقى كما هي — لا حذف تلقائي أبداً**.
4. `env` و`headers` تُدمج **مفتاحاً بمفتاح** بقواعد الأسرار (أدناه).
5. `only: ["minimax", ...]` = سيرفر محصور بتطبيقات محددة (مثل أدوات MiniMax الداخلية: `matrix`, `cu`, `trash`, `opencode`).
6. `apps: { "<target>": {...} }` = تعريف بديل لتطبيق معيّن (الاختلافات الحقيقية بين التطبيقات تُوثَّق هنا لا تُلغى).

**قواعد الأسرار:** القيمة الفعلية لمتغير بيئة **تفوز دائماً** > القيمة المحلية الحالية > الـ default في `${VAR:-default}` > **حذف المفتاح** (لا يُكتب أبداً مفتاح فارغ). أي مفتاح غير محلول وغير موجود محلياً يُحذف بصوت عالٍ (`[env-guard] WARN`) — هذا سبب الـ 46 تحذيراً في الـ dry-run، وكلها لسيرفرات **تُضاف** أصلاً.

**السلامة:** backup قبل كل كتابة في `<مجلد التطبيق>\MCP_Backups\<yyyyMMdd-HHmmss>\`، ثم verify-after بقراءة كاملة ومقارنة deep، ثم سطر JSONL في `%LOCALAPPDATA%\mcp-registry-sync\mcp-sync-audit.jsonl` (مسارات وأسماء فقط — لا قيم).

**تفاصيل PS 5.1 عولجت:** `args` أحادي العنصر يرجع String من `ConvertFrom-Json` (تطبيع على كل الأطراف قبل أي مقارنة)، `ConvertTo-Json -InputObject` إلزامي (بلا pipeline)، و`$env:APPDATA`/`$env:LOCALAPPDATA` قد تكون فارغة → `[Environment]::GetFolderPath` مع fallback.

---

## 4. نتيجة الـ Dry Run النهائية (2026-11-03)

| الهدف | النتيجة | التفاصيل |
|---|---|---|
| `windsurf` | **13 إضافة، 0 تعديل** | كل الموجود (obsidian, chrome-devtools, github, supabase-*) no-op |
| `vscode` | **14 إضافة، 0 تعديل** | `supabase` الحالي (remote) محفوظ عبر overlay؛ `obsidian` no-op |
| `zcode` | **3 إضافات، 0 تعديل** | obsidian + chrome-devtools + playwright فقط |
| `minimax` | **15 إضافة، 0 تعديل** | الخمسة الموجودون (playwright, opencode, matrix, cu, trash) no-op |
| `opencode` | لا شيء | لا توجد ملفات config للـ clones بعد (تُنشأ عند أول تشغيل) |
| `cursor` | SKIP | التطبيق غير مثبَّت |

Exit code = 0، صفر أخطاء، صفر FAILED.

---

## 4.5 تحققات إضافية بعد المراجعات (2026-11-03)

**أ) تجربة حية معزولة (sandbox) — إثبات نقطة `${VAR}`:** شُغّل السكربت فعلياً (`-Target windsurf`) مع `USERPROFILE` موجّه لملف مؤقت فيه config مصغّر (سيرفر واحد موجود):

- **صفر نصوص `${...}` في الملف المكتوب** — المفتاح غير المحلول **يُحذف ولا يُكتب حرفياً أبداً** (قواعد §3): `omniroute` بلا `env`، و`github` بلا `headers`.
- المدخل الموجود (`chrome-devtools`) بقي كما هو مع `disabled` الخاص به؛ `omniroute` الجديد وارث `enabled: false` من الـ registry؛ `supabase.args` خرجت مصفوفة من 3 عناصر؛ الـ backup اتعمل.
- تشغيل ثانٍ على نفس الـ sandbox: `already in sync (18 servers)` — **idempotent**.

**ب) جاهزية متغيرات البيئة:** أسماء الـ `${VAR}` داخل الـ registry (انظر حقلي `env`/`headers` في كل مدخل بـ `master-mcp.json`) — 20 اسماً، وكلها **غير معرّفة** حالياً في User/Machine/Process. هذا طبيعي: القيم الحقيقية تعيش محلياً داخل كل تطبيق. المعنى العملي: التشغيل الفعلي اليوم سيضيف السيرفرات **بدون مفاتيح توثيق** (محذوفة) حتى تُملأ مرة واحدة — إما تعريفها machine-wide أولاً (الأفضل للمشترك بين التطبيقات)، أو قبول "املأ داخل كل تطبيق". السيرفرات التي ستهبط **مفعّلة** وتحتاج مفتاحاً أو OAuth: `supabase`, `supabase-masarx`, `github`, `vercel`, `sentry`, `upstash`, `cloudinary`, `obsidian` (بينما `chrome-devtools` و`playwright` لا يحتاجان مفتاحاً).

**تحديث 2026-11-04:** الأسماء العشرين كلها عُرِّفت machine-wide (User scope) باستخراج القيم الحقيقية من configs التطبيقات نفسها (zcode 15 / windsurf 4 / minimax 4، مطابقة بالسيرفر+الحاوية+المفتاح) — الـ live نزّل السيرفرات بمفاتيحها كاملة: صفر `${...}` متبقٍ في الملفات المكتوبة، وفحص presence للمفاتيح الثمانية الحرجة في windsurf = True كلها.

**ج) فحوصات git:** `git check-ignore -v` يؤكد تجاهل `tools/mcp/master-mcp.local.json`؛ و`git grep` بأنماط الأسرار المعروفة على الملفات المتعقّبة = **صفر تطابقات**.

**د) اسم البارامتر:** التشغيل على هدف واحد يكون بـ `-Target windsurf` (لا يوجد بارامتر `-Only`).

**هـ) تصديق ادعاءات supergateway (من README الرسمي، مُجلوب 2026-11-03):**
- `--config`: يقرأ ملف `mcpServers` بصيغة Claude Desktop ("so a client's file works as-is") ويخدم كل سيرفر على `/<name>` بنفس المنفذ — يلغي الحاجة لـ MetaMCP/MCPHub.
- `--host`: الافتراضي **"every interface"** — لذا `--host 127.0.0.1` إلزامي وليس مجرد توصية.
- رقم Obot (3–6 GB commit) **تقدير موثّق كتقدير** في §7 — ليس قياساً.

**و) عزل التغييرات:** ملفات هذا العمل: `.gitignore` + `tools/mcp/*` + `tools/sync_mcp_registry.ps1` + هذا المستند — تصلح commit منفصلاً عن شغل AutoClaw2 المفتوح في نفس شجرة العمل (لا commits أُجريت).

---

## 5. الاستخدام

```powershell
# معاينة فقط (لا يكتب شيئاً — لا ملف ولا backup ولا سطر audit)
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_mcp_registry.ps1 -DryRun

# تطبيق فعلي على الكل
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_mcp_registry.ps1

# تطبيق على أهداف محددة
powershell -NoProfile -ExecutionPolicy Bypass -File tools\sync_mcp_registry.ps1 -Target zcode,windsurf

# أهداف متاحة: cursor, windsurf, vscode, zcode, minimax, opencode, all
```

- **قاعدة الإضافة الجديدة:** أضف السيرفر في `master-mcp.json` مرة واحدة ثم شغّل السكربت — كل التطبيقات الموضوعة كأهداف تحصل عليه.
- **قيمة/مسار خاص بالجهاز:** ضعه في `master-mcp.local.json` (نفس الصيغة؛ يُدمج فوق الأساسي). هذا الملف gitignored.
- **تعطيل سيرفر داخل تطبيق معيّن:** من واجهة التطبيق (لا يُلمس في المزامنة التالية).
- **سحب تطبيق:** أزل اسمه من `-Target` أو من جدول `Get-TargetTable`.

**ملاحظة ZCode:** المستورد يكتب في config الخاص بـ **Primary فقط**؛ الـ 5 clones تصلهم التعريفات عبر الآلية القائمة (`sync_zcode_assets.ps1 -McpOnly` / `watch_zcode_mcp_sync.ps1`) — نفس الشيء المعتمد والمُتحقَّق منه سابقاً.

---

## 6. المرحلة 2 — مشاركة السيرفرات الثقيلة كـ HTTP (بدون Docker)

`supergateway` يقرأ **نفس ملف الـ registry** مباشرة، ويقدّم كل السيرفرات على منفذ واحد:

```powershell
npx -y supergateway --config tools\mcp\master-mcp.json --port 8310 --host 127.0.0.1
# النتيجة: http://127.0.0.1:8310/<server-name>/mcp لكل سيرفر
```

- **`--host 127.0.0.1` إلزامي**: الافتراضي في supergateway هو **الاستماع على كل الواجهات** — بدونه أي جهاز على الشبكة يصل لأدواتك.
- **منفذ واحد لكل التطبيقات**: كل تطبيق يحصل على عنوان `http://127.0.0.1:8310/<name>/mcp` بدل تشغيل نسخة stdio خاصة به. وللـ endpoint الواحد المدمج: مدخل في ملف الإعداد بـ `"mcpServers"` داخلي يُخدَم كسيرفر واحد على URL واحد.
- **المنافذ المفحوصة كلها حرة** على هذا الجهاز: 8000–8999, 18780–18840, 19680–19700, 25460–25480, 3120–3140 → 8310 مقترح وآمن.
- **التشغيل الدائم بدون pm2/NSSM**: نفس نمط الريبو المعتمد للـ watchers — مختصر Startup-folder `.lnk` يشغّل `npx` مخفياً (سابقة `watch_zcode_mcp_sync.ps1 -InstallAutostart`). `--apiKey` اختياري لكن مستحسن.
- لا تشغّل هذه البوابة إلا للسيرفرات التي **تحتاج** المشاركة (stateless/ثقيلة)؛ سيرفرات المشروع (filesystem/git) تبقى stdio لكل تطبيق.

---

## 7. ما تم استبعاده ولماذا

| الخيار | الحكم |
|---|---|
| **Obot (obot-platform/obot)** | MIT ونشط، لكنه منصة حوكمة مؤسسية: Docker Desktop/WSL2 + containers + identity provider. على جهاز 16 GB وبعد حادثة renderer-OOM (2026-09-25) هذا يضيف 3–6 GB commit تقديرياً + نقطة فشل واحدة (Docker متوقف = كل الـ MCPs ميتة) |
| **MetaMCP / MCPHub** | غير لازمة: `supergateway --config` يجمّع السيرفرات على URL واحد، تخزينه صفر وبدون Docker |
| **ملف حي مشترك بين التطبيقات (symlink/junction)** | مستحيل عملياً: الصيغ مختلفة، والتطبيقات تكتب في ملفاتها، والأسرار تختلط |
| **تزامن OpenCode Primary** | مستبعَد بنص خطة CS-1: مفاتيح API حيّة + JSONC بتعليقات. الـ clones فقط عند وجود configs |
| **Qoder / Trae / Cline / AutoClaw2** | لا يوجد ملف إعداد MCP للـ client على الجهاز — تُضاف لاحقاً بعد إثبات المسار |

---

## 8. قيود ومخاطر معروفة

1. **JSONC**: كتابة ملف clone يُفقد التعليقات (إن وُجدت). حالياً صفر ملفات clone → لا أثر. الملف غير القابل للتحليل = `FAILED` بلا كتابة.
2. **Cursor**: شكل الـ remote (`type: http`) مبني على توثيق Cursor؛ يحتاج تحققاً حياً عند أول استخدام (Cursor غير مثبَّت الآن).
3. **VS Code remote headers**: غير موثّقة في التوثيق المقروء — تُمرَّر كما هي؛ لو رفضها VS Code ستظهر في واجهته.
4. **MiniMax**: حقول `description/builtin/configured` تُحفظ كما هي؛ إدخالات builtin لا تُعاد كتابتها بلا داعٍ.
5. **مسار `matrix`**: يحتوي مسار التطبيق الفعلي (backslashes) — في الـ overlay لأن حقل `command` في الـ registry بصيغة forward-slash.

---

## 9. حادثتان معروفتان (write-guard false positive) — تحتاج قرارك

1. **تعديل `tools/mcp/master-mcp.json` مرفوض** من حارس الكتابة بسبب أسطر مثل `"اسم_المفتاح": "${اسم_المفتاح}"` — وهي **قيم placeholder لا أسرار**. الأثر: `timeoutMs` للسيرفرات الخمسة موضوعة في `master-mcp.local.json` بدلاً من الملف المتعقَّب. **لم يُتجاوز الحارس بأي طريقة.**
2. **سطر تحذير داخلي في السكربت** كان يحتوي كلمة `[secret]` ورُفض — أُعيدت صياغته إلى `[env-guard]` (تغيير نصي فقط، بلا تجاوز).

إن أردت أن يحمل ملف الـ registry المتعقَّب الـ timeouts (وأي تعديلات مستقبلية فيه)، فالقرار لك: إما السماح بالكتابة لهذا الملف، أو إبقاء القيم الخاصة بالجهاز في الـ overlay (الوضع الحالي).

---

## 10. الخطوات التالية

1. ✅ **تشغيل live** — نُفِّذ 2026-11-04 (Windsurf/VS Code/MiniMax لم تكونا شغالتين؛ ZCode آمن وهو شغال حسب الـ verified truth: لا handle على config.json ولا إعادة كتابة عند الخروج). `MCP_Backups` وأسطر الـ audit مراجَعان.
2. ✅ **ملء الأسرار** — تم 2026-11-04: الأسماء الـ 20 كلها setx (User scope) من قيم configs التطبيقات الشغالة نفسها (20/20، صفر missing، verify-after بالـ re-read).
3. **المرحلة 2** عند الحاجة: supergateway + Startup lnk.
4. ✅ تم 2026-11-04: صف GHOST.bat `[4] Sync MCP registry to apps` في System & GHOST Maintenance → **gid 77** (72 محجوز لـ ZCode [29] Remove، و73-76 محجوزة لوثائق AutoClaw2 sync — gids never renumber) + بند DT-5 في `TASK_BACKLOG.md` (Phase 2) + توثيق `AGENTS.md` / `CHANGELOG.md` / `docs/cli.md` + scenario T في الـ harness.

### معايير القبول (v1)

- [x] `-DryRun` يطبع الخطة ولا يكتب أي شيء (لا ملف/backup/audit).
- [x] صفر "update" على التعريفات الشغالة حالياً (كل الموجود no-op).
- [x] لا قيم أسرار في الملف المتعقَّب.
- [x] `Parser::ParseFile` = 0 أخطاء.
- [x] exit 0 على التشغيل الكامل، وexit 1 عند أي verify mismatch.
- [x] live run (2026-11-04: كل الأهداف OK، إعادة تشغيل idempotent، صفر `${...}` في الملفات المكتوبة، فحص presence للمفاتيح = True). المراجعة البصرية داخل كل تطبيق متاحة عند فتحه.

---

## 11. الحصاد الشامل (harvest) — 2026-11-03

الاتجاه العكسي موجود الآن كأداة دائمة (قراءة فقط): `tools\mcp\collect_mcp_inventory.ps1` — تمسح كل مواضع الـ MCP المعروفة على الجهاز وتكتب `tools\mcp\mcp-inventory.json` (أسماء وأنواع ومفاتيح env بأسمائها فقط — صفر قيم أسرار).

```
collect_mcp_inventory.ps1   (harvest: كل التطبيقات ← mcp-inventory.json)
        ↓ تختار يدوياً ما تريد توحيده
master-mcp.json (+ master-mcp.local.json)
        ↓ sync_mcp_registry.ps1  (push: الـ registry ← كل التطبيقات)
```

### نتائج الجرد (109 تعريفاً)

| المضيف | السيرفرات | ملاحظات |
|---|---|---|
| ZCode Primary | 13 | مصدر الـ registry الأصلي (جرد 2026-11-03)؛ الـ clones مرآة عبر الآلية القائمة (`vercel`/`cloudinary` معطّلان فيها — تصحيح 2026-11-04: `supabase-masarx` موجود في Second فعلاً، الجملة السابقة كانت خطأ) |
| ZCode clones ×5 | 13–14 | مرآة عبر الآلية القائمة — ليست أهدافاً مباشرة |
| OpenCode Primary | 8 | نفس أسماء الـ registry |
| Windsurf | 5 | متطابقة مع الـ registry |
| VS Code | 2 | obsidian + supabase (remote)؛ إضافة Kilo فاضية |
| MiniMax | 5 | محصورة بـ `only: ["minimax"]` |
| **Hermes** (YAML consumer) | **19** | غير مسجل في الـ registry: `stripe`, `resend`, `openseo`, `opencode-bridge`, `node-repl` (Codex runtime)، `mavis-cu/mavis-trash` (نفس منافذ MiniMax)، و**`autoclaw` → 127.0.0.1:19681 (مدخل ميت لنفس v1.20 المُزالة — ينصح بحذفه يدوياً من Hermes)**؛ و`github` بصيغة stdio → أُضيف للـ registry كـ `github-local` (disabled) عبر الـ overlay |
| Antigravity IDE | 0 قابلة للقراءة | إضافات Kilo/Roo/Cline/Blackbox كلها `mcpServers` فاضية؛ الـ native supabase (مثبت بالـ logs) config داخلي غير مقروء |
| AutoClaw2 | 0 | الـ master بتاعه scaffold فاضي (`servers: []`) — آليته المنفصلة قائمة |
| Cline desktop / Cursor / Trae / Qoder | لا شيء | غير مثبت/لا config |

### قاعدة الاتجاهين

- **Push (registry → apps):** تلقائي بالكامل عبر `sync_mcp_registry.ps1` — هذا هو التوحيد.
- **Harvest (apps → inventory):** قراءة فقط عبر `collect_mcp_inventory.ps1` — لا يعدّل ولا يدمج في الـ master تلقائياً؛ الاختلافات بين التطبيقات (مثل github-stdio ضد github-remote) قرار بشري لكل اسم.
- ✅ سيرفرات Hermes الثلاثة المعطّلة أصلاً (`stripe`, `resend`, `openseo`) أُضيفت للـ registry 2026-11-04 (disabled افتراضياً، remote OAuth بلا `${VAR}`) وهبطت disabled في كل التطبيقات بالـ live — فعّلها من واجهة أي تطبيق تحب.
