# BaoCode Antigravity on Linux SSH and WSL
1. Open the Linux SSH project or the WSL distribution in BaoCode.
2. In that environment's terminal, under the same user BaoCode connects as, install Google's official Antigravity CLI. Confirm that `agy --version` and `agy models` work, and if necessary sign in using `agy acp --login`. No Google credential is sent back to Windows.
3. In the project's chat model picker, look for **Antigravity · <host>**. The local AGY settings control the Windows installation only. New remote conversations use the normal BaoCode conversation catalog. The previous experimental build's separate-kernel conversations are not automatically imported; the original AGY data stays with that Linux user.
4. Usage for new turns appears in BaoCode; account quotas for the remote Google sign-in can be checked using `/usage` directly in that environment's interactive Antigravity CLI. BaoCode does not access its credential store for quotas.
5. The unsigned Windows fork installer uses the same app identity as the previous preview. Back up the BaoCode data folder before installing and keep the old installer if you need to open old preview history. The fork build does not use the official auto-update channel.

## Install the remote CLI without opening a terminal

Open an SSH or WSL project and expand its **Antigravity · host** group in
the model picker. BaoCode only checks the target until you click **Install**.
The download and SHA-512 check run for that target's Linux architecture.
The verified Google binary is added to the project user's `~/.local/bin`
without sudo, replacing existing executables, or changing shell settings.

After installation, click **Sign in** in the same host group if needed.
BaoCode runs Google's `agy acp --login` on the host and opens its Google
authorization link only when requested. Paste Google's temporary code
into the BaoCode dialog; the durable CLI credentials remain on that host.
The app verifies sign-in by refreshing the host's model list. Local
Antigravity settings and unrelated hosts are not changed.
