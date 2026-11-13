// 验证「后台 isolate + FFI」这条真实路径（UI 用的就是它）。
//
// 与 ffi_smoke.dart 的区别：那个脚本在主 isolate 里同步调用 C ABI，
// 用来验证 FFI 本身；这个脚本走 NetdiskWorker，验证 isolate 转发、
// 超时、重试是否正确 —— 也就是 App 里真正执行的链路。
//
// 用法（在 app/ 目录下）：
//   NETDISK_FFI_DLL=<动态库绝对路径> \
//   NETDISK_RELAY_TOKEN=<token> \
//   NETDISK_SERVER_ADDR=<EndpointAddr JSON> \
//   dart run tool/worker_smoke.dart

import 'dart:io';

import 'package:netdisk_app/src/netdisk_worker.dart';

Future<void> main() async {
  final dll = Platform.environment['NETDISK_FFI_DLL'];
  final token = Platform.environment['NETDISK_RELAY_TOKEN'] ?? '';
  final addr = Platform.environment['NETDISK_SERVER_ADDR'] ?? '';
  final relay = Platform.environment['NETDISK_RELAY_URL'] ??
      'https://relay.example.com:8443';

  if (addr.isEmpty) {
    stderr.writeln('NETDISK_SERVER_ADDR is required');
    exit(2);
  }

  final worker = NetdiskWorker();
  try {
    final sw = Stopwatch()..start();
    await worker.start(libraryPath: dll);
    stdout.writeln('start    : OK (${sw.elapsedMilliseconds} ms)');

    sw.reset();
    await worker.init(relay, token, addr);
    stdout.writeln('init     : OK (${sw.elapsedMilliseconds} ms) '
        'running=${worker.isRunning}');

    sw.reset();
    final entries = await worker.list(
      onAttempt: (n) => stdout.writeln('list attempt $n'),
    );
    stdout.writeln('list     : OK (${sw.elapsedMilliseconds} ms) '
        'count=${entries.length}');
    for (final e in entries) {
      stdout.writeln('  - ${e.path} (${e.size} bytes)');
    }
    stdout.writeln('WORKER_SMOKE_OK');
  } finally {
    worker.dispose();
  }
}
