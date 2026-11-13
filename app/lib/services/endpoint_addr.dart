import 'dart:convert';

/// 把 `EndpointAddr` JSON 拆成两个输入框各自的内容。
class EndpointAddrParts {
  const EndpointAddrParts({required this.id, required this.addrs});

  /// 纯 EndpointId（hex / base32），不带引号、不带 JSON。
  final String id;

  /// `addrs` 字段的 JSON 数组文本，例如 `[]` 或 `[{"Relay":"https://..."}]`。
  final String addrs;
}

/// 解析连接参数页要展示的初始值。
///
/// 解析失败时把整串原样放进 [EndpointAddrParts.id]、addrs 给 `[]`：
/// 用户以前在旧版手填过的内容不能因为换页面就丢掉。
EndpointAddrParts splitEndpointAddr(String addr) {
  final text = addr.trim();
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map && decoded['id'] is String) {
      final id = (decoded['id'] as String).trim();
      final rawAddrs = decoded['addrs'];
      return EndpointAddrParts(
        id: id,
        addrs: rawAddrs == null ? '[]' : jsonEncode(rawAddrs),
      );
    }
  } catch (_) {
    // 落到下面的兜底分支。
  }
  return EndpointAddrParts(id: text, addrs: '[]');
}

/// 组合两个输入框的内容，生成传给 Rust 的 `EndpointAddr` JSON。
///
/// 返回 `addr` 为 null 表示输入不合法，[error] 是可直接展示给用户的提示。
/// 这里只校验结构；EndpointId 本身的格式由 Rust 侧（iroh）校验。
({String? addr, String? error}) buildEndpointAddr({
  required String id,
  required String addrs,
}) {
  final cleanId = id.trim();
  if (cleanId.isEmpty) {
    return (addr: null, error: 'EndpointId 不能为空');
  }
  final rawAddrs = addrs.trim().isEmpty ? '[]' : addrs.trim();
  final Object? decoded;
  try {
    decoded = jsonDecode(rawAddrs);
  } catch (_) {
    return (addr: null, error: 'addrs 不是合法 JSON');
  }
  if (decoded is! List) {
    return (addr: null, error: 'addrs 必须是 JSON 数组，例如 []');
  }
  return (addr: jsonEncode({'id': cleanId, 'addrs': decoded}), error: null);
}

/// 界面上展示 EndpointId 时的打码形式：只留首尾各 4 位。
///
/// 占位符单独提示为「未配置」，避免让用户误以为已经配对成功。
String maskEndpointId(String id) {
  final text = id.trim();
  if (text.isEmpty || text == 'YOUR_ENDPOINT_ID') return '未配置';
  if (text.length <= 8) return '••••';
  return '${text.substring(0, 4)}••••${text.substring(text.length - 4)}';
}

/// 状态栏 / 错误提示统一过一遍，防止底层异常把完整地址或 token 回显到界面。
///
/// 替换顺序有讲究：先整串 EndpointAddr，再单独的 id，最后 token。
String scrubConnectionText(
  String text, {
  required String addr,
  String token = '',
}) {
  var out = text;
  final full = addr.trim();
  if (full.isNotEmpty) {
    out = out.replaceAll(full, '[地址已隐藏]');
  }
  final id = splitEndpointAddr(addr).id.trim();
  if (id.length >= 8) {
    out = out.replaceAll(id, '••••');
  }
  final cleanToken = token.trim();
  if (cleanToken.isNotEmpty) {
    out = out.replaceAll(cleanToken, '••••');
  }
  return out;
}
