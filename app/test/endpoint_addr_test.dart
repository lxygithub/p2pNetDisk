import 'package:flutter_test/flutter_test.dart';

import 'package:netdisk_app/services/endpoint_addr.dart';

// 测试里只用假 ID；真实 EndpointId 绝不写进版本控制。
const _fakeId = 'aaaa1111bbbb2222cccc3333dddd4444';

void main() {
  group('splitEndpointAddr', () {
    test('n0 模式拆出 id 与空地址数组', () {
      final parts = splitEndpointAddr('{"id":"$_fakeId","addrs":[]}');
      expect(parts.id, _fakeId);
      expect(parts.addrs, '[]');
    });

    test('保留自建 relay 的地址数组', () {
      final parts = splitEndpointAddr(
        '{"id":"$_fakeId","addrs":[{"Relay":"https://relay.example.com:8443/"}]}',
      );
      expect(parts.id, _fakeId);
      expect(parts.addrs, '[{"Relay":"https://relay.example.com:8443/"}]');
    });

    test('缺少 addrs 字段时按 [] 处理', () {
      final parts = splitEndpointAddr('{"id":"$_fakeId"}');
      expect(parts.addrs, '[]');
    });

    test('非法 JSON 不丢内容，整串放进 id 供用户修正', () {
      final parts = splitEndpointAddr('{"id":"broken');
      expect(parts.id, '{"id":"broken');
      expect(parts.addrs, '[]');
    });
  });

  group('buildEndpointAddr', () {
    test('两个输入框组合成合法 EndpointAddr', () {
      final result = buildEndpointAddr(id: _fakeId, addrs: '[]');
      expect(result.error, isNull);
      expect(result.addr, '{"id":"$_fakeId","addrs":[]}');
    });

    test('addrs 留空等同于 []', () {
      final result = buildEndpointAddr(id: _fakeId, addrs: '   ');
      expect(result.addr, '{"id":"$_fakeId","addrs":[]}');
    });

    test('自建 relay 地址原样保留', () {
      final result = buildEndpointAddr(
        id: _fakeId,
        addrs: '[{"Relay":"https://relay.example.com:8443/"}]',
      );
      expect(result.error, isNull);
      expect(
        result.addr,
        '{"id":"$_fakeId","addrs":[{"Relay":"https://relay.example.com:8443/"}]}',
      );
    });

    test('id 为空时拒绝', () {
      final result = buildEndpointAddr(id: '  ', addrs: '[]');
      expect(result.addr, isNull);
      expect(result.error, isNotNull);
    });

    test('addrs 不是数组时拒绝', () {
      final result = buildEndpointAddr(id: _fakeId, addrs: '{}');
      expect(result.addr, isNull);
      expect(result.error, contains('数组'));
    });

    test('addrs 不是合法 JSON 时拒绝', () {
      final result = buildEndpointAddr(id: _fakeId, addrs: '[oops');
      expect(result.addr, isNull);
      expect(result.error, contains('JSON'));
    });

    test('拆分与组合可以往返', () {
      const addr =
          '{"id":"$_fakeId","addrs":[{"Relay":"https://relay.example.com:8443/"}]}';
      final parts = splitEndpointAddr(addr);
      final result = buildEndpointAddr(id: parts.id, addrs: parts.addrs);
      expect(result.addr, addr);
    });
  });

  group('maskEndpointId', () {
    test('只保留首尾各 4 位', () {
      expect(maskEndpointId(_fakeId), 'aaaa••••4444');
    });

    test('占位符提示为未配置', () {
      expect(maskEndpointId('YOUR_ENDPOINT_ID'), '未配置');
      expect(maskEndpointId(''), '未配置');
    });

    test('过短的值完全打码', () {
      expect(maskEndpointId('abc'), '••••');
    });
  });

  group('scrubConnectionText', () {
    const addr = '{"id":"$_fakeId","addrs":[]}';
    const token = 'super-secret-token';

    test('完整 EndpointAddr 不回显', () {
      final out = scrubConnectionText('连接失败: $addr', addr: addr);
      expect(out, contains('[地址已隐藏]'));
      expect(out, isNot(contains(_fakeId)));
    });

    test('单独出现的 id 与 token 都被打码', () {
      final out = scrubConnectionText(
        'bad id $_fakeId with token $token',
        addr: addr,
        token: token,
      );
      expect(out, isNot(contains(_fakeId)));
      expect(out, isNot(contains(token)));
      expect(out, contains('••••'));
    });

    test('普通文本不受影响', () {
      expect(scrubConnectionText('正在拉取列表…', addr: addr), '正在拉取列表…');
    });
  });
}
