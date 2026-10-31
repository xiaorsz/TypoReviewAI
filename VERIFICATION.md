# GitHub 同步检查：2026-10-31

- 本次同步包括读音／音节记忆、单词页展示稳定与仅预备下一词，以及相关测试和交接说明；工程版本号仍为 0.4.5 (18)，这些新增功能尚未上传 TestFlight。
- 推送前 `swift test --scratch-path .build/GitHubPreflight` 的 60 项核心测试通过，日志 `.build/github-preflight-20261031.log`。原 App 158 个基线文件与容器隔离检查通过，`git diff --check` 通过；本次差异未检出疑似 API Token 或私钥。
- 推送目标为独立仓库 `xiaorsz/TypoReviewAI` 的 `main`；实际提交号与远端状态以 `git log` 和 `git status -sb` 为准。下方“未推送”记载指各功能完成当时的状态。

---

# 本地更新：单词页进入稳定与只预备下一词（尚未发布）

验证日期：2026-10-31。最近 TestFlight 发布仍为 0.4.5 (18)，未变更工程版本号。

- 单词页原先从未初始化／第 1 词／讲解页开始渲染，再由两个异步任务恢复实际词语和作答状态；新词在任务开始前还可能短暂进入失败提示，按词索引驱动的整页动画也会造成旧内容淡出叠影。现在通过 `WordStudyPresentation` 在展示前确定位置、页面和基础模式，切词时同步切换输入及页面；准备结束后才显示失败提示，取消整页切词动画，全屏背景与学习页一致。
- 当前词先生成并显示，后台仅预备紧接着的一个未跳过词；进入下一词后再预备其下一词。已保存的讲解不重生成；基础模式不调用 AI 预备。后台任务不使用前台 `isGenerating`，当前作答仍可操作；提前进入正在准备的词时等待同一请求。
- 后台响应从最新状态合并，保留等待期间提交的作答；失败按词记录，当前词继续可用，不自动循环重试。取消、退出／后台、恢复备份、授权变化和原判定变化阻止迟到写入。未新增正式成绩、SwiftData 模型或云端字段。
- `.build/next-word-core.log`：60 项核心测试通过。`.build/next-word-phone.log`：29 项原生测试通过（23 项补练集成、6 项朗读），包含首屏位置状态及 4 项下一词预备测试，覆盖只预备一词、前台作答不受阻及结果合并、进入下一词复用请求、失败显式重试，以及取消／撤授权／恢复／来源撤销。
- 最终 `.build/next-word-phone.log` 返回 `TEST SUCCEEDED`：3 项手机 UI 流程通过，覆盖返回讲解／草稿／只读结果／退出续学、朗读暂停继续和进入作答停止，以及五词后继续剩余两词。最终截图位于 `artifacts/next-word-phone/`，已检查记忆便签、作答隐藏和返回布局；检查了隔离流程的切换录屏。`verify_isolation.py` 确认原 App 的 158 个文件不变，`git diff --check` 通过。

边界：请求使用模拟模型，UI 使用隔离示例；没有读取真实 Key、消费 AI 额度或测量真实接口等待时间。下一词准备未完成时仍需等待，不能承诺切词始终无等待。没有上传 TestFlight 或推送 GitHub。

---

# 本地新增：读音与音节记忆（尚未发布）

验证日期：2026-10-31。最近 TestFlight 发布仍为 0.4.5 (18)，本次只修改独立 AI 实验版，工程版本号未变。

- 在现有“组成与记忆”便签内加入“按读音记”，帮助孩子联系声音与写法；中文可结合带声调拼音、字义／字形，英文可结合可靠的音节、重音和对应拼写。提示词要求具体方法，不机械拆分、不把构词记忆块当音节、不使用中文谐音替代英语发音，不确定时省略。
- 随每词原有单次模型请求生成；新增可选 `pronunciation`、`soundMemory` 字段及长度／类型校验，保存在原本机讲解 JSON 中。旧响应和旧记录缺字段仍可读取，不自动重新生成；基础讲解不编造提示。后续练法上下文保留用过的读音记忆方法。
- 学习讲解、作答结果与学习记录详情共用记忆便签；作答页隐藏整段记忆提示。朗读实现、正式成绩、积分、调度与云端模型未改。
- `.build/sound-memory-core.log`：60 项核心测试通过，新增 3 项覆盖中文／英文记忆内容及作答后保存恢复、旧讲解兼容与基础模式、缺省／空值及超长或错误类型拦截。英文测试样本按美式读音标注，参考 [Dictionary.com banana](https://www.dictionary.com/browse/banana)。
- `.build/sound-memory-ipad.log` 返回 `TEST SUCCEEDED`：18 项词语学习原生集成、6 项朗读测试及 2 项 UI 流程通过，覆盖记忆提示在便签内显示、作答隐藏、返回保留输入、只读结果、退出续学与朗读暂停继续。截图位于 `artifacts/sound-memory-ipad/`，已检查记忆提示和原组成说明处在同一便签内，排版无截断。最终仅补充练法上下文保存后，核心测试再次通过，手机复核另见下条。

- `.build/sound-memory-phone.log` 返回 `TEST SUCCEEDED`：最终代码的相同 24 项原生测试及 2 项手机 UI 流程通过。截图位于 `artifacts/sound-memory-phone/`，已检查便签换行、底部作答按钮和答题时隐藏记忆提示。`python3 tools/verify_isolation.py` 确认原 App 的 158 个文件不变、仅声明实验版自己的容器；`git diff --check` 通过。

边界：生成链路使用模拟模型，UI 使用隔离示例，没有读取真实 Key 或消费 AI 额度；未验证真实模型解释质量或学习效果。没有上传 TestFlight 或推送 GitHub。

---

# 当前版本：词语学习页面精简与朗读稳定 0.4.5 (18)

验证日期：2026-10-30。仅修改 AI 实验版；0.4.5 (18) 已完成 Release 归档、上传及 Apple 处理，CoachLab 现有内部测试组显示“正在测试”，可在手机更新。

- 修复开始／停止朗读时向 ScrollView 插入／移除状态栏引起的内容位移。状态与进度合并在同一行，空闲不显示额外提示，播放状态与错误在原位更新；作答页不显示朗读状态。
- 词语、例句、中文翻译的听读／暂停／继续使用图标按钮，根据三种图标的最大自然尺寸布局，至少 44 点触控区域，保持宽高稳定并适配动态字体。
- 状态标识仅挂在文字上，停止按钮保留独立辅助功能标识；空闲时隐藏停止按钮但保留尺寸，不能点击或被辅助功能读出。
- 新增 `testLessonSpeechKeepsContentAndButtonFramesStable`，比较开始、暂停、继续前后的例句按钮 x/y/宽/高，以及停止前后的词语按钮位置。停止检查前先暂停语音，避免滚动期间自然播放结束与测试竞争。
- 修复前 `.build/word-speech-layout-before.log` 确认该回归测试失败，复现朗读引起的位置变化。
- 最终 `.build/word-speech-layout-phone-final.log`、`.build/word-speech-layout-ipad.log` 均返回 `TEST SUCCEEDED`：手机、平板各 2 项 UI 测试通过，包含布局稳定及进入答题停止、返回和退出。测试使用隔离示例，不调用真实 AI。截图位于 `artifacts/word-speech-layout-phone/`、`artifacts/word-speech-layout-ipad/`。
- 手机测试通过后 Xcode 卡在诊断收集，仅终止该 diagnose 子进程后正常生成报告并以 0 退出，没有跳过断言。早期 `.build/word-speech-layout-phone.log` 是中间失败记录，不作为最终通过证据。
- `verify_isolation.py` 确认原 App 的 158 个基线文件未变；`git diff --check` 通过。没有修改朗读内容、AI 请求、正式学习数据、调度、数据库或云端结构，未推送 GitHub；TestFlight 发布状态见下方发布证据。
- 按用户要求完成三处精简：顶部进度与状态合为一行、减少页面上边距；词语／例句旁使用小喇叭；词义更醒目，组成／记忆提示与例句形成清晰层级。根据用户对暂停位置的反馈，例句播放／暂停放到句子正文右上侧，单词控件紧贴单词。原有系统配色、底部作答、返回与续学流程保留。
- 最终视觉调整验证：`.build/word-compact-045-reading-final.log` 与 `.build/word-compact-045-ipad-reading-final.log` 的完整学习流程通过；`.build/word-compact-045-phone-verified.log` 和 `.build/word-compact-045-ipad-dark-large.log` 中的朗读交互及布局稳定两项均通过。手机浅色、平板深色且 accessibility-large 字号的截图已检查，平板恢复原浅色及 large 字号。
- 截图位于 `artifacts/word-compact-045-reading-final/`、`artifacts/word-compact-045-phone-verified/`、`artifacts/word-compact-045-ipad-dark-large/`。位置断言按实际字形边界检查正文右侧、第一行及不遮挡文字，避免将段落的换行留白误判为控件错位；44 点尺寸检查允许坐标浮点误差。早期多项测试日志包含中间失败，不作为整套通过证据。
- 本轮平板完整流程通过后，Xcode 诊断收集阻塞；仅结束 diagnose 子进程后正常生成结果并以 0 退出，没有停止测试进程。最终流程截图另存于 `artifacts/word-compact-045-ipad-reading-final/`。
- 本轮没有改 AI 请求、选题、存储或正式成绩逻辑，0.4.5 (18) 已发布至 TestFlight。
- 发布证据：`.build/testflight-045-18.log` 包含 `ARCHIVE SUCCEEDED`、`Upload succeeded` 和 `EXPORT SUCCEEDED`。实际归档及后台版本均为 0.4.5 (18)，应用标识 `cc.xiaorsz.dictation-coach-lab`、团队 `FCAW792CJD`、独立 iCloud 容器与 Production 环境核对通过。现有内部“测试组”已自动加入构建并显示“正在测试”；收据 `tools/releases/testflight-2026-10-30-0.4.5-18.json`，截图 `artifacts/testflight/0.4.5-18-testing.png`。未编辑测试说明、创建群组、上传原 App 或推送 GitHub。

- GitHub 同步前复核：`swift test --scratch-path .build/GitHubPreflight` 的 57 项核心测试通过，日志 `.build/github-preflight-tests.log`；待发布差异未检出疑似 API Token 或私钥，构建产物、运行数据和签名资料由 `.gitignore` 排除。独立仓库原分支与 `origin/main` 一致，不覆盖远端提交。

---

# 历史版本：词语与例句朗读 0.4.4 (17)

验证日期：2026-10-30。仅修改 AI 实验版；0.4.4 (17) 已完成 Release 归档、上传及 Apple 处理，独立 CoachLab 应用的现有内部测试组状态为“正在测试”，可在手机更新。

- 学习页与学习记录详情新增独立的词语／单词、例句、中文翻译朗读按钮，使用既有系统语音选择与音频会话，按科目选择中文／英语。英文单词不追加词典释义。无新增 API 调用、麦克风权限、云端模型或成绩变更。
- 同一按钮可暂停与继续；切换片段停止旧语音，不排队叠加。离开页面、切换词语、进入作答、后台与音频中断均停止，作答页不保留答案朗读入口。
- 语音完成／取消回调回到主线程，并按 utterance 对象校验，忽略切换后的迟到回调；空内容、缺少语音、暂停失败明确回到可重试状态。
- 新增 6 项原生测试，覆盖中英语音与原文、暂停继续、切换与迟到回调、停止释放、空内容／不可用语音及暂停失败。
- `.build/word-speech-044-phone-confirmed.log` 返回 `TEST SUCCEEDED`：6 项原生语音测试及 2 项手机 UI 测试通过，覆盖朗读切换、暂停继续、作答停止，以及返回讲解、输入保留、只读结果和学习记录。测试使用隔离示例，不调用实际 AI；截图位于 `artifacts/word-speech-044-phone/`。
- `python3 tools/verify_isolation.py` 确认原 App 158 个文件保持不变、仅实验版 iCloud 容器，`git diff --check` 通过。
- 发布证据：`.build/testflight-044-17.log` 包含 `ARCHIVE SUCCEEDED`、`Upload succeeded` 和 `EXPORT SUCCEEDED`。实际归档为 0.4.4 (17)，应用标识 `cc.xiaorsz.dictation-coach-lab`、团队 `FCAW792CJD`，iCloud 容器为实验版独立容器，环境 Production。App Store Connect 现有内部测试组已自动加入该构建并显示“正在测试”；收据 `tools/releases/testflight-2026-10-30-0.4.4-17.json`，截图 `artifacts/testflight/0.4.4-17-testing.png`。未修改测试说明、创建群组、上传原 App 或推送 GitHub。
- 初轮平板 UI 测试发现例句按钮宽屏点击区域不正确，改为明确标签尺寸和矩形点击区域后，`.build/word-speech-044-ipad-hitarea.log` 返回 `TEST SUCCEEDED`，验证词语→例句切换、暂停、继续和进入答题停止。截图位于 `artifacts/word-speech-044-ipad/`，已检查排版。测试通过后 Xcode 诊断收集阻塞，停止其 diagnose 子进程后正常生成结果，不跳过断言。
- `.build/word-speech-044-ipad-final.log` 的 6 项原生语音测试通过；该轮 UI 点击失败已由上述最终测试修复。

---

# 历史版本：词语学习返回与界面统一 0.4.3 (16)

验证日期：2026-10-30。只修改 AI 实验版；0.4.3 (16) 已完成 Release 归档、上传及 Apple 处理，独立 CoachLab 应用的现有内部测试组状态为“正在测试”，可在手机更新。

- 学习页新增左上角返回按钮，右上角单独退出。作答返回当前讲解，结果页可回看讲解，后续词可回到前面已准备的词；首词讲解返回词语列表。全屏展示由入口绑定统一关闭。
- 当前小组内保留未提交的输入；已提交答案只读回看，不重新作答或增加判定。作答后回看讲解再提交会标记已回看。退出后继续首个未完成词，不重复建组。
- 学习记录使用明确的导航状态，整行含留白均可点击，修复平板上点击行中间不响应的问题。
- 词语模块的入口、学习与记录页面统一使用首页的 systemGroupedBackground／secondarySystemGroupedBackground，以及应用主色、主次文字和分隔线颜色；移除单独的米色／墨绿背景方案，保留书签角色、便签层次和底部操作。
- 没有修改正式成绩、题量、积分、调度、存储模型或云端结构。原 App 158 个文件哈希保持不变。

## 验证证据

- 配色统一后，`.build/word-style-unified-build.log` 构建通过；`.build/word-style-unified-phone.log` 和 `.build/word-style-unified-ipad-dark.log` 均返回 `TEST EXECUTE SUCCEEDED`，复核了讲解、作答、返回、退出续学和记录入口。浅色手机与深色平板截图已检查，保存在 `artifacts/word-style-unified-phone/` 和 `artifacts/word-style-unified-ipad-dark/`；平板已恢复原浅色设置。
- `.build/word-back-043-phone-verified.log`：手机返回讲解、输入保留、已答词只读回看、退出续学和返回列表通过。
- `.build/word-back-043-ipad-hitarea.log`：平板同一完整流程及返回后的学习记录入口通过；整行留白可点击。
- `.build/word-back-043-phone-group.log`：最终构建完成五词后继续剩余两词、结束退出并查看记录通过，返回 `TEST EXECUTE SUCCEEDED`。测试结束后的模拟器诊断收集卡住，停止了该诊断子进程，Xcode 正常以 0 退出；没有终止测试进程或跳过断言。
- 构建日志为 `.build/word-back-043-hitarea-build.log`；截图位于 `artifacts/word-back-043-phone/` 与 `artifacts/word-back-043-ipad/`，已检查左上返回、右上退出及只读结果入口。
- 初轮平板测试暴露出记录行留白没有点击响应；修正整行点击区域后复测通过。测试使用隔离示例，不消费 API，不操作真实学习数据。`verify_isolation.py` 与 `git diff --check` 通过，已上传独立实验版 0.4.3 (16)，未推送 GitHub。

- 发布证据：`.build/testflight-043-16.log` 包含 `ARCHIVE SUCCEEDED`、`Upload succeeded`、`EXPORT SUCCEEDED`。实际归档核对了版本、独立应用标识与 Production iCloud 容器；构建已自动加入现有内部测试组，组内状态为“正在测试”。收据见 `tools/releases/testflight-2026-10-30-0.4.3-16.json`，截图见 `artifacts/testflight/0.4.3-16-testing.png`。未创建测试组、编辑测试说明或操作原 App 的发布配置。

---

# 历史版本：词语小课堂 UI 0.4.2 (15)

验证日期：2026-10-30。仅修改 AI 实验版；0.4.2 (15) 已完成 Release 归档、上传及 Apple 处理，独立 CoachLab 应用的现有内部测试组状态为“正在测试”，可在手机更新。

## 界面调整

- 入口、讲解、作答、反馈、完成及学习记录改用纸张与墨绿视觉；减少系统列表与表单排版，增加可伸缩的书签角色、轻微错落的词语标签和便签式结构说明。角色以 SwiftUI 绘制，无新增图片或外部服务。
- 讲解改为全屏阅读，词义、结构、例句使用不同层次。主要作答、下一词及再学一组操作固定于底部，键盘弹出后提交仍可点击。
- 支持深色、动态字体、标签换行及减少动态效果；原生导航与辅助功能名称保留。每组五词、自动判定、续学、去重、隔日验证及本地存储模型保持不变。

## 验证

- `.build/word-classroom-042-phone.log`：完整讲解、输入错误反馈及五词后继续剩余两词的两个 UI 流程通过，`TEST EXECUTE SUCCEEDED`。
- `.build/word-classroom-042-ipad.log`：深色模式、放大至 extra-extra-extra-large 的平板完整讲解与键盘作答通过；测试后恢复模拟器原来的 light / large 设置。
- 书签笑脸微调后，`.build/word-classroom-042-final.log` 再次构建并跑通完整手机流程，`TEST SUCCEEDED`。截图位于 `artifacts/word-classroom-042-final/` 及 `artifacts/word-classroom-042-ipad/`，已检查长讲解、词语换行、深色对比与键盘布局。
- 丰富讲解截图使用 DEBUG 且同时带三个 UI 测试参数才启用的固定示例；只写入测试临时元数据，不使用真实 Key 或 API，不向真实学习库加入示例。Release 不包含此测试入口。
- 原 App 158 个文件哈希不变，`git diff --check` 通过。已上传实验版 0.4.2 (15)，本轮未推送 GitHub，没有变更数据库或云端结构。

- 发布证据：`.build/testflight-042-15.log` 包含 `ARCHIVE SUCCEEDED`、`Upload succeeded` 和 `EXPORT SUCCEEDED`。实际归档核对了 0.4.2 (15)、独立应用标识和自己的 Production iCloud 容器；已自动分发到现有内部组。收据见 `tools/releases/testflight-2026-10-30-0.4.2-15.json`，状态截图见 `artifacts/testflight/0.4.2-15-testing.png`。未创建新测试组或编辑测试说明，未操作原 App 的发布配置或 App Store Connect 应用。

---

# 历史版本：AI 词语讲解 0.4.1 (14)

验证日期：2026-10-30。只修改独立 AI 实验版；0.4.1 (14) 已完成独立应用的 Release 归档、上传及 Apple 处理，内部测试组状态为“正在测试”。

## 已实现

- 首页移除独立的“AI 复习安排／规则复习安排”卡片及首页专用展示代码，只自然收拢间距，其他模块顺序不变。复习与预习入口保持原位置；AI 词语讲解、设置中的每日安排与执行记录继续保留。
- 入口改为“AI 词语讲解”，每组最多 5 个重点词；学完可直接再推荐 5 个，不足时按实际数量展示，无更多新词时明确提示。同日去重，有未完成组优先继续。
- 孩子独立查看词义、结构／拼写说明和例句，再进入隐藏讲解的屏幕输入页；一词一道题、自动判定，不再需要家长逐组核题或判定。英语例句附中文意思，保留大小写判定。不确定结构时允许省略，避免强行拆词。
- 逐词按需生成，每词一次请求；失败可重试、停止、跳过或明确改用题库／词典基础讲解。已保存讲解不重复请求，组进度及基础模式选择跨重启保存。
- 新学习组与讲解沿用独立本机 JSON，v2 兼容 v1 旧补练，日期精度不变。旧纸上补练只在历史查看，不阻塞新屏幕学习。来源校验、授权撤回、取消与恢复备份仍受保护；新作答不写正式成绩、积分、阶段或每日计划。
- 推荐结果缓存供界面读取，历史分析在页面打开后执行；详情保留真实后续验证。没有新增云端模型。

## 验证证据

- 首页卡片移除后的专项界面验证：`.build/home-remove-plan-phone-final.log` 返回 `TEST SUCCEEDED`，`.build/home-remove-plan-ipad.log` 返回 `TEST EXECUTE SUCCEEDED`。覆盖首页无独立安排卡及详情按钮、五词讲解入口、七题预习与正式复习、设置中的每日安排及执行记录、自动同步诊断；未提交判定，正式记录仍为 21 条。手机首轮因执行记录按钮在屏幕外而中断，补足测试滚动定位后完整通过，无额外产品逻辑改动。手机和平板首页截图已检查，模块顺序保持不变且无空白占位。
- `.build/word-lessons-phone.log`：57 项核心、174 项原生回归、5 项手机 UI 测试全部通过。新 UI 实际跑完首组 5 个与剩余 2 个，逐词输入自动反馈、验证答案隐藏和空输入禁用、完成后继续下一组，并查看后续记录。
- 最终加入基础模式持久化与推荐缓存后，构建返回 `TEST BUILD SUCCEEDED`；57 项核心、18 项补练原生及手机完整流程复核通过，iPad 同一完整流程也通过，均返回 `TEST EXECUTE SUCCEEDED`。证据见 `.build/word-lessons-final-build.log`、`.build/word-lessons-final-phone.log`、`.build/word-lessons-final-ipad.log`。
- 使用模拟模型响应验证 AI 讲解链路，界面测试走显式基础讲解，不读取真实 Key、不消费 API。实际模型讲解质量和家庭体验仍待试用，自动格式校验不能验证全部教学语义。
- `python3 tools/verify_isolation.py` 确认原 App 158 个文件不变，只声明实验版自己的容器；`git diff --check` 通过。本轮未推送 GitHub；已上传独立实验版 0.4.1 (14)，未操作原 App 的发布配置或 App Store Connect 应用。

- 发布证据：`.build/testflight-041-14.log` 包含 `ARCHIVE SUCCEEDED`、`Upload succeeded` 和 `EXPORT SUCCEEDED`；实际归档核对了独立 Bundle ID、版本和 Production iCloud 容器。构建已自动分发到现有内部测试组，没有创建新组或修改测试说明。收据见 `tools/releases/testflight-2026-10-30-0.4.1-14.json`，页面截图见 `artifacts/testflight/0.4.1-14-testing.png`。

---

# 历史版本：反复错题—针对性补练—隔日验证 0.4.0 (13)

验证日期：2026-10-30。实现位于独立 AI 实验版，沿用原复习规则；未新增 SwiftData 模型或 CloudKit 字段，未修改原 App。

## 已实现的闭环

- 首页和 AI 教练页均可进入“反复错题与补练”。分析在后台读取当前授权科目的原生快照，采用原生记录的规范化规则；近 30 天至少错误 3 次且跨 2 天，按记录 ID 去重、按内容归并，支持语文字词与英语单词。结论可展开真实日期、模式和对错，不从频率推断具体错因。
- 家长可补充困难和实际错写。单次 AI 请求包含本题与最近记录，不带安排工具；生成 2–3 道写法辨析／语境填空，程序校验题型、标准答案、选项和遮盖，再由家长确认才可开始。模型不可修改原答案、阶段、积分或每日复习计划。失败保留数据，可重试或显式使用非 AI 的本地基础练法。
- 补练单独记录确认时间、逐题作答、是否查看答案及完成时间，可恢复进度。记录使用当前实验版自己的 `targeted-coach.json` 原子保存，日期按 Foundation 原始参考时间编码，保留原生亚秒精度。不得把已看过答案的当次补练成绩作为隔日验证。
- 后续验证只读取补练完成之后、不同日期的正式复习／听写，排除同日、重练、重复 ID 和未来记录。不同两天正确仅提示改善迹象；任一后续错误提示调整，撤销记录后重新计算。正常判定、撤销、同步变化和回前台均会刷新已加载的结果，刷新合并延迟避免频繁扫描。
- 新错误需要下一轮补练时，模型请求包含同一内容最近三轮的练法、练习内成绩及独立验证证据，要求说明沿用或调整理由。待确认、进行中及待验证的补练不重复建组。来源撤销／内容改变、恢复备份、授权变化、取消和退后台会阻止迟到写入；取消向当前网络任务传播。

## 验证证据

- `.build/targeted-040-regression.log`：53 项核心、167 项完整原生回归及 2 项手机 UI 流程通过；覆盖既有每日安排、反馈撤销、设置和新补练数据兼容。
- 在加入上一轮练法上下文与取消任务管理后，`.build/targeted-040-complete.log` 再次通过 53 项核心、11 项补练原生集成及 1 项手机完整补练流程，返回 `TEST SUCCEEDED`。新增覆盖真实来源阈值、答案校验、亚秒日期重启恢复、重复生成、新错误不重复建组、网络失败、撤销、数据集替换、授权撤回、损坏文件保留、取消后重试，以及给模型分别传递练习内成功和后续独立失败证据。
- `.build/targeted-040-ipad.log`：最终 iPad 完整流程通过。UI 使用 DEBUG 双参数启用的内存示例库，实际验证分析入口、家长核对、遮盖作答、补练完成与等待验证，不使用真实学习数据。
- `.build/targeted-040-device-final.log`：Debug 真机目标签名构建 `BUILD SUCCEEDED`；产物核对版本 `0.4.0 (13)`。
- 手机截图位于 `artifacts/targeted-040/`，平板截图位于 `artifacts/targeted-040-ipad/`；已检查实际布局。差异清单为 35 个原样副本、25 个适配副本和 10 个新增 Swift 文件。原 App 158 个文件哈希不变，`git diff --check` 通过。

## 当前边界

- 新补练元数据只在当前设备保存，尚未加入 iCloud 或备份导出；恢复备份会重置关联。原生题库、听写、正式复习及现有同步方式继续保留。
- 使用模拟模型响应验证生成与反馈链路，没有读取真实 Key、消费 API 额度或完成真实家庭学习效果验证。AI 题目的语义质量仍需家长核对和真实试用；两个日期答对不能证明因果或永久掌握。
- 2026-10-30 已通过 Release 归档与上传；App Store Connect 已处理完成 `0.4.0 (13)`，并自动加入现有内部“测试组”，组内构建状态已核对为“正在测试”。发布记录见 `tools/releases/testflight-2026-10-30-0.4.0-13.json`，上传日志见 `.build/testflight-040-13.log`；原 App 158 个文件再次核对不变。没有推送本轮源码到 GitHub，也未代用户在手机安装。
- 额外测试说明的保存被自动审批拒绝，原因是授权范围仅包含上传构建。未发布说明，已放弃未保存草稿；不影响构建上传或既有内部组的安装资格。

---

# 历史版本：首页复习摘要与自动状态检查 0.3.8 (12)

验证日期：2026-10-30。只修改 AI 实验版；数据库模型、已保存题单、判定与云端结构不变。

- 按最新要求，首页完全移除 iCloud 同步卡片及相关按钮；状态查询、诊断和完整错误信息保留在“设置 → iCloud 存储”。CloudKit 默认自动同步，状态检查不是同步开关。
- 修复旧服务器同步任务在未启用时仍排队、取消启动／回前台状态检查的问题；未启用时不创建任务，延迟结束后也先核对启用状态，再进行互斥操作。
- AI 卡片保留题量、前三项预览和简短依据；完整题单按实际顺序显示在独立详情页，关闭后首页不展开。旧依据只作“依据待更新”提醒，提供“检查安排”入口，不替换原题单或编造选题原因。教练页使用相同详情组件。
- 13 项同步／说明语义回归，以及同一完整 UI 流程在 iPhone 17 Pro 和 iPad Pro 13 英寸模拟器上均通过。最终 `.build/home-no-sync-038.log` 返回 `TEST SUCCEEDED`，结果位于 `.build/home-no-sync-038.xcresult`。
- UI 流程验证首页没有同步提示、完整题单只出现在详情、进入 AI 教练和设置中的同步诊断；从未点击检查按钮，也能读到自动检查生成的本地数据统计。最终截图导出至 `artifacts/home-no-sync-038/`。测试使用隔离内存库及 DEBUG 双参数启用的示例题单，不访问真实学习数据。
- 原 App 的 158 个文件哈希一致，`git diff --check` 通过。没有读取真实 Key、付费调用模型、上传 TestFlight 或推送本次修改到 GitHub；用户需要安装新构建才能看到变化。模拟器自动检查回归不能替代真实设备云端上传／下载验收。

---

# 历史版本：复习安排卡片 0.3.7 (11)

验证日期：2026-10-30。只修改实验版的安排展示和生成说明提示词，不变更数据库模型、已保存计划、判定记录或云端结构。

- 首页展示标题、今日待复习数量、实际题单前四项，以及最多两行的依据。详情默认折叠；展开显示完整待复习清单、选题依据和分条记忆提示。教练页同样折叠各日期的长说明，日期、总题量和已开始状态保留。
- 旧版包含题目 ID／分页异常的说明提示“旧安排的依据不完整”，不编造替代依据或继续呈现其中的记忆提示。旧原文和计划存储不改动。正常依据及英语词语／标点保留，提示按分号和换行拆分。
- 生成说明的提示词明确要求依据最多两句，不重复整份题单；提示最多三条。实际模型是否完全遵守仍取决于生成结果，界面摘要始终限制为两行。
- 4 项说明语义回归和 1 项 iPhone UI 流程通过，`.build/plan-card-ui.log` 返回 `TEST SUCCEEDED`。UI 使用隔离测试内容，验证题量、展开题单、旧说明警示和隐藏技术文本；导出截图位于 `artifacts/plan-card-ui/`，已检查实际布局。测试内容仅在 DEBUG 且同时传入两个 UI 测试参数时显示，用户正式运行不会出现。
- 提示词修改后的 45 项核心测试通过，证据 `.build/plan-card-core.log`；未使用真实 API Key 或付费调用。
- Debug 真机目标签名构建通过，`.build/plan-card-device.log` 返回 `BUILD SUCCEEDED`。原 App 158 个文件哈希校验一致，新增展示文件已纳入独立工程。没有上传新的 TestFlight 包，用户需安装新构建才能看到界面变化。

---

# 历史版本：本次错题查询与生产同步诊断 0.3.6 (10)

验证时间：2026-10-29 晚至 10-30 凌晨。仅修改实验版，原应用 158 个文件哈希保持不变。

## 修复与本地验证

- 反馈查询先返回本次错误、再返回其余本次判定；支持 1–100 个 ID 的定向查询。仍严格校验授权、存在性及实际查询资格，失败查询不会扩大可写范围。提示词要求先核实反馈题，不因未读分页改排其他题；依据向家长说明核实的学情与到期原因。
- 新增大题库回归：180 条旧积压、7 个新错、3 个新对，首屏仍包含本次判定，三轮调用可安排本次错题。真实听写排除、总题量和原规则到期限制保留。
- 跨午夜回归发现，虚拟反馈的处理日期可能被误作听写判定日期，导致次日补练被排除。现排除虚拟 feedback／coachReview，用原始复习记录日期判断；真实听写仍按实际判定日期排除。
- 同步直连诊断覆盖 17 类模型及 AI 清单三个字段，分清账户、同步区域和模型写入阶段。不把 zone 访问拒绝直接说成缺 schema，不把账户可用说成同步成功；“推送环境”更名为实际可验证的“编译配置”。错误详情增加必要失败原因并隐藏凭据。RetryAfter 同时兼容 Int／Double、过滤非有限值和负值。
- 最终 **45 项核心 + 151 项原生测试通过，共 196 项，0 失败**，见 `.build/cloud-paging-regression-final.log` 的 `TEST SUCCEEDED`。另有 6 项离线结构生成器测试通过。前两次回归分别发现重试时间解析和跨午夜反馈问题，修复后才计入通过。
- Debug 真机目标签名构建见 `.build/cloud-paging-device.log`；未上传新 TestFlight 包，也未覆盖用户手机上的现有安装。

## 云端检查与结构部署

- 通过用户自行登录的 Apple 官方 CloudKit Console，核对团队和独立容器 `iCloud.cc.xiaorsz.dictation-coach-lab`。Development／Production 均只有系统 Users，没有 17 类应用模型。最近一小时生产日志查询未返回可进一步解释截图错误的事件。缺结构是明确需要修复的配置，不能仅凭 15/2000/1011 判断全部底层原因。
- 从公开 `NSManagedObjectModel.makeManagedObjectModel(for:)` 离线导出准确模型：17 实体、170 属性，全部标量，无关系／加密／转换器。不打开学习数据库或 CKContainer；基于 Apple 官方 Core Data 字段映射生成 `tools/cloud-schema/CoachLab.ckdb`，不是声称来自 printSchema。包含 264 个应用／元数据／溢出字段、102 个系统字段，保留原 Users，合计 18 类。新应用类型不授予公共库权限。
- 原 schema 和输入／产物 SHA256 已保留，生成器遇到不支持的模型会停止；6 项 Python 回归覆盖字段、Users 保留、权限和失败边界。
- 首次上传被自动审批拒绝后未绕过。2026-10-30 用户明确授权上传指定文件到实验版容器、导入开发环境并部署生产；登录会话由用户自行恢复后继续执行。
- **Development 导入及 Production 部署已完成。** 指定文件 SHA256 仍为 `8b8cfe4cdc9b0b620e12f9861dc9f6c86ef10b59dcc73de46f0aaa09158a1e7f`。Apple 导入预览显示 `Validation Passed`，随后显示 `The schema was successfully imported.`。生产差异为新增 17 类和 17 个记录 ID 查询索引，Security Roles (0)，没有删除行，原 Users 保持不变。
- Apple 返回 `Changes Deployed`／`The schema is deployed to Production.`。北京时间 2026-10-30 10:50 前已完成生产读回：18 个类型（17 应用 + Users）均可见，`CD_ReviewDailyPlan` 的 `CD_coachSubjectRawValue`、`CD_coachRationale`、`CD_startedAt` 及相应字符串溢出字段已存在。证据位于 `artifacts/cloud-schema/` 的部署成功截图、生产字段截图、部署差异和字段读回快照；范围回执见 `tools/cloud-schema/deployment-2026-10-30.json`。
- 只改实验容器的结构，无学习记录／Key 上传，无区域／环境重置或记录删除。原 App 容器未操作；部署后原应用 158 个本地文件哈希隔离校验仍通过。此次未打包或上传新的 TestFlight 构建。

参考：[Apple 同步故障排查](https://developer.apple.com/documentation/technotes/tn3164-debugging-the-synchronization-of-nspersistentcloudkitcontainer)、[部署结构](https://developer.apple.com/documentation/cloudkit/deploying-an-icloud-container-s-schema)、[Core Data 字段映射](https://developer.apple.com/documentation/coredata/reading-cloudkit-records-for-core-data)。

边界：没有读取真实 Key 或消费模型额度；尚未完成用户手机的云端重试及双机同步验证。结构部署成功也不能替代真实同步验收。AI 查询和诊断修复在本地 0.3.6 (10)，当前 TestFlight 安装不会自动包含这些源码改动。

---

# 历史版本：新增 AI 流程检查与修复 0.3.5 (9)

验证日期：2026-10-29。仅修改实验版，围绕新增教练的授权、凭据、选题、反馈和撤回进行检查。

## 修复

- 无到期题、已掌握或剩余题量为零时，程序判断无需新增复习并正常完成；反馈会检查明日至未来第 7 天。没有合法候选时不请求模型，有候选时仍不能凭模型文字声称安排完成。反馈继续在原生保存成功后才消费。
- 查询安排仅向模型返回授权科目的题目和结果；完全未授权的安排省略，跨科安排使用通用标题。跨科总题量以匿名每日完成数和剩余额度提供，不附未授权题干、题目 ID 或标题。
- 点击检查会先将当前填写的 Key 保存到本实验版钥匙串，后续自动安排使用同一 Key。教练与小结共用异步 Key 控制器；读取、保存、清空、连接测试互斥，连接测试的迟到结果不恢复旧 Key。失败保留编辑内容并可重试。
- 教练配置只在首次出现时初始化；进入执行记录或听写子页再返回，未保存的科目、题量和授权草稿保留。
- 单科 AI 少选题时，其他科目按原规则补入剩余名额，不再被原规则前一批的题量截断隐藏；不会补回 AI 未选的本科题。已完成复习仍计入总量，当天听写判定内容仍排除。
- 正式复习与统一判卷传入稳定提交 ID 和本次实际保存的记录 ID；跳过或缺失的题不再被当成新错误反馈。已消费的重复通知忽略，无效通知不会堵住后续队列。
- 撤回完成判定会取消在途 AI、移除旧反馈，并撤销本次生成且仍未开始、版本仍匹配的安排；已开始或后来改动的安排保留。模型调用前后用独立 context 核验记录，记录被删或结果变动后不再写入旧学情。

## 验证

- 核心测试 40 项和原生测试 144 项通过，共 **184 项，0 失败**。证据 `.build/ai-audit-regression.log` 返回 `TEST SUCCEEDED`。新增 17 项覆盖无需补练、授权范围、跨科补额、Key 持久化及互斥、反馈去重、撤回改判、在途撤回、删除记录与安排保护。
- Swift Package 核心测试独立通过 40 项，证据 `.build/ai-audit-core.log`。首次编译发现 lazy closure 缺显式捕获，修正后重跑通过；未将失败命令记为成功。
- Debug 真机目标签名构建通过，证据 `.build/ai-audit-device.log` 返回 `BUILD SUCCEEDED`。已读取产物 Info.plist 核对名称、独立 Bundle ID 和 0.3.5 (9)。
- iPhone 三项界面用例分别通过：原有首页／听写／任务／教练入口和设置子页见 `.build/ai-audit-ui.log` 中对应两个通过用例；新增授权草稿往返记录页见 `.build/ai-audit-draft-ui.log`，返回 `TEST SUCCEEDED`。首次整组命令中新增用例点击了 SwiftUI 开关的文字区域，未切换状态；改为点击尾部实际控件并等待状态后重跑通过，不将首次整组命令记为成功。
- iPad 的草稿保留和原有完整界面／教练按钮两项用例通过，`.build/ai-audit-ipad-ui.log` 返回 `TEST SUCCEEDED`。
- 原 App 的 158 个受跟踪文件哈希一致；独立容器、原同步地址及共享钥匙串检查通过。完整副本清单更新为 36 个未改动原 Swift 文件、24 个适配副本及 7 个新增 Swift 文件。
- 对照 [DeepSeek Chat Completions 文档](https://api-docs.deepseek.com/api/create-chat-completion/)核对教练模型标识；现有 `deepseek-flash`、`deepseek-v4-pro` 均受支持。教练已显式关闭 thinking，本轮没有修改模型或接入地址，也未发起真实 API 请求。

边界：没有读取真实 Key 或消费真实 API 额度；未安装用户真机，未在真实家庭样本验证 AI 选题质量或学习效果。撤销版本索引与当前复习页面同生命周期；重启后原界面也不提供旧会话的撤回。既有双机 iCloud 与实际大备份的真机验证边界保持不变。

---

# 历史版本：AI 教练响应与重试修复 0.3.4 (8)

验证日期：2026-10-29。针对设置里进入“AI 家庭复习教练”仍卡顿、点击检查没有反应的问题；仅修改实验版，原 App 的 158 个受跟踪文件哈希一致。

## 修复

- 教练页不在 onAppear 全量读取学习表或重写缓存。Key 读取／保存移到后台，加载期间有进度且暂不可编辑，避免异步读取覆盖刚粘贴的 Key。安排查询仅取最近 8 份未来 AI 清单，执行日志在独立列表按需显示。
- 点击检查会采用当前可见授权和配置；未保存的授权开关不会再导致按钮静默禁用。准备状态立即发布，再用后台 ModelContext 读取不可变值快照，不把 SwiftData 模型跨执行器传递。
- CoachNativeSnapshot 直接映射字段，保留原始 ID、状态与小数日期，删除热路径中的 JSON encode/decode 往返。Codec 的两个日期格式器按 decoder 复用；不再按每个日期重新创建。
- 完整 App 的 LabStore 只将教练元数据、AI 计划和反馈落盘；内存仍保留本次完整查询快照，原生学习数据仍在 SwiftData 中。默认 LabStore 持久化模式保留，先前精简实验版的一次性迁移兼容保留。元数据中的内部计划不作为旧听写录入迁回主库。
- 未授权、缺 Key、教练未就绪、今日已开始锁定均有明确说明。手动检查可绕过当天自动去重标记重新查询；自动触发仍去重，同一计划不会因重查新增副本，已开始清单不覆盖。
- 请求取消／备份替换用 runID 和 datasetID 拦截迟到响应。反馈仅在原生计划保存成功后确认消费；保存失败仍保留重试资格。失效题目引用会清理对应内部计划和每日标记；当日锁定也允许恢复先前已保存的未来安排。

## 验证

- 最终 **132 项原生测试 + 35 项核心测试通过，共 167 项，0 失败**。包括后台字段精度、元数据模式与默认兼容、手动重查、反馈去重、即时 busy、缺 Key 提示、今日锁定提示、取消后马上重试，以及模型选题后原生数据被删除导致保存失败、恢复后仍能重试且仅在成功后消费反馈。
- iPhone 完整界面流程通过，明确检查：进入教练页、等待后台 Key 加载、点击未授权的检查按钮能收到授权提示，听写及任务入口仍可用。证据 `.build/coach-responsive-final.log` 返回 `TEST SUCCEEDED`。
- 后续保存确认修复的最终单元／集成回归见 `.build/coach-responsive-ack-tests.log`，返回 `TEST SUCCEEDED`。
- iPad 初次两次因测试运行器 Busy／预检失败未能运行用例；明确启动本任务的 iPad 模拟器并等待系统就绪后，界面流程通过。证据 `.build/coach-responsive-ipad-final.log`，返回 `TEST SUCCEEDED`；不将前两次失败命令记为成功。
- Debug 真机目标签名构建通过，证据 `.build/coach-responsive-release-check.log` 返回 `BUILD SUCCEEDED`。已读取产物 Info.plist，确认 0.3.4 (8)、名称“听写复习本AI版”和独立 Bundle ID。

边界：模型工具闭环和网络失败使用模拟响应，未读取用户真实 Key 或消费真实 API 额度。尚未在用户真机及其实际大备份上测量帧率和耗时，没有承诺具体加速倍数；原有真实 AI 质量及双机 iCloud 边界继续适用。

---

# 历史版本：听写复习本AI版 0.3.3 (7)

验证日期：2026-10-29。名称改为用户指定的“听写复习本AI版”；Bundle ID、数据路径和独立 iCloud 容器不变，继续升级已有实验版。

- 沿用原 App 橙色折页／勾选图形，由内置 `image_gen` 工具添加右下角白色 `AI` 字样。按用户最新反馈去掉彩色底牌，只保留文字。浅色和深色图标分别编辑，均已缩放封装为不含透明通道的 1024×1024 RGB PNG。
- 生成资源已保存到实验工程 `FullApp/Assets.xcassets/AppIcon.appiconset/`，资产目录引用浅色和深色两个版本；提示词与来源见 `tools/app-icon-design.json`。旧实验版图标移到忽略目录 `artifacts/previous-coachlab-icon.png` 留存。
- 工程和显式 Info.plist 显示名称一致，设置关于栏、备份文件名前缀及存储初始化错误提示同步改名。
- Debug 真机目标签名构建通过，`.build/ai-branding-build.log` 返回 `BUILD SUCCEEDED`。已读取编译后的 Info.plist 核对显示名称、标识、版本及图标注册；证据 `artifacts/ai-branding-verification.json`。
- 原 App 的 158 个受跟踪文件哈希保持一致，没有修改原图标或原名称。此次仅品牌文字及图标资源修改，没有为可逆外观变更新增测试或重复全套功能测试。

边界：没有安装用户真机或发布。新名称与图标需重新运行安装实验版后生效；此前真实 AI 和双机 iCloud 的验证边界仍适用。

---

# 历史版本：隐藏每日计算 0.3.2 (6)

验证日期：2026-10-29。按用户最后修正，任务、今日任务卡片及“待办”入口保留，只隐藏每日计算。

- 首页正常内容及加载态不再创建每日计算卡片，顶部状态区由四项改为任务／复习／听写三项，计算页面不再有首页入口。
- 首页加载不再读取 CalculationRound，展示快照与今日小结输入移除计算统计；本地小结和模型提示不再推荐该训练模块。今日小结缓存更换命名空间，避免旧计算小结继续出现。
- 任务数据加载、任务卡片、日历、待办导航和任务小结继续保留。CalculationRound 仍在 SwiftData 模型和 JSON 备份中，既有计算记录没有清空，存储结构不变。
- 原生回归 **124 项通过**，其中新增 4 项检查任务／复习／听写小结、编码不含计算字段，以及旧缓存失效。iPhone 界面流程通过，覆盖首页滚动后计算卡片和入口不存在、待办仍能打开“任务管理”、听写录入及 AI 教练入口。
- `.build/home-without-calculation.log` 返回 `TEST SUCCEEDED`；`.build/home-without-calculation-device.log` 返回 `BUILD SUCCEEDED`，Debug 真机目标签名构建通过。原 App 的 158 个受跟踪文件哈希一致。

边界：没有更新用户真机或发布 App；需要重新运行安装实验版。没有消费真实模型额度，既有 iCloud 双机实测边界保持不变。

---

# 历史版本：设置页性能修复 0.3.1 (5)

验证日期：2026-10-29。用户反馈为进入设置卡顿、滚动不顺。只修改实验版；原 App 的 158 个受跟踪文件校验一致。

- 设置首页不再在 View 状态初始化与出现时同步读取钥匙串，删除独立版未启用的旧配对码代码。API Key 只在小结子页面后台读取，保存、清空也移出主线程。
- 将晨读和 AI 小结详细控件放入按需打开的子页面，原功能和配置保留。根页面不创建整套晨读时间控件，去除每个设置图标显示前的 UIImage 检查。
- 晨读旧格式单时间段原先每次读取都会产生新 UUID，导致列表行身份不稳定，编辑也可能找不到目标行。现改为稳定的旧格式行 ID；已有自定义时间段 ID 保持不变。
- 设置快照直接由值字段生成；显示与晨读计算用的临时模型按配置复用，配置变化后更新。缓存不写入数据库，不改变设置持久化格式。
- 最终原生回归 **120 项、0 失败**，含 6 项新检查：快照字段、反复读取后编辑、保存／恢复、读取不创建存储行、旧格式 ID 稳定与自定义 ID 保留、准备显示数据的微基准。证据 `.build/settings-regression-final.log`，返回 `TEST SUCCEEDED`。
- iPhone 的原有五入口流程及新增设置进入／滚动／晨读与 AI 子页面导航两项界面测试通过，见 `.build/settings-performance-final.log` 的 UI 测试部分。该次命令整体因一个原生测试未先初始化设置而失败；修正测试初始化后，上述最终原生回归全部通过，不将先前命令整体记为成功。
- iPad 的设置进入／滚动和子页面导航测试通过，见 `.build/settings-ipad.log`，返回 `TEST SUCCEEDED`。Debug 真机目标签名构建通过，见 `.build/settings-device.log`，版本为 0.3.1 (5)。

边界：未在用户的真机上测量卡顿时间或帧率；微基准不是整页速度或真机 FPS 的证据，没有声称具体倍数提升。实际大数据量与 iCloud 同步期间的真机体验仍需验证。此前 AI 复习与独立 iCloud 的验证边界继续适用。

---

# 历史版本：AI 每日复习统筹 0.3.0 (4)

验证日期：2026-10-29。仅修改 `AI教练实验版/`，原应用 158 个受跟踪文件校验保持一致。

- 听写保持独立录入和判定流程。AI 写入目标改为原生 `ReviewDailyPlan`，不再生成听写录入；首页、看板和提交前检查共用 `DailyReviewPlanner`。
- 每日复习使用一个总上限，已完成复习也占用题量；按内容身份去重，当天已听写判定的内容不再复习，但不占用复习题量。复习清单开始后锁定，不会被迟到 AI 响应覆盖。
- 原调度器继续推进阶段和计算到期日，AI 只选择目标日期已到期的题目与顺序。缺 Key、网络错误和无有效 AI 结果时使用已保存清单／原规则；反馈后的安排最早从明天开始。
- 原生测试 **114 项通过**，AI 核心测试 **30 项通过**；共 144 项单元／集成测试，0 失败。覆盖全科共享题量、已完成题占额度、当天听写排除、相同内容不同 ID、AI 少选不自动补题、输入计划不变、开始锁定、迟到响应校验、重复写入、网络／Key 失败及模拟模型三轮工具闭环与次日调整。
- iPhone、iPad 完整界面测试均通过（原有五入口、独立听写录入、AI 复习设置）；Debug 真机目标签名构建通过，仍使用实验版自己的 iCloud 容器和 Development 环境。
- 新的复习清单依据与锁定状态随 SwiftData 存储。旧听写计划、结果和记录保留；升级时停用先前 AI 听写的本机规划关联。AI 授权和 Key 仍为本设备配置。

证据：`.build/daily-review-final.log`（全部测试，`TEST SUCCEEDED`）、`.build/daily-review-ipad.log`（iPad 界面，`TEST SUCCEEDED`）、`.build/daily-review-device.log`（`BUILD SUCCEEDED`）、`artifacts/daily-review-signing.json`（签名权限核对）。首轮新增核心测试存在一个复习／听写记录类型的测试数据错误，已修正并在最终全套回归中通过，不将失败运行记为通过。

边界：模型请求使用模拟响应或模拟断网，没有消费真实 DeepSeek 额度；未宣称真实 AI 选题质量或学习效果已验证。没有安装用户真机、发布或进行双真机 iCloud 合并测试。跨设备离线同时开始的情况仍需实测；本次检查会在同步记录到达后重新核对题量与重复内容。

---

# 历史版本：独立 iCloud 存储 0.2.1 (3)

验证日期：2026-10-29。仅修改实验版目录，原 App 的 158 个受跟踪文件校验保持不变。

- 新 App 使用私有容器 `iCloud.cc.xiaorsz.dictation-coach-lab`，SwiftData 沿用原实验版本机 `coach-full.store`；首次启用前复制主数据库及存在的 WAL／SHM 到本机备份目录。初始化失败时使用同一个本机数据库，并在设置中显示状态。
- 题库、听写、复习、任务、日程、积分及原生设置接入 SwiftData iCloud 同步；新导入媒体优先使用独立 iCloud Documents。既有本机媒体不会自动搬移。AI 授权、Key、日志及规划快照仍保留在本设备。
- Apple 开发描述文件已授权新 App 的独立容器；Debug 真机目标签名构建返回 `BUILD SUCCEEDED`。已核对产物的 CloudKit／CloudDocuments 权限、容器 ID、推送权限及 `Development` 环境，均与描述文件匹配；没有 App Group 或共享钥匙串权限。
- 原生功能回归及新增云存储测试 **101 项全部通过**。新增 5 项覆盖容器和数据库路径、真实数据库备份后保留 ID 和内容、SQLite 附属文件复制、备份失败保护及首次安装。测试配置明确禁用 CloudKit，不向真实云端写入测试数据。
- iPhone 完整界面测试通过；已有 AI 核心 25 项测试结果保留，核心未因本次云配置变更。双真机的真实 Apple ID 同步、离线后合并以及发布环境尚未实测；真机目标签名构建不等于已安装或发布。

本次证据：`.build/icloud-local-tests.log`（101 项回归）、`.build/icloud-tests.log`（含界面测试）、`.build/icloud-signing-final.log`（签名构建）、`artifacts/icloud-signing-verification.json`（权限核对）。差异清单见 `tools/full-copy-manifest.json`。

---

# 历史版本：完整应用副本 0.2.0 (2)

验证日期：2026-10-29。以下为 0.2.0 完整副本的验证记录。

- 原 App 的 60 个 Swift 源文件全部复制到 `FullApp/`：44 个原样保留、16 个仅在副本内适配隔离、离线模式和 AI 接入。另加 3 个 Swift 文件提供独立 Key 与 AI 入口／数据桥接。差异清单见 `tools/full-copy-manifest.json`。
- `FullAppTests` 的 90 项原有功能回归与 6 项 AI／离线集成测试均已通过；AI 核心另有 25 项测试通过，共 121 项单元测试。
- iPhone、iPad 的完整界面流程通过：原有五个主入口、批量创建原生听写计划、进入 AI 教练页面。
- 完整副本的 Release 设备目标无签名构建通过，原有 158 个文件隔离校验通过。
- 集成测试确认 AI 计划真实写入原生 SwiftData、保留关联 ID，已开始的计划不会被覆盖，备份历史不会自动排入新判定队列；本机存储不会显示云同步故障，每日一句可离线显示。
- 某次完整测试在所有用例通过后，Xcode 的结果收尾挂起，已停止该测试进程并针对新增能力重跑，重跑已正常结束并返回 `TEST SUCCEEDED`，日志见 `.build/full-copy-smoke-final.log`。该情况属于本机测试工具收尾问题，不将挂起命令记作正常完成。
- 完整副本的测试日志：`.build/full-copy-final.log`（基础完整回归）、`.build/full-app-release-check.log`（含离线适配的 121 项单元用例与界面用例）、`.build/full-copy-ipad.log`、`.build/full-copy-release.log`。
- 尚未使用真实 DeepSeek 额度，尚未验证用户实际备份、真机并存、真实家庭试用或平台分发。原音视频文件不在 JSON 备份内，需在新 App 重新导入。

---

# 实现验证记录

验证日期：2026-10-29（Asia/Shanghai）。开发环境：Xcode 27.1，模拟器 iOS 26.5；应用部署目标为 iOS 17。

## 已通过

- **核心测试 21 项，0 失败**：本机 Swift Package 与 iPhone 模拟器均通过。包括旧备份兼容、关联校验、原子写盘失败、重复导入、判定去重与重启、基础复习规则、题量与日期权限、四轮调用限制、网络中断后恢复、并发启动、暂停和数据集替换后旧响应拦截。
- **iPhone 界面测试通过**：添加题目 → 手动创建听写 → 开始练习 → 家长判定 → 保存结果 → 设置 → 测试专用 API Key 保存与清除。
- **iPad 界面测试通过**：同一条完整流程，包括平板顶部标签栏与测试专用钥匙串。测试运行器明确支持 iPhone / iPad，使用模拟器本地签名。
- **设备目标构建通过**：Debug 与 Release 无签名构建，用于编译检查；不代表已签名安装或发布。
- **隔离检查通过**：原有 158 个 Git 跟踪文件的 SHA-256 与实施前一致；新 App 运行源码及工程没有原应用的同步地址、共享容器权限或凭据读取逻辑。
- **应用标识确认**：构建产物为 `cc.xiaorsz.dictation-coach-lab`，独立图标为不含透明通道的 1024 × 1024 PNG。

## 验证边界

- AI 多轮查询、计划写入和反馈调整使用可注入的模拟模型响应测试，没有使用原 App 的 Key，也没有消费真实 API 额度。
- 真实 DeepSeek 联网调用需在新 App 中填写独立 Key 后验证；API 余额、实际调用费用和建议质量尚未验证。
- 没有获取或导入用户实际备份；导入测试使用与原备份格式一致的构造数据。
- 没有进行真机安装、两款 App 真机并存对照、iOS 17 运行测试或家庭试用，没有注册新 App、归档或上传 TestFlight。
- 本机 iPad 测试曾遇到运行器预检失败；补齐测试目标的通用设备配置后，最终本地签名测试通过。无签名的模拟器构建不能用于验证钥匙串。

## 本地证据

测试与构建日志位于 `.build/`，模拟器截图位于 `artifacts/`（两者均不进入版本控制）。

| 证据 | 路径 |
|---|---|
| 本机核心测试 | `.build/core-tests.log` |
| iPhone 核心与界面测试 | `.build/iphone-signed.log`、`.build/iphone-signed.xcresult` |
| iPad 最终签名界面测试 | `.build/ipad-signed-universal.log`、`.build/ipad-signed-universal.xcresult` |
| Release 构建 | `.build/release-build.log` |
| iPhone 首页预览 | `artifacts/preview-iphone.png` |
| 原文件校验基线 | `tools/original-files.sha256.json` |

可重新执行 `python3 tools/verify_isolation.py` 检查原文件和配置隔离。该脚本只读，不会还原或改写原应用文件。

## 备份导入兼容修复（2026-10-29）

针对“备份存在无法关联的复习记录或听写条目”的反馈，调整实验版导入策略：缺少父题目的复习记录和缺少父计划的听写条目分别统计并跳过，确认前展示各类跳过数量，有效数据保留原 ID 和关联。不猜测归属，不补造题目或计划，不修改源文件。

修复后本机核心测试 **25 项全部通过**，新增覆盖混合有效与孤立数据、不支持类型与孤立记录分开统计、确认前不写入／源文件不变，以及继续拦截无效对错值。iOS 模拟器目标构建通过；原有 158 个文件的隔离检查再次通过。证据为 `.build/import-fix-tests.log`、`.build/import-fix-build.log`。尚未取得用户实际备份进行逐条核对。
