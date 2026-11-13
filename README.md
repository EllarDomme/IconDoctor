# IconDoctor

> 桌面快捷方式图标变成"白纸"时，绝大多数教程只有一个答案：清图标缓存。
> IconDoctor 换了个思路——**先定位坏在哪一层，再只修那一层，修完自己验证**。

[![CI](https://github.com/OWNER/IconDoctor/actions/workflows/ci.yml/badge.svg)](https://github.com/OWNER/IconDoctor/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-blue)
![Platform](https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-lightgrey)
![License](https://img.shields.io/badge/license-MIT-green)

---

## 为什么要做这个

"图标变白纸"是 Windows 上最经典的一类疑难杂症。网上的解决步骤几乎都是固定的四步：

1. 结束 explorer.exe
2. 删 `iconcache_*.db`
3. 重启 explorer.exe
4. `ie4uinit.exe -show`

这四步能解决**缓存层**的问题（大概七八成）。剩下那两三成呢？用户会被告知"你系统坏了""重装吧"。

而这个故障其实有**至少六层**可能的原因，清缓存只覆盖其中一层：

| 层 | 探测的问题 | 判断依据 |
|---|---|---|
| **L1 图标源** | 程序本身还有图标资源吗？ | 直接从 exe 抠图标（绕过缓存） |
| **L2 快捷方式** | `.lnk` 内容还完整吗？ | 目标路径、参数、工作目录可解析 |
| **L3 图标缓存** | 缓存坏了/满了？ | 数据库文件大小、`Max Cached Icons` |
| **L4 Shell 处理器** | `.lnk` 的 IconHandler 还注册着吗？ | `HKCR\lnkfile\shellex\IconHandler` → `windows.storage.dll` |
| **L5 文件夹对象** | **是这个目录在污染图标解析吗？** | 同目录新建探针 `.lnk`，与 `%TEMP%` 对照 |
| **L6 文件夹 ACL** | 目录权限有脏东西吗？ | Deny 规则、孤儿 SID（`S-1-4-*`） |

**L5 是绝大多数工具完全没覆盖的一层**，也是真实存在、且清缓存永远修不好的情况。IconDoctor 的起点就是一次这样的真实故障，见 [docs/case-study.md](docs/case-study.md)。

## 核心思路：图标指纹

工具要"知道自己有没有修好"，就必须能**客观判断一个图标是不是白纸**。

IconDoctor 的做法：

1. **基准**——用 `ExtractIconEx` 直接从目标 exe 抠图标，完全绕开 shell 缓存，这是"这个图标本该长什么样"。
2. **实测**——用 `SHGetFileInfo` 取 shell 实际会画的图标（和资源管理器同一条路径）。
3. **指纹**——两者各自降采样成 16×16 RGB 网格，计算平均绝对差，得到 0–1 的相似度。
4. **白纸判定**——近白像素占比 ≥ 45% 且平均饱和度 ≤ 0.18。两个条件同时成立才算白纸，这样"浅色底 + 彩色 logo"（比如百度网盘）不会被误判。

有了这个，`-Fix` 就能在修完之后自己再扫一遍，输出"5 个里 5 个已恢复"，而不是让你用眼睛确认。

## 安装

```powershell
git clone https://github.com/OWNER/IconDoctor.git
cd IconDoctor
Import-Module .\IconDoctor.psd1
```

也可以不安装，直接跑命令行入口：

```powershell
.\bin\IconDoctor.ps1 -Scan
```

**完全不想碰命令行**：双击仓库根目录的 `icondoctor.cmd` 就行——它会用一个临时绕过执行策略的 PowerShell 进程跑完整诊断，跑完停在结果页。Windows 默认禁止运行 `.ps1`，这个包装脚本就是为这一步准备的。

## 用法

### 1. 体检（只读，不碰系统）

```powershell
Get-IconReport | Format-Table Name, Verdict, Similarity
```

输出里每个快捷方式一个 `Verdict`：`Ok` / `Blank` / `TargetMissing` / `NoIconSource` / `Skipped`。

### 2. 六层诊断

```powershell
Invoke-IconDiagnosis | Select-Object -ExpandProperty Layers |
    Format-Table Layer, Name, Status, Detail -AutoSize -Wrap
```

或者直接：

```powershell
.\bin\IconDoctor.ps1 -Diagnose
```

会打印每一层的 `Pass / Warn / Fail / Skip` 和证据，最后给出"第一层失败的"作为根因。

### 3. 修复

```powershell
# 先看它会做什么，不动手
Invoke-IconRepair -WhatIf

# 只做安全操作（重建快捷方式、调缓存上限）
Invoke-IconRepair

# 允许重启资源管理器（会关闭所有文件夹窗口）
Invoke-IconRepair -RestartExplorer

# 允许重建文件夹对象（会搬动目录内所有文件，需 -Force 确认）
Invoke-IconRepair -RestartExplorer -RebuildFolderObject -Force
```

## 各层对应的修复

| 层 | 自动修复 | 说明 |
|---|---|---|
| L1 图标源缺失 | ❌ 只报告 | 程序本身没图标，任何缓存操作都无效 |
| L2 快捷方式损坏 | ✅ 重建 | 保留目标/参数/工作目录 |
| L3 缓存满/坏 | ✅ 重置缓存 + 提高上限 | 需要 `-RestartExplorer` |
| L4 处理器注册坏 | ⚠️ 只报告 | 需重新注册 ShellExperienceHost（提权） |
| L5 文件夹对象坏 | ✅ 换壳重建 | 需要 `-RebuildFolderObject -Force` |
| L6 ACL 异常 | ⚠️ 只报告 | 附 SDDL 备份与人工建议 |

## 安全边界

- `-Scan` / `-Diagnose` **纯只读**，不写注册表、不碰文件。
- `-Fix` 默认只做**可逆**操作；每一项改动前都会备份到 `%TEMP%\IconDoctor\backup_<时间戳>\`。
- 重启 explorer 必须显式 `-RestartExplorer`。
- 重建文件夹对象必须 `-RebuildFolderObject -Force`，并且内置回滚：任何文件搬不动就整体还原。
- 不支持 Windows 10 以前的系统。

## 已知局限

- **没有图标的程序**（L1）修不了，只能报告。
- **.url 文件**不参与扫描（走的是另一套 handler）。
- **白纸判定是启发式**：极少数"纯白底 + 极低饱和度"的正版图标可能被误判为 Blank。可以用 `-Detailed` 看原始数值再判断。
- L4 的自动修复（重新注册 ShellExperienceHost）需要管理员权限，当前版本只做检测。

## 真实案例

[`docs/case-study.md`](docs/case-study.md) 记录了一次完整的排查：五层探针逐层排除，最后定位到"文件夹对象损坏"——五个快捷方式清缓存、重注册、换 `.ico` 全部无效，把目录换个壳就好了。

## 开发

```powershell
# 单元测试（Pester 5 / 6 均可）
Invoke-Pester -Path ./tests

# 静态检查（规则豁免都在 PSScriptAnalyzerSettings.psd1 里，每条都写了理由）
Invoke-ScriptAnalyzer -Path . -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
```

CI 会在 Windows + PowerShell 5.1 / 7 两个组合上跑完整测试，并强制分析器零警告。

## 贡献

欢迎提 Issue，尤其是**你的白纸图标案例**。最有价值的反馈是：

```powershell
.\bin\IconDoctor.ps1 -Diagnose -Json > diagnosis.json
```

把 `diagnosis.json` 附在 Issue 里，六层探针的证据能直接判断是哪种故障。

## License

[MIT](LICENSE)
