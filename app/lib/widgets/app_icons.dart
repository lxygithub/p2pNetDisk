// ignore_for_file: constant_identifier_names

import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 自绘图标集。
///
/// 全部用 [CustomPainter] 以 24×24 画布手绘，统一 1.7px 圆头描边，
/// 不依赖 Material Icons 字体，也不引入任何第三方包。
/// 风格：细线、圆角、克制——和毛玻璃底色保持一致。
enum AppIcon {
  add,
  arrowUp,
  audio,
  battery,
  bolt,
  brokenImage,
  chevronRight,
  clean,
  close,
  cloudOff,
  cloud,
  copy,
  createFolder,
  delete,
  deleteSweep,
  document,
  deselect,
  download,
  move,
  rename,
  folderUpload,
  error,
  folder,
  folderOpen,
  folderSpecial,
  archive,
  history,
  image,
  link,
  more,
  video,
  pause,
  pauseCircle,
  pdf,
  play,
  playCircle,
  refresh,
  restore,
  search,
  selectAll,
  settings,
  swap,
  tune,
  upload,
  top,
  visibility,
  visibilityOff,
}

/// 与 Material Icons 同名的语义常量，方便把 `Icons.xxx` 整体替换成 `AppIcons.xxx`。
abstract final class AppIcons {
  static const add = AppIcon.add;
  static const arrow_upward = AppIcon.arrowUp;
  static const audiotrack_outlined = AppIcon.audio;
  static const battery_saver_outlined = AppIcon.battery;
  static const bolt = AppIcon.bolt;
  static const broken_image_outlined = AppIcon.brokenImage;
  static const chevron_right = AppIcon.chevronRight;
  static const cleaning_services_outlined = AppIcon.clean;
  static const close = AppIcon.close;
  static const cloud_off = AppIcon.cloudOff;
  static const cloud_queue = AppIcon.cloud;
  static const copy_outlined = AppIcon.copy;
  static const create_new_folder_outlined = AppIcon.createFolder;
  static const delete_outline = AppIcon.delete;
  static const delete_sweep_outlined = AppIcon.deleteSweep;
  static const description_outlined = AppIcon.document;
  static const insert_drive_file_outlined = AppIcon.document;
  static const deselect = AppIcon.deselect;
  static const download = AppIcon.download;
  static const download_outlined = AppIcon.download;
  static const drive_file_move_outline = AppIcon.move;
  static const drive_file_rename_outline = AppIcon.rename;
  static const drive_folder_upload = AppIcon.folderUpload;
  static const error_outline = AppIcon.error;
  static const folder = AppIcon.folder;
  static const folder_rounded = AppIcon.folder;
  static const folder_outlined = AppIcon.folder;
  static const folder_open = AppIcon.folderOpen;
  static const folder_special = AppIcon.folderSpecial;
  static const folder_zip_outlined = AppIcon.archive;
  static const history = AppIcon.history;
  static const image_outlined = AppIcon.image;
  static const link = AppIcon.link;
  static const more_vert = AppIcon.more;
  static const movie_outlined = AppIcon.video;
  static const pause = AppIcon.pause;
  static const pause_circle_outline = AppIcon.pauseCircle;
  static const picture_as_pdf_outlined = AppIcon.pdf;
  static const play_arrow = AppIcon.play;
  static const play_circle_outline = AppIcon.playCircle;
  static const refresh = AppIcon.refresh;
  static const restore = AppIcon.restore;
  static const search = AppIcon.search;
  static const select_all = AppIcon.selectAll;
  static const settings = AppIcon.settings;
  static const settings_outlined = AppIcon.settings;
  static const swap_vert = AppIcon.swap;
  static const tune = AppIcon.tune;
  static const upload_file = AppIcon.upload;
  static const vertical_align_top = AppIcon.top;
  static const visibility = AppIcon.visibility;
  static const visibility_off = AppIcon.visibilityOff;
  static const visibility_off_outlined = AppIcon.visibilityOff;
}

/// 统一入口：[icon] 语义名，[size] 边长，[color] 描边色，[stroke] 线宽。
class AppIconView extends StatelessWidget {
  const AppIconView(
    this.icon, {
    super.key,
    this.size = 24,
    this.color,
    this.stroke = 1.7,
  });

  final AppIcon icon;
  final double size;
  final Color? color;
  final double stroke;

  @override
  Widget build(BuildContext context) {
    final resolved =
        color ??
        IconTheme.of(context).color ??
        Theme.of(context).colorScheme.onSurface;
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _IconPainter(icon, resolved, stroke)),
    );
  }
}

class _IconPainter extends CustomPainter {
  const _IconPainter(this.icon, this.color, this.stroke);

  final AppIcon icon;
  final Color color;
  final double stroke;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.save();
    canvas.scale(size.width / 24, size.height / 24);
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    _draw(canvas, p, icon);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _IconPainter old) =>
      old.icon != icon || old.color != color || old.stroke != stroke;
}

void _line(Canvas c, Paint p, double x1, double y1, double x2, double y2) =>
    c.drawLine(Offset(x1, y1), Offset(x2, y2), p);

void _poly(Canvas c, Paint p, List<double> pts, {bool close = false}) {
  final path = Path()..moveTo(pts[0], pts[1]);
  for (var i = 2; i < pts.length; i += 2) {
    path.lineTo(pts[i], pts[i + 1]);
  }
  if (close) path.close();
  c.drawPath(path, p);
}

void _rrect(
  Canvas c,
  Paint p,
  double x,
  double y,
  double w,
  double h,
  double r,
) {
  final rr = RRect.fromLTRBAndCorners(
    x,
    y,
    x + w,
    y + h,
    topLeft: Radius.circular(r),
    topRight: Radius.circular(r),
    bottomLeft: Radius.circular(r),
    bottomRight: Radius.circular(r),
  );
  c.drawRRect(rr, p);
}

void _circle(Canvas c, Paint p, double x, double y, double r) =>
    c.drawCircle(Offset(x, y), r, p);

void _arc(
  Canvas c,
  Paint p,
  double x,
  double y,
  double r,
  double start,
  double sweep,
) => c.drawArc(
  Rect.fromCircle(center: Offset(x, y), radius: r),
  start,
  sweep,
  false,
  p,
);

void _draw(Canvas c, Paint p, AppIcon icon) {
  switch (icon) {
    case AppIcon.add:
      _line(c, p, 12, 5, 12, 19);
      _line(c, p, 5, 12, 19, 12);
    case AppIcon.close:
      _line(c, p, 6, 6, 18, 18);
      _line(c, p, 18, 6, 6, 18);
    case AppIcon.chevronRight:
      _poly(c, p, const [9, 5, 16, 12, 9, 19]);
    case AppIcon.arrowUp:
      _line(c, p, 12, 20, 12, 5);
      _poly(c, p, const [6, 11, 12, 5, 18, 11]);
    case AppIcon.top:
      _line(c, p, 4, 4, 20, 4);
      _line(c, p, 12, 20, 12, 8);
      _poly(c, p, const [7, 13, 12, 8, 17, 13]);
    case AppIcon.more:
      for (final y in [6.0, 12.0, 18.0]) {
        _circle(c, p, 12, y, 1.15);
      }
    case AppIcon.search:
      _circle(c, p, 10.5, 10.5, 6.5);
      _line(c, p, 15.5, 15.5, 20, 20);
    case AppIcon.settings:
      _circle(c, p, 12, 12, 3.2);
      for (var i = 0; i < 8; i++) {
        final a = i * math.pi / 4;
        final dx = math.cos(a);
        final dy = math.sin(a);
        _line(c, p, 12 + 4.3 * dx, 12 + 4.3 * dy, 12 + 6.4 * dx, 12 + 6.4 * dy);
      }
    case AppIcon.refresh:
      _arc(c, p, 12, 12, 7.5, -1.2, 4.4);
      _poly(c, p, const [17.5, 2.5, 19.5, 6.5, 15.5, 7]);
      _arc(c, p, 12, 12, 7.5, 2.0, 4.4);
      _poly(c, p, const [6.5, 21.5, 4.5, 17.5, 8.5, 17]);
    case AppIcon.restore:
      _arc(c, p, 12, 12, 7.5, 3.5, 4.7);
      _poly(c, p, const [6.8, 18.2, 4.7, 14.2, 8.7, 13.8]);
      _line(c, p, 12, 8, 12, 12);
      _line(c, p, 12, 12, 15, 14);
    case AppIcon.history:
      _circle(c, p, 12, 12, 8);
      _line(c, p, 12, 7, 12, 12);
      _line(c, p, 12, 12, 15.5, 14);
    case AppIcon.tune:
      _line(c, p, 4, 7, 20, 7);
      _line(c, p, 4, 17, 20, 17);
      _circle(c, p, 9, 7, 2);
      _circle(c, p, 16, 17, 2);
    case AppIcon.swap:
      _line(c, p, 7, 20, 7, 4);
      _poly(c, p, const [3.5, 7.5, 7, 4, 10.5, 7.5]);
      _line(c, p, 17, 4, 17, 20);
      _poly(c, p, const [13.5, 16.5, 17, 20, 20.5, 16.5]);
    case AppIcon.selectAll:
      _rrect(c, p, 4, 4, 16, 16, 2.5);
      _poly(c, p, const [8, 12, 11, 15, 16.5, 9]);
    case AppIcon.deselect:
      _rrect(c, p, 4, 4, 16, 16, 2.5);
      _line(c, p, 9, 12, 15, 12);
    case AppIcon.visibility:
      _poly(c, p, const [
        2.5,
        12,
        6,
        7.5,
        12,
        5,
        18,
        7.5,
        21.5,
        12,
        18,
        16.5,
        12,
        19,
        6,
        16.5,
      ], close: true);
      _circle(c, p, 12, 12, 2.6);
    case AppIcon.visibilityOff:
      _poly(c, p, const [
        4,
        9,
        2.5,
        12,
        6,
        16,
        12,
        19,
        18,
        16,
        21.5,
        12,
        18,
        7.5,
        12,
        5,
        6,
        7.5,
      ], close: true);
      _line(c, p, 3, 21, 21, 3);
    case AppIcon.folder:
    case AppIcon.folderOpen:
      _poly(c, p, const [
        3,
        7,
        3,
        6,
        5,
        4,
        10,
        4,
        12,
        6.5,
        20,
        6.5,
        21,
        8,
        21,
        18.5,
        19.5,
        20,
        4.5,
        20,
        3,
        18.5,
      ], close: true);
      if (icon == AppIcon.folderOpen) _line(c, p, 3, 11, 21, 11);
    case AppIcon.folderSpecial:
      _poly(c, p, const [
        3,
        7,
        3,
        6,
        5,
        4,
        10,
        4,
        12,
        6.5,
        20,
        6.5,
        21,
        8,
        21,
        18.5,
        19.5,
        20,
        4.5,
        20,
        3,
        18.5,
      ], close: true);
      _poly(c, p, const [
        12,
        10,
        12.9,
        12.8,
        15.8,
        13.6,
        13.3,
        15.6,
        13.9,
        18.5,
        12,
        17.1,
        10.1,
        18.5,
        10.7,
        15.6,
        8.2,
        13.6,
        11.1,
        12.8,
      ], close: true);
    case AppIcon.createFolder:
      _poly(c, p, const [
        3,
        7,
        3,
        6,
        5,
        4,
        10,
        4,
        12,
        6.5,
        20,
        6.5,
        21,
        8,
        21,
        18.5,
        19.5,
        20,
        4.5,
        20,
        3,
        18.5,
      ], close: true);
      _line(c, p, 12, 11, 12, 17);
      _line(c, p, 9, 14, 15, 14);
    case AppIcon.folderUpload:
      _poly(c, p, const [
        3,
        7,
        3,
        6,
        5,
        4,
        10,
        4,
        12,
        6.5,
        20,
        6.5,
        21,
        8,
        21,
        18.5,
        19.5,
        20,
        4.5,
        20,
        3,
        18.5,
      ], close: true);
      _line(c, p, 12, 17, 12, 10);
      _poly(c, p, const [9, 13, 12, 10, 15, 13]);
    case AppIcon.archive:
      _rrect(c, p, 3, 4, 18, 4, 1.5);
      _poly(c, p, const [5, 8, 5, 19, 19, 19, 19, 8]);
      _line(c, p, 10, 12, 14, 12);
    case AppIcon.document:
    case AppIcon.pdf:
    case AppIcon.brokenImage:
      _poly(c, p, const [
        6,
        2.5,
        14.5,
        2.5,
        19,
        7,
        19,
        20.5,
        17.5,
        21.5,
        5,
        21.5,
        4,
        20,
        4,
        4,
      ], close: true);
      _poly(c, p, const [14.5, 2.5, 14.5, 7, 19, 7]);
      if (icon == AppIcon.document) {
        _line(c, p, 8, 12, 16, 12);
        _line(c, p, 8, 16, 14, 16);
      } else if (icon == AppIcon.pdf) {
        _line(c, p, 8, 12, 16, 12);
        _line(c, p, 8, 16, 13, 16);
      }
    case AppIcon.image:
      _rrect(c, p, 3.5, 4, 17, 16, 2.5);
      _circle(c, p, 8.5, 9, 1.5);
      _poly(c, p, const [4, 18, 9, 13, 13, 17, 16, 14, 20, 18]);
    case AppIcon.video:
      _rrect(c, p, 3, 5, 18, 14, 2.5);
      _poly(c, p, const [10, 9, 15, 12, 10, 15], close: true);
      _line(c, p, 7, 5, 7, 19);
      _line(c, p, 17, 5, 17, 19);
    case AppIcon.audio:
      _poly(c, p, const [9, 18, 9, 6, 18, 4, 18, 16]);
      _circle(c, p, 6.5, 18, 2.5);
      _circle(c, p, 15.5, 16, 2.5);
    case AppIcon.battery:
      _rrect(c, p, 3, 7, 17, 10, 2);
      _line(c, p, 21, 10.5, 21, 13.5);
      _poly(c, p, const [
        12.5,
        9,
        10,
        13,
        13,
        13,
        11,
        16,
        15,
        11.5,
        12,
        11.5,
      ], close: true);
    case AppIcon.bolt:
      _poly(c, p, const [
        13,
        2,
        5,
        13,
        11,
        13,
        9,
        22,
        19,
        10,
        13,
        10,
        16,
        2,
      ], close: true);
    case AppIcon.error:
      _circle(c, p, 12, 12, 8.5);
      _line(c, p, 12, 8, 12, 13.5);
      _circle(c, p, 12, 16.5, 0.9);
    case AppIcon.cloudOff:
      _poly(c, p, const [
        6,
        18,
        4.5,
        18,
        3.5,
        17,
        3.5,
        15,
        5,
        13.5,
        7,
        13.5,
        8.5,
        10,
        12,
        8.5,
        15.5,
        10,
        17,
        13.5,
        19,
        13.5,
        20.5,
        15,
        20.5,
        17,
        19,
        18,
        6,
        18,
      ]);
      _line(c, p, 3, 21, 21, 3);
    case AppIcon.cloud:
      _poly(c, p, const [
        6,
        18,
        4.5,
        18,
        3.5,
        17,
        3.5,
        15,
        5,
        13.5,
        7,
        13.5,
        8.5,
        10,
        12,
        8.5,
        15.5,
        10,
        17,
        13.5,
        19,
        13.5,
        20.5,
        15,
        20.5,
        17,
        19,
        18,
        6,
        18,
      ], close: true);
    case AppIcon.clean:
      _poly(c, p, const [
        19,
        4,
        20.5,
        5.5,
        14,
        12,
        12.5,
        10.5,
        19,
        4,
      ], close: true);
      _poly(c, p, const [12.5, 10.5, 6, 17, 4, 21, 8, 19, 14.5, 12.5]);
      _line(c, p, 4, 4, 4.5, 6);
      _line(c, p, 2, 6, 4, 6.5);
    case AppIcon.deleteSweep:
      _poly(c, p, const [4, 7, 20, 7]);
      _poly(c, p, const [9, 7, 9, 4, 15, 4, 15, 7]);
      _poly(c, p, const [6, 7, 7, 20, 17, 20, 18, 7]);
      _line(c, p, 10, 11, 10, 17);
      _line(c, p, 14, 11, 14, 17);
    case AppIcon.delete:
      _poly(c, p, const [5, 7, 19, 7]);
      _poly(c, p, const [9, 7, 9, 4, 15, 4, 15, 7]);
      _poly(c, p, const [6.5, 7, 7.5, 20, 16.5, 20, 17.5, 7]);
      _line(c, p, 10, 10.5, 10, 16.5);
      _line(c, p, 14, 10.5, 14, 16.5);
    case AppIcon.copy:
      _rrect(c, p, 8, 8, 12, 12, 2);
      _poly(c, p, const [16, 8, 16, 5, 14, 3.5, 5, 3.5, 4, 5, 4, 16, 8, 16]);
    case AppIcon.rename:
      _poly(c, p, const [
        4,
        20,
        4,
        16.5,
        15.5,
        5,
        18.5,
        8,
        7.5,
        19.5,
        4,
        20,
      ], close: true);
      _line(c, p, 13.5, 7, 16.5, 10);
    case AppIcon.move:
      _rrect(c, p, 3, 4, 12, 12, 2);
      _line(c, p, 9, 16, 9, 20);
      _line(c, p, 9, 20, 20, 20);
      _poly(c, p, const [16, 16, 20, 20, 20, 15]);
    case AppIcon.link:
      _poly(c, p, const [10, 14, 14, 10]);
      _arc(c, p, 8, 8, 4, 0.8, 3.6);
      _arc(c, p, 16, 16, 4, 3.9, 3.6);
    case AppIcon.upload:
      _line(c, p, 12, 16, 12, 4);
      _poly(c, p, const [7, 9, 12, 4, 17, 9]);
      _poly(c, p, const [4, 16, 4, 19, 6, 21, 18, 21, 20, 19, 20, 16]);
    case AppIcon.download:
      _line(c, p, 12, 4, 12, 16);
      _poly(c, p, const [7, 11, 12, 16, 17, 11]);
      _poly(c, p, const [4, 16, 4, 19, 6, 21, 18, 21, 20, 19, 20, 16]);
    case AppIcon.play:
      _poly(c, p, const [8, 5, 19, 12, 8, 19], close: true);
    case AppIcon.playCircle:
      _circle(c, p, 12, 12, 9);
      _poly(c, p, const [10, 8, 16, 12, 10, 16], close: true);
    case AppIcon.pause:
      _line(c, p, 8, 5, 8, 19);
      _line(c, p, 16, 5, 16, 19);
    case AppIcon.pauseCircle:
      _circle(c, p, 12, 12, 9);
      _line(c, p, 9.5, 8.5, 9.5, 15.5);
      _line(c, p, 14.5, 8.5, 14.5, 15.5);
  }
}
