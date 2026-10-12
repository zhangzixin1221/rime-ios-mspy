# iOS 原生微软双拼 · 仓输入法配置

在 iOS「[仓输入法](https://apps.apple.com/cn/app/id6446617683)」(Hamster) 上，把 **微软双拼键位** 与 **iOS 原生键盘外观** 一起复刻到 [Rime](https://rime.im/) 配置里。

基于 [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) 的百万词库，在其之上做三层改造：**方案层**（双拼键位）→ **词库层**（完整档 + 自建覆盖层）→ **外观行为层**（仓的应用配置）。

> 个人自用项目，非官方，与仓输入法、雾凇拼音的作者均无关。

---

## 当前状态

| 项 | 状态 | 证据 |
| --- | --- | --- |
| **词库完整档** | ✅ 真机跑通 | 中文 1,919,354 条；编译后 `table.bin` 58.23 MB / 全部 `.bin` 72.82 MB，在 iPhone 16 Pro Max 键盘扩展内正常工作 |
| **配置可部署** | ✅ 真机验证 | librime 1.17.0 headless 部署：**0 错误**、无 `.ERROR.` 日志；补丁合并结果逐项核对通过 |
| **微软双拼键位** | ✅ 已自测 | 104 条键位用例全通过；词库 416 个音节 **416/416 可打字** |
| **配置键名正确** | ✅ 已校验 | 32 个键全部对照仓官方默认模板校验通过（含 BGR 颜色格式校验） |
| **外观对齐** | 🟡 大部分完成 | 配色、圆角、阴影、大小写、内嵌组字、候选栏按钮均对齐；**剩回车键颜色与按键标签字号**（见「已知差异」） |

---

## 与 iOS 原生对齐的清单

| 特征 | 做法 |
| --- | --- |
| 键位 | Rime 官方 `double_pinyin_mspy`（微软方案），逐条核对 |
| `ing` 在分号上 | `displaySemicolonButton: true` |
| 无独立拼音条（组字内嵌） | `enableEmbeddedInputMode: true` + 清空 `preedit_format` |
| 按键显示**小写**字母 | `showUppercasedCharacterOnChineseKeyboard: false` |
| 数字键盘为 123 横排（非九宫格） | `enableNineGridOfNumericKeyboard: false` |
| 符号键盘为分页（非分类） | `enableSymbolKeyboard: false` |
| 候选栏不显示序号 / 注释 | `displayIndexOfCandidateWord` / `displayCommentOfCandidateWord: false` |
| 候选栏两端无按钮 | `displayAppIconButton` / `displayKeyboardDismissButton: false` |
| 按键底部阴影 | `enableButtonUnderBorder: true`（仓内置 `standardButtonShadow`） |
| 空格上滑动移动光标 | `swipe/spaceDragSensitivity` |
| 震动反馈、无按键音 | `enableHapticFeedback: true` / `enableKeySounds: false` |
| 深浅色随系统 | `useColorSchemaForLight` / `useColorSchemaForDark` |

---

## 词库构成

**中文主词库 1,919,354 条**（按挂载顺序，上游规则「重复词条时最上面的权重生效」）：

| # | 表 | 条数 | 说明 |
| --- | --- | --- | --- |
| 1 | `cn_dicts/8105` | 8,610 | 《通用规范汉字表》字表 |
| 2 | `cn_dicts/41448` | 46,014 | Unihan 大字表（**上游默认关闭**，本档启用） |
| 3 | `mspy_overrides` | 3 | **自建覆盖层**（审计补词 + 未来调权重的落点） |
| 4 | `cn_dicts/base` | 542,853 | 精校两字词，**带调频** ← 候选排序质量核心 |
| 5 | `cn_dicts/ext` | 339,327 | 扩展词库，含多音字注音 |
| 6 | `cn_dicts/tencent` | 981,936 | 腾讯词向量大词库（无注音，部署时自动注音） |
| 7 | `cn_dicts/others` | 611 | 杂项 |

**其它词表**

| 表 | 条数 | 用途 |
| --- | --- | --- |
| `en_dicts/en` + `en_ext` | 23,819 | 英文输入 |
| `en_dicts/cn_en_mspy.txt` | 1,001 | 中英混输（`USB接口`、`5G流量`…） |
| `custom_phrase_double.txt` | 10 | 自定义短语（替代 iOS「文本替换」） |
| `radical_pinyin.dict.yaml` | 132,367 | 拆字反查 / 辅码 |

**自建覆盖层的内容**（来自一次 114 词覆盖审计，确认全库无词条才补）：

```
其它    qi ta            30000
帐户    zhang hu         15000
向量库  xiang liang ku    8000
```

`其它`/`帐户` 是异形词（rime-ice 按校对标准故意不收），给了较低权重使规范词形优先。

---

## 目录结构

```
.
├── src/                          # 定制源文件（核心，6 个）
│   ├── default.custom.yaml           # 方案裁剪到 1 个（最大内存杠杆）
│   ├── double_pinyin_mspy.custom.yaml# 挂完整档词库 + 预编辑区对齐原生
│   ├── rime_ice_full.dict.yaml       # 完整档词库挂载（含 41448 大字表）
│   ├── mspy_overrides.dict.yaml      # 自建覆盖层
│   ├── hamster.custom.yaml           # 仓应用配置（32 个键）
│   └── custom_phrase_double.txt      # 自定义短语
├── tools/                        # 6 个可复现工具
├── eval/                         # golden set 评测脚手架
├── reference/                    # 权威依据（官方文档 mdx + 上游方案 yaml）
├── dist/                         # 构建产物
│   ├── rime-ios-mspy-full.zip        # ★ 完整档（192 万条）—— 默认交付
│   ├── rime-ios-mspy-lean.zip        # 精简档（去掉 tencent）
│   └── Rime/                         # 解压后的目录（不入库，可重新生成）
├── build.ps1                     # 构建 + 全量校验 + 打包
├── 部署说明.md                    # 部署步骤与排错
├── 键位校验清单.md                # 与 iOS 原生的键位/外观实测对照表
└── 可行性分析与设计方案.md         # 设计依据与平台约束
```

---

## 快速开始

1. 下载 `dist/rime-ios-mspy-full.zip`，传到 iPhone 的**「文件」App**
2. 仓 →「关于」→ **「重置界面设置」**（★ 必做：仓的界面设置优先于配置文件，不重置会导致配置静默不生效）
3. 仓 →「输入方案设置」→ 右上角 `+` →「导入方案」→ 选该 zip
4. 仓 →「RIME」→「重新部署」（完整档约需数分钟，**勿中途退出**）
5. iOS 设置 → 通用 → 键盘 → 键盘 → 仓输入法 → 打开**「允许完全访问」**（自造词需要写权限）

细则与排错见 **[部署说明.md](部署说明.md)**。

---

## 从源码重建

```powershell
# 1. 下载上游词库（约 15.6 MB）
#    https://mirror.nju.edu.cn/github-release/iDvel/rime-ice/LatestRelease/full.zip
#    解压到 upstream/extracted/
# 2. 构建（会跑全部校验并打包）
.\build.ps1                 # 完整档
.\build.ps1 -Tier lean      # 去掉 tencent（省 30 MB）
.\build.ps1 -Tier slim      # 再去掉 ext（省 41 MB）
```

`build.ps1` 会校验：所需文件齐全、词库导入解析得开、补丁键在上游方案中存在、
方案列表已裁剪、YAML 无 Tab、`hamster.custom.yaml` 的 32 个键在官方模板中存在、
配色键名合法、覆盖层拼音可编码、**zip 条目名全为正斜杠**（PowerShell 5.1 的
`Compress-Archive` 会写成反斜杠，导致 iOS 解压时目录结构塌掉）。

---

## 工具

| 工具 | 作用 |
| --- | --- |
| `tools/ConvertTo-Mspy.ps1` | 全拼 → 微软双拼编码转换器，**104 条键位自测** |
| `tools/Verify-SyllableCoverage.ps1` | 校验词库每个音节都能被双拼打出（当前 416/416） |
| `tools/Test-Deploy.ps1` | 用真实 librime 做 headless 部署并核对补丁是否合并生效 |
| `tools/New-GoldenSet.ps1` | 生成 golden set 工作表（自动查拼音、转编码、报覆盖缺口） |
| `tools/Evaluate-Candidates.ps1` | 候选位次评分 + 回归门槛（有退化则非零退出） |
| `tools/mspy_test_cases.tsv` | 104 条键位用例数据 |

---

## 关键设计决策（都是查证后的结论，避免踩坑）

1. **方案列表从 9 个裁到 1 个** —— 完整档 192 万条下，librime 会为每个方案单独构建 prism，9 个方案的棱镜内存不可接受。这是最大的内存杠杆。
2. **词库挂载点必须改两处**（`translator` 与 `radical_reverse_lookup`）—— 只改一处会让 `rime_ice` 与 `rime_ice_full` 同时被编译，内存翻倍。
3. **仓库的内置外观比自建配色更接近 iOS** —— 仓的 `Colors.xcassets` 里 `standardDarkButtonBackground` 浅色是 `#ABB1BA`，与 iOS 实测 `ABB0BA` 只差 1 个 G 值；而一旦启用自定义配色方案，系统键会改用 `...ForColorSchemeBug` 那套（`#B3B7C0`）反而更远。**所以 `enableColorSchema: false` 还原度更高。**
4. **配色方案的颜色格式是 BGR**（`0xAABBGGRR`），不是 RGB。写错会让浅色键盘底色从冷灰蓝变成偏暖粉灰。（注意：仓的**键盘皮肤**是另一套，用 RGB 且透明度在后两位、不写 `0x`。）
5. **圆角/阴影要按像素→点换算** —— 仓文档那张 iOS 参数表是**像素**单位（iPhone X，scale 3），所以「圆角 15、阴影 3」应填 **5 和 1**。
6. **按键显示小写字母** —— 仓模板默认 `true`（大写），而 iPhone 原生是**小写**，需显式改 `false`。
7. **候选栏两端必须无按钮** —— 否则左端图标按钮会压在第一个候选的高亮框上，框会探出输入栏。
8. **`overrideDictFiles: false`** —— 否则每次重新部署都会冲掉键盘侧的自造词（仓官方同步文档第 2 步的要求）。

---

## 已知差异（无法做到"完全一致"）

**需要皮肤才能解决（皮肤路线已尝试并放弃，见下）**

- **回车键颜色**：iOS 的蓝回车键需要皮肤 `returnButtonStyle`（配合 JS `$getReturnKeyType`）实现；`hamster.yaml` 的配色方案里没有对应键。
- **按键标签的字号 / 字重**：`hamster.yaml` 里没有这些键，只能通过皮肤样式或自定义键盘的 `KeyStyle` 设置。
- **未输入时在候选栏显示一行高频词**：工具栏区（未输入时显示什么）完全由皮肤的 `toolbar.primaryButtonStyle` / `secondaryButtonStyle` 控制，`hamster.yaml` 里没有任何键能往工具栏放文字。

> ⚠️ **皮肤路线的尝试记录（失败）**
>
> 曾按官方 `keyboard_skins.mdx` 写出过一份皮肤草稿（中文 26 键 · iPhone 竖屏 · 深浅各一份，
> 含上述三项修复，机器校验 95 个样式 / 31 个 Cell / 90 处引用全部解析通过），
> 但真机测试失败：先报 `NSCocoaErrorDomain Code=260`（找不到 `config.yaml`，尽管它确实在压缩包根层），
> 加目录条目、镜像 config.yaml 后进一步导致**整个输入法无法运行**。
>
> 失败的根本原因是**皮肤格式无法离线验证**——仓没有皮肤校验器，文档在关键处也不完整
> （例如「不声明 numeric/symbolic 会不会回落到内置键盘」在文档里查不到）。
> 该项收益仅为三处外观细节，代价却是核心功能不可用，因此**已回退并放弃**。
>
> 若要重试，**必须先有一个确认能用的 `.hskin` 样本作为对照**，照它改写才有意义。
> 草稿与打包工具保存在本地 `_local-only/skin-abandoned/`（未入库）。

**替代方案：用「空格两侧按键」放 2 个固定词（不需要皮肤）**

`hamster.yaml` 里有三个能放自定义文字的键，都在**键盘底部**而非候选栏：

```yaml
patch:
  keyboard/displaySpaceLeftButton: true
  keyboard/spaceLeftButtonProcessByRIME: false   # false = 直接上屏文字，不与 RIME 交互
  keyboard/keyValueOfSpaceLeftButton: "好的"
  keyboard/displaySpaceRightButton: true
  keyboard/spaceRightButtonProcessByRIME: false
  keyboard/keyValueOfSpaceRightButton: "收到"
```

依据：模板 L69-75（三行一组）+ FAQ「如何为默认中文26键的键盘增加…空格两侧自定义按键」（`questions.mdx` L17-29）
+ `keyboard_skins.mdx` L1615（`symbol` = 直接上屏的字符）。

限制：**只有 2 个**，且位于空格两侧——而 iOS 原生在那个位置放的是**功能键**（`123`、地球、`换行`），
所以这个做法对"像原生"是**减分**。可在「键盘设置 → 键盘布局 → 中文26键」的界面里即时试，无需重新打包。

**Apple 平台硬限制（任何第三方键盘都做不到）**

- 系统听写（键盘扩展无麦克风权限）
- 在密码框 / 安全输入框使用（系统强制切回原生键盘）
- 读取宿主 App 的完整文本上下文（只能拿到有限的 `textDocumentProxy` 内容）

**没有在线词库**

Rime 生态里存在云输入方案（如 [rime-wenyun](https://github.com/xing133/rime-wenyun)，纯 Lua 实现），但它依赖 `io.popen()` 调用外部 `curl` 命令，而 **iOS 禁止 App 使用 `fork`**，因此无法在仓上运行。加上仓是闭源 App、无法为其添加 C++ 插件，**本配置保持完全离线**：打字零联网，视觉与 iOS 原生同级隐私。

「当下热点词」的现实路径是**本地热词表 + 定期用上游最新词库重打包**（见 `eval/README.md` 与 `build.ps1`）。

---

## 许可与第三方归属

**本项目整体以 [GPL-3.0](https://www.gnu.org/licenses/gpl-3.0.html) 授权**，因为它包含并派生自 [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice)（**GPL-3.0 only**）的方案与词库文件。`dist/` 内的压缩包中已保留上游 `LICENSE` 文件。

| 来源 | 许可 | 本项目中的体现 |
| --- | --- | --- |
| [雾凇拼音 rime-ice](https://github.com/iDvel/rime-ice) | GPL-3.0 | `src/rime_ice_full.dict.yaml` 引用的全部词库、`double_pinyin_mspy.custom.yaml` 所补丁的方案、`reference/rime-ice/` |
| [Rime 官方双拼方案](https://github.com/rime/rime-double-pinyin) | GPL-3.0 | 微软双拼键位映射的权威来源 |
| [仓输入法 Hamster](https://github.com/imfuxiao/Hamster) | 截至 2.1.0 为 MIT，其后闭源 | `reference/hamster.default.yaml`（配置键名校验基准）与 `reference/hamster/*.mdx`（官方文档） |
| 本仓库原创部分（`src/` 补丁、`tools/`、`eval/`、文档） | GPL-3.0 | — |

> 若在 GitHub 新建仓库，请在创建时选择 **GNU General Public License v3.0** 作为 license。
