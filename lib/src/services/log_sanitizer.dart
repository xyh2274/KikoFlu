/// 日志文案的凭据脱敏。
///
/// 为什么需要：日志现在会**滚动落盘**，并且可以被导出/分享出去排查问题。
/// 而下载与接口日志天然会带上「带 token 的 URL」「Cookie 头」这类内容
/// （例如 `开始网络下载: url=https://host/api/media/x?token=...`）。
/// 不脱敏就等于把凭据写进了明文文件。
///
/// 策略：**只遮蔽值、保留键名**。这样既不会泄露，又仍能看出
/// 「这里本来是配置了 token 的」，不影响定位问题。
///
/// 幂等：重复处理已脱敏的文本结果不变。
library;

/// 被遮蔽后显示的占位符。
const String kMaskedValue = '***';

/// 需要遮蔽的键名（按长度降序，避免短的先匹配掉长的前缀）。
const List<String> sensitiveLogKeys = [
  'authorization',
  'refresh_token',
  'client_secret',
  'server_cookie',
  'access_token',
  'set-cookie',
  'signature',
  'password',
  'id_token',
  'api_key',
  'api-key',
  'apikey',
  'passwd',
  'cookie',
  'secret',
  'token',
  'auth',
  'sig',
  'pwd',
];

final String _keyAlternation = (List<String>.from(sensitiveLogKeys)
      ..sort((a, b) => b.length.compareTo(a.length)))
    .map(RegExp.escape)
    .join('|');

/// `?token=xxx` / `&api_key=xxx` 形式的 URL query。
final RegExp _queryPattern = RegExp(
  '([?&](?:$_keyAlternation)=)([^&\\s#]*)',
  caseSensitive: false,
);

/// `token: xxx` / `token=xxx` / `"cookie": "xxx"` 形式的键值对。
///
/// 分组：`1` = 键两侧的引号（可选，靠 `\1` 反向引用保证成对）、`2` = 键、
/// `3` = 分隔符、`4` = 值。
///
/// 两个刻意的设计：
/// - **值里排除 `&` 和 `#`**：否则 `?token=abc&page=2` 会把 `&page=2`
///   一并当成值吃掉，把 URL 剩余参数抹掉（曾被测试逮到）。
/// - **允许键被引号包裹**：JSON 形态 `{"api_key": "..."}` 里键后面跟的是
///   闭合引号而不是 `:`，不加这条匹配不到，等于没脱敏。
final RegExp _pairPattern = RegExp(
  "(?<![\\w])([\"']?)($_keyAlternation)\\1(\\s*[:=]\\s*)"
  "(\"[^\"]*\"|'[^']*'|[^\\s,;)\\]}&#\"']+)",
  caseSensitive: false,
);

/// `Bearer xxx` / `Basic xxx` 形式的认证头。
final RegExp _schemePattern = RegExp(
  r'\b(bearer|basic)(\s+)([A-Za-z0-9._~+/=-]{4,})',
  caseSensitive: false,
);

/// 把日志文本里可能出现的凭据替换为 [kMaskedValue]。
///
/// 三条规则的**顺序有讲究**：必须先处理 `Bearer xxx` 这类 scheme。
/// 反例：`Authorization: Bearer abc` 若先跑键值对规则，值部分会在空格处
/// 停住、只吃掉 `Bearer`，真正的凭据 `abc` 反而留在明文里。
String sanitizeLogMessage(String input) {
  if (input.isEmpty) return input;
  var out = input.replaceAllMapped(
    _schemePattern,
    (m) => '${m.group(1)}${m.group(2)}$kMaskedValue',
  );
  out = out.replaceAllMapped(
    _queryPattern,
    (m) => '${m.group(1)}$kMaskedValue',
  );
  out = out.replaceAllMapped(_pairPattern, (m) {
    final value = m.group(4) ?? '';
    // 值本身带引号时把引号留在原地，保持 JSON / 配置文本的结构可读。
    var quote = '';
    if (value.length >= 2) {
      final first = value[0];
      if ((first == '"' || first == "'") && value.endsWith(first)) {
        quote = first;
      }
    }
    final keyQuotes = m.group(1) ?? '';
    return '$keyQuotes${m.group(2)}$keyQuotes${m.group(3)}'
        '$quote$kMaskedValue$quote';
  });
  return out;
}
