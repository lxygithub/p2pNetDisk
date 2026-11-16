import 'package:flutter_test/flutter_test.dart';
import 'package:netdisk_app/services/path_utils.dart';
import 'package:path/path.dart' as p;

void main() {
  group('localRelPath', () {
    test('空 remoteBase 时原样返回', () {
      expect(localRelPath('photos/2026/a.jpg'), 'photos/2026/a.jpg');
    });

    test('去掉前缀（带结尾斜杠）', () {
      expect(
        localRelPath('photos/2026/a.jpg', remoteBase: 'photos/'),
        '2026/a.jpg',
      );
    });

    test('前缀缺少结尾斜杠也能识别', () {
      expect(
        localRelPath('photos/2026/a.jpg', remoteBase: 'photos'),
        '2026/a.jpg',
      );
    });

    test('目录自身映射成空串', () {
      expect(localRelPath('photos', remoteBase: 'photos/'), '');
      expect(localRelPath('photos/', remoteBase: 'photos'), '');
      // 子目录相对父目录，保留中间那一段（目录下载时用它建本地目录）。
      expect(localRelPath('photos/2026', remoteBase: 'photos/'), '2026');
      expect(localRelPath('photos/2026/', remoteBase: 'photos'), '2026/');
    });

    test('不在前缀内时保留完整路径，避免写到根目录', () {
      expect(localRelPath('videos/a.mp4', remoteBase: 'photos/'), 'videos/a.mp4');
    });

    test('反斜杠会被规范化', () {
      expect(
        localRelPath(r'photos\2026\a.jpg', remoteBase: r'photos\'),
        '2026/a.jpg',
      );
    });
  });

  group('entriesUnder', () {
    final all = <({String path, int size, bool isDir})>[
      (path: 'photos', size: 0, isDir: true),
      (path: 'photos/2026', size: 0, isDir: true),
      (path: 'photos/2026/a.jpg', size: 10, isDir: false),
      (path: 'photos/b.png', size: 20, isDir: false),
      (path: 'photos2/c.jpg', size: 30, isDir: false),
      (path: 'videos/d.mp4', size: 40, isDir: false),
    ];

    test('包含目录自身与全部子项', () {
      final got = entriesUnder(all, 'photos/').map((e) => e.path).toList();
      expect(got, [
        'photos',
        'photos/2026',
        'photos/2026/a.jpg',
        'photos/b.png',
      ]);
    });

    test('不会误匹配同名前缀（photos 与 photos2）', () {
      final got = entriesUnder(all, 'photos').map((e) => e.path).toList();
      expect(got, isNot(contains('photos2/c.jpg')));
    });

    test('根目录返回全部', () {
      expect(entriesUnder(all, '').length, all.length);
      expect(entriesUnder(all, '/').length, all.length);
    });

    test('目录不存在时返回空', () {
      expect(entriesUnder(all, 'nope').length, 0);
    });
  });

  group('上传过滤', () {
    test('跳过隐藏项、密钥与临时文件', () {
      expect(shouldSkipUploadName('.git'), isTrue);
      expect(shouldSkipUploadName('.nomedia'), isTrue);
      expect(shouldSkipUploadName('secret.key'), isTrue);
      expect(shouldSkipUploadName('a.txt.netdisk-tmp'), isTrue);
      expect(shouldSkipUploadName(''), isTrue);
      expect(shouldSkipUploadName('a.txt'), isFalse);
    });

    test('路径中任意一段是隐藏项就整体跳过', () {
      expect(shouldSkipUploadPath('a/.git/config'), isTrue);
      expect(shouldSkipUploadPath('.cache/x.bin'), isTrue);
      expect(shouldSkipUploadPath('a/b/c.txt'), isFalse);
    });
  });

  group('joinUnder', () {
    test('拼接并过滤空段与穿越段', () {
      expect(joinUnder('/root', 'a/b.txt'), p.join('/root', 'a', 'b.txt'));
      expect(joinUnder('/root', '//a///b.txt'), p.join('/root', 'a', 'b.txt'));
      expect(joinUnder('/root', '../etc/passwd'), p.join('/root', 'etc', 'passwd'));
      expect(joinUnder('/root', './a.txt'), p.join('/root', 'a.txt'));
    });

    test('空相对路径返回根本身', () {
      expect(joinUnder('/root', ''), '/root');
      expect(joinUnder('/root', '/'), '/root');
    });
  });

  group('parentOf / dirName', () {
    test('父目录以斜杠结尾，根目录返回空串', () {
      expect(parentOf('photos/2026/'), 'photos/');
      expect(parentOf('photos/2026'), 'photos/');
      expect(parentOf('photos/'), '');
      expect(parentOf('photos'), '');
    });

    test('取最后一段名称', () {
      expect(dirName('photos/2026/'), '2026');
      expect(dirName('photos/2026'), '2026');
      expect(dirName('photos'), 'photos');
      expect(dirName(''), '');
    });
  });
}
