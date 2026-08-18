import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:path/path.dart' as p;
import '../../l10n/app_localizations.dart';
import 'dart:io';

import 'account_management_screen.dart';
import 'download_path_settings_screen.dart';
import 'theme_settings_screen.dart';
import 'ui_settings_screen.dart';
import 'preferences_screen.dart';
import 'about_screen.dart';
import 'permissions_screen.dart';
import 'privacy_mode_settings_screen.dart';
import 'floating_lyric_style_screen.dart';
import 'log_screen.dart';
import '../providers/locale_provider.dart';
import '../providers/settings_provider.dart';
import '../providers/update_provider.dart';
import '../providers/floating_lyric_provider.dart';
import '../services/cache_service.dart';
import '../services/download_service.dart';
import '../services/network_proxy_service.dart';
import '../services/translation_service.dart';
import '../utils/snackbar_util.dart';
import '../widgets/scrollable_appbar.dart';
import '../widgets/download_fab.dart';
import '../widgets/radio_option_group.dart';
import '../widgets/settings_section.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  String _cacheSize = '';
  bool _isUpdatingCacheSize = false;
  ScaffoldMessengerState? _scaffoldMessenger;

  @override
  void initState() {
    super.initState();
    // 延迟执行，确保 ref 可用
    Future.microtask(() {
      if (mounted) {
        _updateCacheSize();
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_cacheSize.isEmpty) {
      _cacheSize = S.of(context).calculating;
    }
    _scaffoldMessenger = ScaffoldMessenger.of(context);
  }

  @override
  void dispose() {
    super.dispose();
  }

  // 安全显示 SnackBar 的辅助方法
  void _showSnackBar(SnackBar snackBar) {
    if (!mounted) return;

    SnackBarUtil.showFromSnackBar(
      context,
      snackBar,
      fallbackMessenger: _scaffoldMessenger,
    );
  }

  Future<void> _updateCacheSize() async {
    if (_isUpdatingCacheSize) return;
    _isUpdatingCacheSize = true;

    if (mounted) {
      setState(() {
        _cacheSize = S.of(context).calculating;
      });
    }

    try {
      final size = await CacheService.getFormattedCacheSize();
      if (mounted) {
        setState(() {
          _cacheSize = size;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _cacheSize = S.of(context).fetchFailed;
        });
      }
    } finally {
      _isUpdatingCacheSize = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // 监听缓存刷新触发器（只在 build 中设置一次监听）
    ref.listen<int>(
      settingsCacheRefreshTriggerProvider,
      (_, __) {
        _updateCacheSize();
      },
    );

    final isLandscape =
        MediaQuery.of(context).orientation == Orientation.landscape;
    final cards = [
      _buildAccountCard(context),
      _buildDownloadAndCacheCard(context),
      _buildAppearanceAndAboutCard(context),
    ];

    return Scaffold(
      floatingActionButton: const DownloadFab(),
      appBar: ScrollableAppBar(
        title: Text(S.of(context).settingsTitle,
            style: const TextStyle(fontSize: 18)),
      ),
      body: isLandscape
          ? _buildLandscapeLayout(cards)
          : ListView.separated(
              padding: const EdgeInsets.all(16),
              itemBuilder: (context, index) => cards[index],
              separatorBuilder: (context, index) => const SizedBox(height: 16),
              itemCount: cards.length,
            ),
    );
  }

  Widget _buildLandscapeLayout(List<Widget> cards) {
    final column1 = <Widget>[];
    final column2 = <Widget>[];

    void addToColumn(List<Widget> column, Widget card) {
      if (column.isNotEmpty) {
        column.add(const SizedBox(height: 16));
      }
      column.add(card);
    }

    for (var i = 0; i < cards.length; i++) {
      if (i.isEven) {
        addToColumn(column1, cards[i]);
      } else {
        addToColumn(column2, cards[i]);
      }
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: column1,
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: column2.isEmpty ? [const SizedBox.shrink()] : column2,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAccountCard(BuildContext context) {
    final privacySettings = ref.watch(privacyModeSettingsProvider);

    return SettingsSectionList(
      children: [
        SettingsNavigationTile(
          icon: Icons.manage_accounts,
          title: S.of(context).accountManagement,
          subtitle: S.of(context).accountManagementSubtitle,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const AccountManagementScreen(),
              ),
            );
          },
        ),
        SettingsNavigationTile(
          icon: Icons.privacy_tip_outlined,
          title: S.of(context).privacyMode,
          subtitle: privacySettings.enabled
              ? S.of(context).privacyModeEnabled
              : S.of(context).privacyModeDisabled,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const PrivacyModeSettingsScreen(),
              ),
            );
          },
        ),
        // 显示悬浮字幕 (Android & Windows & macOS & iOS)
        if (Platform.isAndroid ||
            Platform.isWindows ||
            Platform.isMacOS ||
            Platform.isIOS)
          _buildFloatingLyricTile(context),

        // 仅在安卓平台显示权限管理
        if (Platform.isAndroid)
          SettingsNavigationTile(
            icon: Icons.security,
            title: S.of(context).permissionManagement,
            subtitle: S.of(context).permissionManagementSubtitle,
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const PermissionsScreen(),
                ),
              );
            },
          ),
      ],
    );
  }

  /// 悬浮字幕开关组件
  Widget _buildFloatingLyricTile(BuildContext context) {
    final isEnabled = ref.watch(floatingLyricEnabledProvider);
    final l10n = S.of(context);

    return Column(
      children: [
        SettingsSwitchTile(
          icon: Icons.subtitles_outlined,
          title: S.of(context).desktopFloatingLyric,
          subtitle: isEnabled
              ? S.of(context).floatingLyricEnabled
              : S.of(context).privacyModeDisabled,
          subtitleStyle: TextStyle(
            color: isEnabled
                ? Theme.of(context).colorScheme.primary.withValues(alpha: 0.8)
                : null,
          ),
          value: isEnabled,
          onChanged: (value) async {
            try {
              await ref.read(floatingLyricEnabledProvider.notifier).toggle();
            } catch (e) {
              if (!context.mounted) return;
              SnackBarUtil.showError(
                context,
                l10n.operationFailedWithError(e.toString()),
              );
            }
          },
        ),
        if (isEnabled) ...[
          const SettingsDivider(),
          SettingsListTile(
            leading: const SizedBox(width: 24), // 占位对齐
            title: S.of(context).styleSettings,
            subtitle: S.of(context).styleSettingsSubtitle,
            trailing: const Icon(Icons.arrow_forward_ios, size: 16),
            onTap: () {
              Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (context) => const FloatingLyricStyleScreen(),
                ),
              );
            },
          ),
          if (Platform.isAndroid) ...[
            const SettingsDivider(),
            _buildFloatingLyricTouchTile(context),
          ],
          if (Platform.isIOS) ...[
            const SettingsDivider(),
            _buildFloatingFPSTile(context),
            const SettingsDivider(),
            _buildFloatingNetworkSpeedTile(context),
          ],
        ],
      ],
    );
  }

  /// 悬浮字幕触摸开关（仅 Android）
  Widget _buildFloatingLyricTouchTile(BuildContext context) {
    final touchEnabled = ref.watch(floatingLyricTouchEnabledProvider);
    return SettingsSwitchTile(
      secondary: const SizedBox(width: 24),
      title: S.of(context).floatingLyricTouch,
      subtitle: touchEnabled
          ? S.of(context).floatingLyricTouchEnabled
          : S.of(context).floatingLyricTouchDisabled,
      value: !touchEnabled,
      onChanged: (value) async {
        await ref.read(floatingLyricTouchEnabledProvider.notifier).toggle();
      },
    );
  }

  /// 悬浮窗 FPS 显示开关（仅 iOS）
  Widget _buildFloatingFPSTile(BuildContext context) {
    final fpsEnabled = ref.watch(floatingLyricFPSEnabledProvider);
    return SettingsSwitchTile(
      secondary: const SizedBox(width: 24),
      title: S.of(context).floatingFPS,
      subtitle: fpsEnabled
          ? S.of(context).floatingFPSEnabled
          : S.of(context).floatingFPSDisabled,
      value: fpsEnabled,
      onChanged: (value) async {
        await ref.read(floatingLyricFPSEnabledProvider.notifier).toggle();
      },
    );
  }

  /// 悬浮窗网速显示开关（仅 iOS）
  Widget _buildFloatingNetworkSpeedTile(BuildContext context) {
    final networkSpeedEnabled =
        ref.watch(floatingLyricNetworkSpeedEnabledProvider);
    return SettingsSwitchTile(
      secondary: const SizedBox(width: 24),
      title: S.of(context).floatingNetworkSpeed,
      subtitle: networkSpeedEnabled
          ? S.of(context).floatingNetworkSpeedEnabled
          : S.of(context).floatingNetworkSpeedDisabled,
      value: networkSpeedEnabled,
      onChanged: (value) async {
        await ref
            .read(floatingLyricNetworkSpeedEnabledProvider.notifier)
            .toggle();
      },
    );
  }

  Widget _buildDownloadAndCacheCard(BuildContext context) {
    return SettingsSectionList(
      children: [
        SettingsNavigationTile(
          icon: Icons.folder_outlined,
          title: S.of(context).downloadPath,
          subtitle: S.of(context).downloadPathSubtitle,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const DownloadPathSettingsScreen(),
              ),
            );
          },
        ),
        SettingsNavigationTile(
          icon: Icons.storage,
          title: S.of(context).cacheManagement,
          subtitle: S.of(context).currentCache(_cacheSize),
          onTap: _showCacheManagementDialog,
        ),
        SettingsListTile(
          icon: Icons.download_for_offline_outlined,
          title: '从原 kikoeru 导入',
          subtitle: '将旧版 kikoeru 下载的音声迁移到 KikoFlu',
          onTap: () => _importFromLegacyKikoeru(context),
        ),
        SettingsListTile(
          icon: Icons.vpn_key,
          title: '网络代理',
          subtitle: NetworkProxyService.proxyConfig.isEmpty
              ? '直连（服务器被墙时可配置，如 10.0.2.2:7897）'
              : '当前: ${NetworkProxyService.proxyConfig}',
          onTap: () => _configureNetworkProxy(context),
        ),
      ],
    );
  }

  Future<void> _configureNetworkProxy(BuildContext context) async {
    final controller =
        TextEditingController(text: NetworkProxyService.proxyConfig);
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('网络代理设置'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '服务器需要代理访问时配置，格式 host:port。'
              'MuMu 模拟器访问宿主机代理填 10.0.2.2:7897，'
              '真机填宿主机局域网 IP:7897。留空则直连。',
              style: TextStyle(fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.text,
              decoration: const InputDecoration(
                hintText: '如 10.0.2.2:7897',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: Text(S.of(ctx).cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text),
            child: const Text('保存'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (result == null || !mounted) return;

    final trimmed = result.trim();
    if (trimmed.isNotEmpty && NetworkProxyService.parseProxy(trimmed) == null) {
      _showSnackBar(const SnackBar(
        content: Text('代理格式无效，应为 host:port'),
        backgroundColor: Colors.red,
      ));
      return;
    }

    await NetworkProxyService.setProxyConfig(trimmed);
    if (!mounted) return;
    _showSnackBar(const SnackBar(
      content: Text('代理已保存，重启应用后生效'),
    ));
    setState(() {});
  }

  void _showLanguagePicker(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.read(localeProvider);
    final options = <(String, Locale?)>[
      (S.of(context).languageSystem, null),
      (S.of(context).languageZh, const Locale('zh')),
      (
        S.of(context).languageZhTw,
        const Locale.fromSubtags(languageCode: 'zh', scriptCode: 'Hant')
      ),
      (S.of(context).languageEn, const Locale('en')),
      (S.of(context).languageJa, const Locale('ja')),
      (S.of(context).languageRu, const Locale('ru')),
    ];
    final selectedIndex = options.indexWhere((option) =>
        option.$2?.languageCode == currentLocale?.languageCode &&
        option.$2?.scriptCode == currentLocale?.scriptCode);

    showDialog(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(S.of(context).settingsLanguage),
        children: [
          RadioOptionGroup<int>(
            groupValue: selectedIndex >= 0 ? selectedIndex : null,
            options: [
              for (var index = 0; index < options.length; index++)
                RadioOption(
                  value: index,
                  title: Text(options[index].$1),
                ),
            ],
            onChanged: (index) {
              ref.read(localeProvider.notifier).setLocale(options[index].$2);
              Navigator.of(context).pop();
            },
          ),
        ],
      ),
    );
  }

  Widget _buildAppearanceAndAboutCard(BuildContext context) {
    return SettingsSectionList(
      children: [
        SettingsNavigationTile(
          icon: Icons.palette,
          title: S.of(context).themeSettings,
          subtitle: S.of(context).themeSettingsSubtitle,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const ThemeSettingsScreen(),
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final currentLocale = ref.watch(localeProvider);
            String localeLabel;
            if (currentLocale == null) {
              localeLabel = S.of(context).languageSystem;
            } else if (currentLocale.scriptCode == 'Hant') {
              localeLabel = S.of(context).languageZhTw;
            } else {
              localeLabel = switch (currentLocale.languageCode) {
                'zh' => S.of(context).languageZh,
                'en' => S.of(context).languageEn,
                'ja' => S.of(context).languageJa,
                'ru' => S.of(context).languageRu,
                _ => currentLocale.languageCode,
              };
            }
            return SettingsNavigationTile(
              icon: Icons.language,
              title: S.of(context).settingsLanguage,
              subtitle: localeLabel,
              onTap: () => _showLanguagePicker(context, ref),
            );
          },
        ),
        SettingsNavigationTile(
          icon: Icons.dashboard_customize,
          title: S.of(context).uiSettings,
          subtitle: S.of(context).uiSettingsSubtitle,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const UiSettingsScreen(),
              ),
            );
          },
        ),
        SettingsNavigationTile(
          icon: Icons.tune,
          title: S.of(context).preferenceSettings,
          subtitle: S.of(context).preferenceSettingsSubtitle,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const PreferencesScreen(),
              ),
            );
          },
        ),
        SettingsNavigationTile(
          icon: Icons.article_outlined,
          title: S.of(context).logTitle,
          subtitle: S.of(context).logSubtitle,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(
                builder: (context) => const LogScreen(),
              ),
            );
          },
        ),
        Consumer(
          builder: (context, ref, _) {
            final showRedDot = ref.watch(showUpdateRedDotProvider);
            final hasNewVersion = ref.watch(hasNewVersionProvider);

            return SettingsListTile(
              leading: Stack(
                children: [
                  Icon(Icons.info_outline,
                      color: Theme.of(context).colorScheme.primary),
                  // Red dot indicator for updates (only when not notified)
                  if (showRedDot)
                    Positioned(
                      right: 0,
                      top: 0,
                      child: Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: Theme.of(context).colorScheme.surface,
                            width: 1,
                          ),
                        ),
                      ),
                    ),
                ],
              ),
              title: S.of(context).aboutTitle,
              subtitle: S.of(context).aboutSubtitle,
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (hasNewVersion)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: [
                            Theme.of(context).colorScheme.primaryContainer,
                            Theme.of(context).colorScheme.secondaryContainer,
                          ],
                        ),
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: Theme.of(context)
                              .colorScheme
                              .primary
                              .withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.new_releases,
                            size: 14,
                            color: Theme.of(context).colorScheme.primary,
                          ),
                          const SizedBox(width: 4),
                          Text(
                            S.of(context).hasNewVersion,
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.primary,
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(width: 8),
                  const Icon(Icons.arrow_forward_ios),
                ],
              ),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (context) => const AboutScreen(),
                  ),
                );
              },
            );
          },
        ),
      ],
    );
  }

  Future<void> _importFromLegacyKikoeru(BuildContext context) async {
    // Android 11+ Scoped Storage 下读取 /sdcard 任意目录需"所有文件访问"权限
    if (Platform.isAndroid) {
      var status = await Permission.manageExternalStorage.status;
      if (!status.isGranted) {
        status = await Permission.manageExternalStorage.request();
      }
      if (!status.isGranted) {
        // Android 10 及以下回退到传统存储权限
        final legacy = await Permission.storage.request();
        if (!legacy.isGranted) {
          if (!mounted) return;
          _showSnackBar(const SnackBar(
            content: Text('导入需要文件访问权限，请在系统设置中授予后重试'),
            backgroundColor: Colors.red,
          ));
          return;
        }
      }
    }

    // 选择源目录（通常是 /sdcard/KikoeruLib/libs_work）
    String? sourcePath;
    try {
      sourcePath = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择原 kikoeru 下载目录（通常为 KikoeruLib/libs_work）',
      );
    } catch (e) {
      if (!mounted) return;
      _showSnackBar(SnackBar(content: Text('选择目录失败: $e')));
      return;
    }
    if (sourcePath == null || !mounted) return;

    final sourceDir = Directory(sourcePath);
    final progressNotifier =
        ValueNotifier<_ImportProgress>(const _ImportProgress());

    // 显示进度对话框
    if (!context.mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => ValueListenableBuilder<_ImportProgress>(
        valueListenable: progressNotifier,
        builder: (ctx, p, _) => AlertDialog(
          title: const Text('正在导入'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              LinearProgressIndicator(
                value: p.total > 0 ? p.done / p.total : null,
              ),
              const SizedBox(height: 12),
              if (p.total > 0)
                Text('已迁移 ${p.done} / ${p.total} 个目录')
              else
                const Text('正在扫描目录...'),
              const SizedBox(height: 4),
              if (p.bytes > 0) Text('已复制 ${_formatImportBytes(p.bytes)}'),
            ],
          ),
        ),
      ),
    );

    // 执行导入
    final result = await DownloadService.instance.importFromLegacyKikoeru(
      sourceDir,
      onProgress: (done, total, bytes) {
        progressNotifier.value = _ImportProgress(
          done: done,
          total: total,
          bytes: bytes,
        );
      },
    );

    progressNotifier.dispose();
    if (!context.mounted) return;
    Navigator.of(context).pop();

    final skipDetails = result.skipped
        .take(2)
        .map((s) => '${p.basename(s.path)}: ${s.reason}')
        .join('\n');
    final failDetails = result.failed
        .take(2)
        .map((s) => '${p.basename(s.path)}: ${s.reason}')
        .join('\n');
    final msg = result.error != null
        ? '导入失败: ${result.error}'
        : '导入完成：成功 ${result.success} 个，'
            '跳过 ${result.skippedCount} 个，'
            '失败 ${result.failedCount} 个'
            '${skipDetails.isNotEmpty ? '\n跳过详情:\n$skipDetails' : ''}'
            '${failDetails.isNotEmpty ? '\n失败详情:\n$failDetails' : ''}'
            '\n源目录: $sourcePath';
    if (!mounted) return;
    _showSnackBar(SnackBar(
      content: Text(msg),
      duration: const Duration(seconds: 5),
      backgroundColor: result.error != null ? Colors.red : Colors.green,
    ));
    await _updateCacheSize();
  }

  String _formatImportBytes(int bytes) {
    if (bytes <= 0) return '0 B';
    const units = ['B', 'KB', 'MB', 'GB'];
    int i = 0;
    double size = bytes.toDouble();
    while (size >= 1024 && i < units.length - 1) {
      size /= 1024;
      i++;
    }
    return '${size.toStringAsFixed(i == 0 ? 0 : 2)} ${units[i]}';
  }

  Future<void> _confirmAndClearCache(BuildContext dialogContext) async {
    final l10n = S.of(dialogContext);
    bool includeDownloads = false;
    
    final result = await showDialog<Map<String, bool>>(
      context: dialogContext,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: Text(l10n.confirmClear),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.confirmClearCacheMessage),
              const SizedBox(height: 16),
              // O10: 添加"是否包含下载文件"选项
              CheckboxListTile(
                title: Text(l10n.includeDownloads),
                subtitle: Text(l10n.includeDownloadsWarning),
                value: includeDownloads,
                onChanged: (value) {
                  setState(() {
                    includeDownloads = value ?? false;
                  });
                },
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, null),
              child: Text(l10n.cancel),
            ),
            ElevatedButton(
              onPressed: () => Navigator.pop(context, {'confirmed': true, 'includeDownloads': includeDownloads}),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
              ),
              child: Text(l10n.confirmClear),
            ),
          ],
        ),
      ),
    );

    if (result == null || result['confirmed'] != true || !mounted || !dialogContext.mounted) return;

    final navigator = Navigator.of(dialogContext);
    showDialog(
      context: dialogContext,
      barrierDismissible: false,
      builder: (context) => const Center(
        child: CircularProgressIndicator(),
      ),
    );

    try {
      await CacheService.clearAllCache();
      
      // O10: 如果用户选择包含下载文件，则清理下载目录
      if (result['includeDownloads'] == true) {
        await DownloadService.instance.clearAllDownloads();
      }
      
      if (!mounted || !dialogContext.mounted) return;

      navigator.pop(); // 关闭加载指示器
      navigator.pop(); // 关闭缓存管理对话框
      await _updateCacheSize();

      final message = result['includeDownloads'] == true
          ? l10n.cacheAndDownloadsCleared
          : l10n.cacheCleared;

      _showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.green,
        ),
      );
    } catch (e) {
      if (!mounted || !dialogContext.mounted) return;
      navigator.pop(); // 关闭加载指示器
      _showSnackBar(
        SnackBar(
          content: Text(l10n.clearCacheFailedWithError(e.toString())),
          backgroundColor: Colors.red,
        ),
      );
    }
  }

  Future<void> _clearTranslationCache(BuildContext dialogContext) async {
    final l10n = S.of(dialogContext);
    final navigator = Navigator.of(dialogContext);

    await TranslationService().clearCache();
    if (!mounted || !dialogContext.mounted) return;

    navigator.pop();
    _showSnackBar(
      SnackBar(
        content: Text(l10n.translationCacheCleared),
        backgroundColor: Colors.green,
      ),
    );
  }

  // 显示缓存管理对话框
  Future<void> _showCacheManagementDialog() async {
    // 直接使用已经获取的 _cacheSize，避免重复调用
    final currentSize = await CacheService.getCacheSize();
    final formattedSize = _cacheSize; // 使用已缓存的格式化字符串
    int currentLimit = await CacheService.getCacheSizeLimit();

    // O7: 获取分项存储数据
    final audioCacheSize = await CacheService.getAudioCacheSize();
    final imageCacheSize = await CacheService.getImageCacheSize();
    final downloadSize = await CacheService.getDownloadSize();
    final appCacheSize = currentSize - audioCacheSize - imageCacheSize;

    if (!mounted) return;

    showDialog(
      context: context,
      builder: (context) {
        // 使用独立的状态变量控制滑动条
        int tempLimit = currentLimit;

        // 非线性刻度映射函数
        // 滑动条值 0-100 映射到实际缓存大小
        // 0-50: 100MB-1000MB (每档约18MB)
        // 50-75: 1000MB-3000MB (每档约80MB)
        // 75-90: 3000MB-5000MB (每档约133MB)
        // 90-100: 5000MB-10240MB (每档约524MB)
        int sliderValueToMB(double sliderValue) {
          if (sliderValue <= 50) {
            // 100MB to 1000MB
            return 100 + ((sliderValue / 50) * 900).toInt();
          } else if (sliderValue <= 75) {
            // 1000MB to 3000MB
            return 1000 + (((sliderValue - 50) / 25) * 2000).toInt();
          } else if (sliderValue <= 90) {
            // 3000MB to 5000MB
            return 3000 + (((sliderValue - 75) / 15) * 2000).toInt();
          } else {
            // 5000MB to 10240MB
            return 5000 + (((sliderValue - 90) / 10) * 5240).toInt();
          }
        }

        // MB值反向映射到滑动条值
        double mbToSliderValue(int mb) {
          if (mb <= 1000) {
            return ((mb - 100) / 900.0) * 50;
          } else if (mb <= 3000) {
            return 50 + (((mb - 1000) / 2000.0) * 25);
          } else if (mb <= 5000) {
            return 75 + (((mb - 3000) / 2000.0) * 15);
          } else {
            return 90 + (((mb - 5000) / 5240.0) * 10);
          }
        }

        double currentSliderValue = mbToSliderValue(tempLimit);

        final isLandscape =
            MediaQuery.of(context).orientation == Orientation.landscape;

        return StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            title: Row(
              children: [
                Expanded(
                  child: Text(S.of(context).cacheManagement,
                      style: const TextStyle(fontSize: 18)),
                ),
                if (isLandscape)
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                    tooltip: S.of(context).close,
                  ),
              ],
            ),
            content: SingleChildScrollView(
              child: isLandscape
                  ? SizedBox(
                      width: MediaQuery.of(context).size.width * 0.65,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 左列：缓存信息
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 当前缓存大小
                                SettingsSectionCard(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          S.of(context).currentCacheSize,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Text(
                                          formattedSize,
                                          style: TextStyle(
                                            fontSize: 24,
                                            fontWeight: FontWeight.bold,
                                            color: Theme.of(context)
                                                .colorScheme
                                                .primary,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        LinearProgressIndicator(
                                          value: currentLimit > 0
                                              ? (currentSize /
                                                      (currentLimit *
                                                          1024 *
                                                          1024))
                                                  .clamp(0.0, 1.0)
                                              : 0.0,
                                          backgroundColor: Colors.grey[300],
                                          valueColor:
                                              AlwaysStoppedAnimation<Color>(
                                            currentSize >
                                                    currentLimit * 1024 * 1024
                                                ? Colors.red
                                                : Theme.of(context)
                                                    .colorScheme
                                                    .primary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        Text(
                                          S
                                              .of(context)
                                              .cacheLimitLabelMB(currentLimit),
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: Colors.grey[600],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                // 使用量详情
                                SettingsSectionCard(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          S.of(context).cacheUsagePercent,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 8),
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            Text(
                                              '${currentLimit > 0 ? ((currentSize / (currentLimit * 1024 * 1024)) * 100).clamp(0.0, 100.0).toStringAsFixed(1) : "0.0"}%',
                                              style: TextStyle(
                                                fontSize: 20,
                                                fontWeight: FontWeight.bold,
                                                color: currentSize >
                                                        currentLimit *
                                                            1024 *
                                                            1024
                                                    ? Colors.red
                                                    : Theme.of(context)
                                                        .colorScheme
                                                        .primary,
                                              ),
                                            ),
                                            Icon(
                                              currentSize >
                                                      currentLimit * 1024 * 1024
                                                  ? Icons.warning_amber_rounded
                                                  : Icons.check_circle_outline,
                                              color: currentSize >
                                                      currentLimit * 1024 * 1024
                                                  ? Colors.red
                                                  : Colors.green,
                                              size: 28,
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                // O7: 存储分项展示
                                SettingsSectionCard(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .surfaceContainerHighest,
                                  child: Padding(
                                    padding: const EdgeInsets.all(16.0),
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          S.of(context).storageBreakdown,
                                          style: const TextStyle(
                                            fontSize: 14,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        const SizedBox(height: 12),
                                        _buildStorageBreakdownItem(
                                          context,
                                          icon: Icons.folder_outlined,
                                          label: S.of(context).storageCache,
                                          size: appCacheSize,
                                          color: Colors.blue,
                                        ),
                                        const SizedBox(height: 8),
                                        _buildStorageBreakdownItem(
                                          context,
                                          icon: Icons.audiotrack_outlined,
                                          label: S.of(context).storageAudioCache,
                                          size: audioCacheSize,
                                          color: Colors.purple,
                                        ),
                                        const SizedBox(height: 8),
                                        _buildStorageBreakdownItem(
                                          context,
                                          icon: Icons.image_outlined,
                                          label: S.of(context).storageImageCache,
                                          size: imageCacheSize,
                                          color: Colors.orange,
                                        ),
                                        const SizedBox(height: 8),
                                        _buildStorageBreakdownItem(
                                          context,
                                          icon: Icons.download_outlined,
                                          label: S.of(context).storageDownloads,
                                          size: downloadSize,
                                          color: Colors.green,
                                        ),
                                        const Divider(height: 24),
                                        _buildStorageBreakdownItem(
                                          context,
                                          icon: Icons.storage_outlined,
                                          label: S.of(context).storageTotal,
                                          size: currentSize + downloadSize,
                                          color: Theme.of(context).colorScheme.primary,
                                          isTotal: true,
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 16),
                          const VerticalDivider(width: 1),
                          const SizedBox(width: 16),
                          // 右列：设置和说明
                          Expanded(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // 缓存大小上限设置
                                Text(
                                  S.of(context).cacheSizeLimit,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Column(
                                  children: [
                                    Slider(
                                      value: currentSliderValue,
                                      min: 0,
                                      max: 100,
                                      divisions: 20,
                                      label: tempLimit < 1024
                                          ? '${tempLimit}MB'
                                          : '${(tempLimit / 1024).toStringAsFixed(1)}GB',
                                      onChanged: (value) {
                                        setDialogState(() {
                                          currentSliderValue = value;
                                          tempLimit = sliderValueToMB(value);
                                        });
                                      },
                                      onChangeEnd: (value) async {
                                        final finalLimit =
                                            sliderValueToMB(value);
                                        await CacheService.setCacheSizeLimit(
                                            finalLimit);
                                        if (mounted) {
                                          setState(() {}); // 刷新主界面
                                        }
                                      },
                                    ),
                                    Text(
                                      tempLimit < 1024
                                          ? '${tempLimit}MB'
                                          : '${(tempLimit / 1024).toStringAsFixed(1)}GB',
                                      style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: Theme.of(context)
                                            .colorScheme
                                            .primary,
                                      ),
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 16),

                                // 说明文本
                                Container(
                                  padding: const EdgeInsets.all(12),
                                  decoration: BoxDecoration(
                                    color: Colors.blue.withValues(alpha: 0.1),
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          const Icon(Icons.info_outline,
                                              size: 16, color: Colors.blue),
                                          const SizedBox(width: 8),
                                          Text(
                                            S.of(context).autoCleanTitle,
                                            style: const TextStyle(
                                              fontWeight: FontWeight.w500,
                                              color: Colors.blue,
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        S.of(context).autoCleanDescription,
                                        style: const TextStyle(fontSize: 12),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 当前缓存大小
                        SettingsSectionCard(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  S.of(context).currentCacheSize,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  formattedSize,
                                  style: TextStyle(
                                    fontSize: 24,
                                    fontWeight: FontWeight.bold,
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                LinearProgressIndicator(
                                  value: currentLimit > 0
                                      ? (currentSize /
                                              (currentLimit * 1024 * 1024))
                                          .clamp(0.0, 1.0)
                                      : 0.0,
                                  backgroundColor: Colors.grey[300],
                                  valueColor: AlwaysStoppedAnimation<Color>(
                                    currentSize > currentLimit * 1024 * 1024
                                        ? Colors.red
                                        : Theme.of(context).colorScheme.primary,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  S.of(context).cacheLimitLabelMB(currentLimit),
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.grey[600],
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        // O7: 存储分项展示（竖屏）
                        SettingsSectionCard(
                          color: Theme.of(context)
                              .colorScheme
                              .surfaceContainerHighest,
                          child: Padding(
                            padding: const EdgeInsets.all(16.0),
                            child: Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.start,
                              children: [
                                Text(
                                  S.of(context).storageBreakdown,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                                const SizedBox(height: 12),
                                _buildStorageBreakdownItem(
                                  context,
                                  icon: Icons.folder_outlined,
                                  label: S.of(context).storageCache,
                                  size: appCacheSize,
                                  color: Colors.blue,
                                ),
                                const SizedBox(height: 8),
                                _buildStorageBreakdownItem(
                                  context,
                                  icon: Icons.audiotrack_outlined,
                                  label: S.of(context).storageAudioCache,
                                  size: audioCacheSize,
                                  color: Colors.purple,
                                ),
                                const SizedBox(height: 8),
                                _buildStorageBreakdownItem(
                                  context,
                                  icon: Icons.image_outlined,
                                  label: S.of(context).storageImageCache,
                                  size: imageCacheSize,
                                  color: Colors.orange,
                                ),
                                const SizedBox(height: 8),
                                _buildStorageBreakdownItem(
                                  context,
                                  icon: Icons.download_outlined,
                                  label: S.of(context).storageDownloads,
                                  size: downloadSize,
                                  color: Colors.green,
                                ),
                                const Divider(height: 24),
                                _buildStorageBreakdownItem(
                                  context,
                                  icon: Icons.storage_outlined,
                                  label: S.of(context).storageTotal,
                                  size: currentSize + downloadSize,
                                  color: Theme.of(context).colorScheme.primary,
                                  isTotal: true,
                                ),
                              ],
                            ),
                          ),
                        ),
                        const SizedBox(height: 16),

                        Text(
                          S.of(context).cacheSizeLimit,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Column(
                          children: [
                            Slider(
                              value: currentSliderValue,
                              min: 0,
                              max: 100,
                              divisions: 20,
                              label: tempLimit < 1024
                                  ? '${tempLimit}MB'
                                  : '${(tempLimit / 1024).toStringAsFixed(1)}GB',
                              onChanged: (value) {
                                setDialogState(() {
                                  currentSliderValue = value;
                                  tempLimit = sliderValueToMB(value);
                                });
                              },
                              onChangeEnd: (value) async {
                                final finalLimit = sliderValueToMB(value);
                                await CacheService.setCacheSizeLimit(
                                    finalLimit);
                                if (mounted) {
                                  setState(() {}); // 刷新主界面
                                }
                              },
                            ),
                            Text(
                              tempLimit < 1024
                                  ? '${tempLimit}MB'
                                  : '${(tempLimit / 1024).toStringAsFixed(1)}GB',
                              style: TextStyle(
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),

                        // 说明文本
                        Container(
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.blue.withValues(alpha: 0.1),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Icon(Icons.info_outline,
                                      size: 16, color: Colors.blue),
                                  const SizedBox(width: 8),
                                  Text(
                                    S.of(context).autoCleanTitle,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w500,
                                      color: Colors.blue,
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              Text(
                                S.of(context).autoCleanDescriptionShort,
                                style: const TextStyle(fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
            ),
            actions: [
              if (!isLandscape)
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: Text(S.of(context).close),
                ),
              ElevatedButton.icon(
                onPressed: () => _confirmAndClearCache(context),
                icon: const Icon(Icons.delete_outline),
                label: Text(S.of(context).clearCache),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.red,
                  foregroundColor: Colors.white,
                ),
              ),
              TextButton.icon(
                onPressed: () => _clearTranslationCache(context),
                icon: const Icon(Icons.translate),
                label: Text(S.of(context).clearTranslationCache),
              ),
            ],
          ),
        );
      },
    );
  }

  // O7: 构建存储分项展示项
  Widget _buildStorageBreakdownItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required int size,
    required Color color,
    bool isTotal = false,
  }) {
    final formattedSize = _formatBytes(size);
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: TextStyle(
              fontSize: isTotal ? 14 : 13,
              fontWeight: isTotal ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ),
        Text(
          formattedSize,
          style: TextStyle(
            fontSize: isTotal ? 14 : 13,
            fontWeight: isTotal ? FontWeight.w600 : FontWeight.normal,
            color: isTotal ? Theme.of(context).colorScheme.primary : null,
          ),
        ),
      ],
    );
  }

  // 格式化字节大小
  String _formatBytes(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    } else if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(2)} KB';
    } else if (bytes < 1024 * 1024 * 1024) {
      return '${(bytes / (1024 * 1024)).toStringAsFixed(2)} MB';
    } else {
      return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
    }
  }
}

/// 导入进度值类，用于驱动进度对话框刷新。
class _ImportProgress {
  final int done;
  final int total;
  final int bytes;

  const _ImportProgress({
    this.done = 0,
    this.total = 0,
    this.bytes = 0,
  });
}
