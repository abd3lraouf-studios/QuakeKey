# Security

## Reporting a vulnerability

Please report security problems privately through GitHub's
[private vulnerability reporting](https://github.com/abd3lraouf-studios/QuakeKey/security/advisories/new) for this
repository, not in a public issue. Include the QuakeKey version (or commit), your Windows build and the steps to
reproduce. You should get an answer within a week.

## What QuakeKey changes on your machine

QuakeKey registers a scheduled task that runs `C:\Program Files\QuakeKey\QuakeKey.exe` **elevated, every time you
sign in**. It has to: Windows does not deliver a global hotkey to a normal-privilege program while an elevated window
has focus. The rest of the design limits what that elevated process trusts:

- Its program file and folder are admin-only, and the installer installs only the exact file it built (SHA-256
  checked after the UAC prompt).
- It writes only to an admin-only log folder, created with its final permissions; it never writes through links.
- It never starts Terminal or anything else with admin rights; Terminal is started by a separate normal-privilege
  task.
- It sends exactly one fixed message (`WM_HOTKEY`, index 0) to a Terminal of the same user, in the same session,
  that is not elevated and is the Microsoft Store release package.

## The trade-off you should know about

QuakeKey is a .NET Framework program, and the task starts it with **your account's environment**. .NET reads
`COR_*` and `COMPlus_*` environment variables while it starts, before any QuakeKey code runs. `COR_ENABLE_PROFILING`
with `COR_PROFILER` loads a profiler DLL, and other `COMPlus_*` settings change how the runtime loads code. Any
program running as you, without admin rights, can set such variables for your account (`HKCU\Environment`). At your
next sign-in they would take effect inside the elevated QuakeKey. An elevated logon task therefore gives code that
already runs as you a way to admin rights without a UAC prompt.

QuakeKey checks for these variables and refuses to run elevated when one is set, logging
`not starting elevated: the environment variable ... is set`. That is a **tripwire, not a defense**: by the time the
check runs, the variable has already had its effect. If you see that line and did not set the variable yourself,
treat the account as compromised.

Microsoft does not treat UAC as a security boundary, and many tools that run elevated at logon share this property.
On a single-user PC where you approve UAC prompts anyway, it changes little. On a machine where the UAC prompt is a
control you rely on, for example where people without the admin password use your account, don't install QuakeKey.
Fully removing this path would need the elevated part written in native code, which cannot be built with the
compiler that ships with Windows; that is a possible future change.

The same applies, in a smaller way, to installing: `install.ps1` runs `scripts\Elevated.ps1` from the folder you
cloned, which your account can write to. Something already running as you could change that script while the UAC
prompt is open. The exe itself is hash-checked; the scripts cannot check themselves.

## Supported versions

Only the latest release gets fixes.
