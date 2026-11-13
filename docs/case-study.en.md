# Case study: five blank icons, every standard fix failed

> This is the real incident that IconDoctor grew out of. It is documented in
> detail because it is the best evidence that layer 5 (the folder object)
> exists at all.

## Symptom

Windows 11 (build 26100), 25 shortcuts on the desktop. Five of them rendered
as the generic white-page-plus-arrow icon:

- JianYing (CapCut desktop)
- Cemu
- Baidu Netdisk
- MuMu Player
- DSH Desktop

Every one of them launched normally. The other 20 icons were fine.

## Round one: everything the tutorials say

| Attempt | Result |
|---|---|
| Kill Explorer, delete every `iconcache_*.db`, restart | ❌ no change |
| `ie4uinit.exe -show` | ❌ no change |
| Re-register ShellExperienceHost (Microsoft's own guidance) | ❌ no change |
| Delete and recreate the five `.lnk` files | ❌ no change |
| Point the shortcuts at an external `.ico` | ❌ no change |
| Raise `Max Cached Icons` to 8192 | ❌ no change (worth keeping anyway) |

At this point the standard toolbox is empty.

## Round two: isolate by control experiment

No more guessing. Every measurement came from the same two calls: `SHGetFileInfo`
for the icon the shell actually draws, `ExtractIconEx` for the icon the executable
actually contains.

| Experiment | Result |
|---|---|
| Extract the icon straight from `Cemu.exe` | ✅ correct (blue C) |
| Read the icon of `Cemu.lnk` | ❌ blank |
| Copy a **working** `Code.lnk` into the desktop folder | ❌ becomes blank |
| Copy the same `Code.lnk` into `E:\` | ✅ fine |
| Copy it into `E:\TestDir` | ✅ fine |
| Create a new shortcut to `notepad.exe` **inside** the desktop folder | ❌ blank |
| Put `Cemu.exe` itself into the desktop folder | ✅ correct icon |
| Put a `.url` file into the desktop folder | ✅ correct icon |

The result converges cleanly:

- not the executable (its icon extracts fine),
- not the shortcut contents (a known-good `.lnk` goes blank too),
- not the cache (fully cleared),
- not the drive (same volume, different folder behaves differently),
- **only `.lnk` files inside this one folder fail** — `.exe` and `.url` are fine.

## Round three: the folder object, not the registration

Pointing the desktop at a brand-new folder (`SHSetKnownFolderPath`) and
restarting Explorer:

- a new `.lnk` in the new folder → ✅ correct icon

So "the desktop is redirected" is not the trigger. Two other suspects were
also eliminated:

- removing `desktop.ini` and the read-only attribute → ❌ still blank
- cleaning the ACL (an `Everyone` deny rule plus an orphan `S-1-4-*` SID) → ❌ still blank

Same path, same permissions, same contents — a **new directory object** fixes it.
The old object carried some corrupt state that the shell hits when resolving
shortcut icons for items inside it.

## Fix

Rebuild the folder in place (rename, not copy — instant, same volume):

1. create `E:\DeskTop_new`
2. move all 59 entries into it
3. rename the now-empty `E:\DeskTop` to `E:\DeskTop_old`
4. rename `E:\DeskTop_new` to `E:\DeskTop`
5. restart Explorer, reset the icon cache once, recreate the five shortcuts

All five icons came back, and no path changed — project directories and absolute
paths in scripts kept working.

## The reusable criterion

The valuable part is not the repair, it is the decision rule:

> The same `.lnk` renders blank inside the target folder and renders correctly
> in `%TEMP%` ⇒ the problem is the folder object — not the icon, not the
> shortcut, not the cache.

That rule is now implemented as `Test-LayerFolderObject` (the L5 probe) and runs
automatically on every diagnosis.


---

## Appendix: a second cause, same day — damaged shortcut data

After the folder object was rebuilt, a reboot left **25 shortcuts blank** again
(including VS Code, IDEA and WeChat, which had been fine). It looked like a
relapse, but the probes told a different story:

| Experiment | Result | Conclusion |
|---|---|---|
| New shortcut in `%TEMP%` | ✅ correct icon | shell handler is fine |
| New shortcut **on the desktop** | ✅ correct icon | **folder is fine** |
| **Pre-existing** shortcuts on the desktop | ❌ all 28 colours (blank) | **the files themselves are broken** |
| Rebuild one of them | ✅ recovers | confirmed |

The file headers differ:

```
broken .lnk : LinkFlags = 0x0000009B   (HasRelativePath + HasWorkingDir)
new .lnk    : LinkFlags = 0x00000083
```

These shortcuts were created months ago and carry an embedded **relative path**.
Rebuilding the folder changed the base those relative paths resolved against, so
after the reboot resolution failed and the shell fell back to the generic page
icon — while the `TargetPath` string in `LinkInfo` stayed valid, which is why
double-clicking still worked.

Fix: rebuild the shortcuts, keeping arguments, working directory and description.
Twenty-four of them in one pass:

```powershell
Invoke-IconRepair
```

### The two failures side by side

| | Morning | Afternoon |
|---|---|---|
| Cause | damaged folder object | damaged link data inside the shortcuts |
| Decision rule | same file blank in the folder, fine in `%TEMP%` | new file fine, existing files blank |
| Repair | rebuild the folder object | rebuild each shortcut |
| Layer | L5 | L2 |

> **Same symptom, two different layers.** That is exactly where "clear the icon
> cache" tutorials break down: cache clearing fixes neither L5 nor L2.
