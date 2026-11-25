import 'dart:async';

import 'package:flutter/material.dart';

import '../../kernel/antigravity/agy_remote_runtime.dart';
import '../../remote/remote_location.dart';
import '../../workspace/editor_launcher.dart' show openExternal;

/// Runs setup only after the user clicks the host-specific picker action.
Future<void> showRemoteAgySetup(
  BuildContext context, {
  required RemoteAgyRuntime runtime,
  required bool install,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _RemoteAgySetup(runtime: runtime, install: install),
);

bool remoteAgyChinese(BuildContext context) =>
    Localizations.localeOf(context).languageCode == 'zh';

class _RemoteAgySetup extends StatefulWidget {
  const _RemoteAgySetup({required this.runtime, required this.install});

  final RemoteAgyRuntime runtime;
  final bool install;

  @override
  State<_RemoteAgySetup> createState() => _RemoteAgySetupState();
}

class _RemoteAgySetupState extends State<_RemoteAgySetup> {
  final _cancel = Completer<void>();
  final _code = TextEditingController();
  Completer<String?>? _authorization;
  Uri? _link;
  bool _busy = true;
  bool _success = false;
  bool _verifiedModels = false;

  String _text(String zh, String en) => remoteAgyChinese(context) ? zh : en;

  @override
  void initState() {
    super.initState();
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      if (widget.install) {
        await widget.runtime.installOnHost(cancel: _cancel.future);
      } else {
        await widget.runtime.signInOnHost(
          cancel: _cancel.future,
          authorize: (url) {
            if (!mounted) return Future.value(null);
            final authorization = Completer<String?>();
            setState(() {
              _link = url;
              _authorization = authorization;
            });
            return authorization.future;
          },
        );
      }
      if (!mounted) return;
      // For installation the CLI can be ready without a linked account.
      _success = await widget.runtime.version() != null;
      if (_success) {
        try {
          _verifiedModels = (await widget.runtime.models()).isNotEmpty;
        } on Object {
          _verifiedModels = false;
        }
      }
      if (!widget.install && !_verifiedModels) _success = false;
    } on Object {
      // Never surface raw remote output or log the OAuth URL or code.
      _success = false;
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _link = null;
          _code.clear();
        });
      }
    }
  }

  void _submit() {
    final code = _code.text.trim();
    if (code.isEmpty) return;
    final authorization = _authorization;
    if (authorization == null || authorization.isCompleted) return;
    authorization.complete(code);
    setState(() {
      _link = null;
      _code.clear();
    });
  }

  @override
  void dispose() {
    _cancel.complete();
    final authorization = _authorization;
    if (authorization != null && !authorization.isCompleted) {
      authorization.complete(null);
    }
    _code.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = RemoteLocation.hostName(widget.runtime.host);
    final title = widget.install
        ? _text('安装 Antigravity', 'Install Antigravity')
        : _text('登录 Antigravity', 'Sign in to Antigravity');
    final link = _link;
    return AlertDialog(
      title: Text('$title · $host'),
      content: SizedBox(
        width: 420,
        child: link != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _text(
                      '在浏览器完成 Google 登录，然后将授权码粘贴到这里。',
                      'Sign in with Google in your browser, then paste the authorization code here.',
                    ),
                  ),
                  TextButton(
                    onPressed: () => unawaited(openExternal(link.toString())),
                    child: Text(_text('打开 Google 登录', 'Open Google sign-in')),
                  ),
                  TextField(
                    controller: _code,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    onSubmitted: (_) => _submit(),
                    decoration: InputDecoration(
                      labelText: _text('授权码', 'Authorization code'),
                    ),
                  ),
                ],
              )
            : _busy
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const LinearProgressIndicator(),
                  const SizedBox(height: 12),
                  Text(
                    widget.install
                        ? _text(
                            '正在目标环境安装 Google 官方 CLI…',
                            'Installing the official Google CLI on the target…',
                          )
                        : _text(
                            '正在等待目标环境的登录结果…',
                            'Waiting for sign-in on the target…',
                          ),
                  ),
                ],
              )
            : Text(
                _success
                    ? _verifiedModels
                          ? _text(
                              '已就绪，模型列表将刷新。',
                              'Ready. The model list will refresh.',
                            )
                          : _text(
                              '已安装。请在模型菜单里选择「登录」。',
                              'Installed. Choose Sign in in the model menu.',
                            )
                    : widget.install
                    ? _text(
                        '未能安装。请检查目标环境能否访问 Google 下载站点，并已安装 curl、tar 和 sha512sum。',
                        'Installation failed. Check that the target can reach Google downloads and has curl, tar and sha512sum.',
                      )
                    : _text(
                        '未能确认登录。请重试，并只使用本次登录生成的授权码。',
                        'Sign-in was not confirmed. Retry with the code from this attempt.',
                      ),
              ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(_busy ? _text('取消', 'Cancel') : _text('关闭', 'Close')),
        ),
        if (link != null)
          FilledButton(
            onPressed: _submit,
            child: Text(_text('继续', 'Continue')),
          ),
      ],
    );
  }
}
