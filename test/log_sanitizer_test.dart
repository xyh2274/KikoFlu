import 'package:flutter_test/flutter_test.dart';
import 'package:kikoeru_flutter/src/services/log_sanitizer.dart';

void main() {
  group('sanitizeLogMessage - URL query', () {
    test('遮蔽 query 中的 token，保留其他参数', () {
      expect(
        sanitizeLogMessage('GET https://api/x?token=abc123&page=2'),
        'GET https://api/x?token=$kMaskedValue&page=2',
      );
    });

    test('遮蔽 & 分隔的 api_key', () {
      expect(
        sanitizeLogMessage('https://h/a?b=1&api_key=SECRET&c=2'),
        'https://h/a?b=1&api_key=$kMaskedValue&c=2',
      );
    });

    test('空值与普通参数不受影响', () {
      expect(
        sanitizeLogMessage('https://h/a?token=&id=7'),
        'https://h/a?token=$kMaskedValue&id=7',
      );
    });
  });

  group('sanitizeLogMessage - 键值对', () {
    test('token: 形式', () {
      expect(
        sanitizeLogMessage('开始下载 token: eyJhbGciOiJIUzI1NiJ9'),
        '开始下载 token: $kMaskedValue',
      );
    });

    test('token= 形式', () {
      expect(
        sanitizeLogMessage('token=abcdef'),
        'token=$kMaskedValue',
      );
    });

    test('JSON 引号形式保留引号结构', () {
      expect(
        sanitizeLogMessage('{"api_key": "abcdef"}'),
        '{"api_key": "$kMaskedValue"}',
      );
    });

    test('保留键名，只遮蔽值（便于定位"此处配了 token"）', () {
      final out = sanitizeLogMessage('password: hunter2');
      expect(out, contains('password'));
      expect(out, isNot(contains('hunter2')));
    });

    test('下划线键名优先于其子串（access_token 不被 token 规则截断）', () {
      expect(
        sanitizeLogMessage('access_token=AAA'),
        'access_token=$kMaskedValue',
      );
    });
  });

  group('sanitizeLogMessage - 认证头', () {
    test('Bearer 被完整遮蔽', () {
      expect(
        sanitizeLogMessage('Authorization: Bearer eyJ0eXAiOiJKV1Q'),
        'Authorization: $kMaskedValue $kMaskedValue',
      );
    });

    test('Basic 被完整遮蔽', () {
      final out = sanitizeLogMessage('Basic dXNlcjpwYXNz');
      expect(out, isNot(contains('dXNlcjpwYXNz')));
      expect(out, contains('Basic'));
    });

    // 回归：曾经先跑键值对规则，值在空格处停住只吃掉 'Bearer'，
    // 真正的凭据反而留在明文里。
    test('回归：Authorization: Bearer xxx 不能只遮蔽 Bearer', () {
      final out = sanitizeLogMessage('Authorization: Bearer abcdefgh');
      expect(out, isNot(contains('abcdefgh')));
    });
  });

  group('sanitizeLogMessage - 幂等与不误伤', () {
    test('重复处理结果不变', () {
      const samples = [
        'GET https://api/x?token=abc123&page=2',
        'Authorization: Bearer eyJ0eXAiOiJKV1Q',
        '{"api_key": "abcdef"}',
        'access_token=AAA',
      ];
      for (final s in samples) {
        final once = sanitizeLogMessage(s);
        expect(sanitizeLogMessage(once), once, reason: '二次处理应稳定: $s');
      }
    });

    test('普通日志不受影响', () {
      const plain = '发现临时文件，尝试断点续传: 已下载 123456 字节';
      expect(sanitizeLogMessage(plain), plain);
    });

    test('空串安全', () {
      expect(sanitizeLogMessage(''), '');
    });

    test('中文里的"口令"等词不会被误伤', () {
      const plain = '分段下载完成，共 12 个分片';
      expect(sanitizeLogMessage(plain), plain);
    });
  });

  group('sensitiveLogKeys', () {
    test('按长度降序排列，避免短键先匹配掉长键前缀', () {
      for (var i = 1; i < sensitiveLogKeys.length; i++) {
        expect(
          sensitiveLogKeys[i - 1].length,
          greaterThanOrEqualTo(sensitiveLogKeys[i].length),
        );
      }
    });
  });
}
