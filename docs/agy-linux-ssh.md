# Antigravity 预览版：Linux SSH 项目

1. 在 Windows 的 BaoCode 中通过 SSH 打开 Linux 项目目录。
2. 新建空会话，在输入框旁的内核菜单选 **Antigravity**。
3. 如果没检测到 CLI，点聊天里的「安装」。安装以 SSH 用户身份进行，不需要 sudo。如果服务器不能访问 Google 下载地址，改在 BaoCode 的 SSH 终端里按 [Google 的 Linux 安装文档](https://antigravity.google/docs/getting-started?tab=cli) 操作，再重试。
4. 点「登录」，或在同一 SSH 用户的终端运行 `agy acp --login`。用本机浏览器完成 Google 授权，只把一次性授权码交回登录提示。不要把令牌、凭据文件或授权码发到聊天消息里。
5. 登录后重新打开会话或发送消息。BaoCode 会在远端项目目录启动 `agy acp`，会话和凭据由远端 CLI 保存。打开/恢复会话时仍需连接原 SSH 主机和用户。

配对手机可以打开已有远端 Antigravity 会话。支持内核选择的新客户端可以在空白会话里选 Antigravity；旧客户端可以打开桌面已选好内核的会话，或沿用桌面默认内核。浏览器截图工具继续沿用 BaoCode 的工具权限；手机可发图片，并读取远端项目内的截图文件。

短暂网络中断由 BaoCode SSH 通道恢复。如果远端会话守护进程也停止，重新连接后可从 agy 已保存的会话继续，未完成的一轮不会自动重发。当前仅支持 Linux SSH；暂不在客户端读取远端 Google 账户额度或任务日志文件，也不支持 agy ACP 没提供的回退、分叉。
