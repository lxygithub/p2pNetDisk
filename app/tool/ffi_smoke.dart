// 纯 Dart 冒烟测试：不启动 Flutter UI，直接加载 Rust 动态库验证 C ABI。
//
// 用法（在 app/ 目录下，设置以下环境变量后执行 dart run tool/ffi_smoke.dart）：
//   NETDISK_FFI_DLL       动态库绝对路径
//   NETDISK_RELAY_TOKEN   relay token
//   NETDISK_SERVER_ADDR   EndpointAddr JSON
//
// 覆盖 ping / list / put / get，并逐字节校验上传下载内容。

import 'dart:io';

import 'package:netdisk_app/src/netdisk_ffi.dart';

bool _sameBytes(List<int> a, List<int> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

void main() {
  final token = Platform.environment['NETDISK_RELAY_TOKEN'] ?? '';
  final addr = Platform.environment['NETDISK_SERVER_ADDR'] ?? '';
  final dll = Platform.environment['NETDISK_FFI_DLL'];
  if (token.isEmpty || addr.isEmpty) {
    stderr.writeln('set NETDISK_RELAY_TOKEN and NETDISK_SERVER_ADDR');
    exit(2);
  }

  final client = NetdiskClient(libraryPath: dll);
  final err = client.connect(
    Platform.environment['NETDISK_RELAY_URL'] ??
        'https://relay.example.com:8443',
    token,
    addr,
  );
  if (err != null) {
    stderr.writeln('init failed: $err');
    exit(1);
  }

  final ping = client.ping();
  stdout.writeln('ping: $ping');
  if (ping['Error'] != null) {
    client.close();
    exit(1);
  }

  final dir = Directory.systemTemp.createTempSync('netdisk_ffi_smoke_');
  final src = File('${dir.path}/upload.bin');
  final dst = File('${dir.path}/download.bin');
  final payload = List<int>.generate(64 * 1024, (i) => i % 251);
  src.writeAsBytesSync(payload);

  const remote = 'e2e/ffi_smoke.bin';
  final put = client.put(remote, src.path);
  stdout.writeln('put: $put');
  if (put['Error'] != null) {
    client.close();
    dir.deleteSync(recursive: true);
    exit(1);
  }

  final get = client.get(remote, dst.path);
  stdout.writeln('get: $get');
  if (get['Error'] != null || !_sameBytes(payload, dst.readAsBytesSync())) {
    stderr.writeln('download content mismatch');
    client.close();
    dir.deleteSync(recursive: true);
    exit(1);
  }

  final list = client.listFiles();
  stdout.writeln('list: ${parseEntries(list)}');
  client.close();
  dir.deleteSync(recursive: true);
  stdout.writeln('FFI_SMOKE_OK');
}
