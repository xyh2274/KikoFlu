import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/widgets/responsive_dialog.dart';

/// 验证共享弹层（showResponsiveBottomSheet）在存在系统导航栏时，
/// 内容底部是否避让了系统栏高度——真机上"确认/取消"被安卓导航栏遮住即断言失败。
void main() {
  const screenHeight = 800.0;
  const navBarHeight = 48.0;

  void simulateThreeButtonNav(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, screenHeight);
    tester.view.devicePixelRatio = 1.0;
    tester.view.padding = const FakeViewPadding(bottom: navBarHeight);
    tester.view.viewPadding = const FakeViewPadding(bottom: navBarHeight);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetPadding();
      tester.view.resetViewPadding();
    });
  }

  Widget host(Widget Function(BuildContext) sheetBuilder) {
    return MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showResponsiveBottomSheet<void>(
                context: context,
                builder: sheetBuilder,
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('弹层内容避让系统导航栏', (tester) async {
    simulateThreeButtonNav(tester);

    await tester.pumpWidget(host(
      (_) => const SizedBox(
        key: ValueKey('sheet-body'),
        height: 100,
        width: double.infinity,
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final bodyBottom =
        tester.getRect(find.byKey(const ValueKey('sheet-body'))).bottom;
    expect(
      screenHeight - bodyBottom,
      greaterThanOrEqualTo(navBarHeight - 0.5),
      reason: '弹层内容底部距屏幕底部应至少留出系统导航栏高度',
    );
  });

  testWidgets('弹层底部动作条（取消/确认）避让系统导航栏', (tester) async {
    simulateThreeButtonNav(tester);

    await tester.pumpWidget(host(
      (context) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const SizedBox(height: 200),
          BottomSheetActionBar(
            key: const ValueKey('action-bar'),
            secondaryLabel: '取消',
            onSecondaryPressed: () => Navigator.of(context).pop(),
            primaryLabel: '下载',
            onPrimaryPressed: () {},
          ),
        ],
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    final barBottom =
        tester.getRect(find.byKey(const ValueKey('action-bar'))).bottom;
    expect(
      screenHeight - barBottom,
      greaterThanOrEqualTo(navBarHeight - 0.5),
      reason: '动作条底部距屏幕底部应至少留出系统导航栏高度',
    );
  });
}
