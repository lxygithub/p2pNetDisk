// ignore_for_file: constant_identifier_names
// 基于 Remix Icon v4.9.1（Remix Icon License 1.0，允许商用与移动应用）。
// 图标以字体形式打包，无需自定义绘制，也没有第三方 Dart 依赖。
import 'package:flutter/material.dart';

/// Remix Icon 字体族名（见 pubspec.yaml 的 fonts 声明）。
const String _family = 'RemixIcon';

/// 图标语义常量，接口与旧版自绘图标一致，业务代码无需改动。
abstract final class AppIcons {
  static const add = IconData(0xea13, fontFamily: _family);
  static const arrow_upward = IconData(0xea76, fontFamily: _family);
  static const audiotrack_outlined = IconData(0xef83, fontFamily: _family);
  static const battery_saver_outlined = IconData(0xeaae, fontFamily: _family);
  static const bolt = IconData(0xed3d, fontFamily: _family);
  static const broken_image_outlined = IconData(0xee45, fontFamily: _family);
  static const chevron_right = IconData(0xea6e, fontFamily: _family);
  static const cleaning_services_outlined = IconData(
    0xec26,
    fontFamily: _family,
  );
  static const close = IconData(0xeb99, fontFamily: _family);
  static const cloud_off = IconData(0xeb9f, fontFamily: _family);
  static const cloud_queue = IconData(0xeb9d, fontFamily: _family);
  static const copy_outlined = IconData(0xecd5, fontFamily: _family);
  static const create_new_folder_outlined = IconData(
    0xed5a,
    fontFamily: _family,
  );
  static const delete_outline = IconData(0xec26, fontFamily: _family);
  static const delete_sweep_outlined = IconData(0xec26, fontFamily: _family);
  static const description_outlined = IconData(0xecef, fontFamily: _family);
  static const insert_drive_file_outlined = IconData(
    0xeceb,
    fontFamily: _family,
  );
  static const deselect = IconData(0xeb89, fontFamily: _family);
  static const download = IconData(0xec5a, fontFamily: _family);
  static const download_outlined = IconData(0xec5a, fontFamily: _family);
  static const drive_file_move_outline = IconData(0xed11, fontFamily: _family);
  static const drive_file_rename_outline = IconData(
    0xecdb,
    fontFamily: _family,
  );
  static const drive_folder_upload = IconData(0xed82, fontFamily: _family);
  static const error_outline = IconData(0xeca1, fontFamily: _family);
  static const folder = IconData(0xed6a, fontFamily: _family);
  static const folder_rounded = IconData(0xed52, fontFamily: _family);
  static const folder_outlined = IconData(0xed6a, fontFamily: _family);
  static const folder_open = IconData(0xed70, fontFamily: _family);
  static const folder_special = IconData(0xed78, fontFamily: _family);
  static const folder_zip_outlined = IconData(0xed1f, fontFamily: _family);
  static const history = IconData(0xee17, fontFamily: _family);
  static const image_outlined = IconData(0xee4b, fontFamily: _family);
  static const link = IconData(0xeeb2, fontFamily: _family);
  static const more_vert = IconData(0xef77, fontFamily: _family);
  static const movie_outlined = IconData(0xef81, fontFamily: _family);
  static const pause = IconData(0xefd8, fontFamily: _family);
  static const pause_circle_outline = IconData(0xefd6, fontFamily: _family);
  static const picture_as_pdf_outlined = IconData(0xf3c6, fontFamily: _family);
  static const play_arrow = IconData(0xf00b, fontFamily: _family);
  static const play_circle_outline = IconData(0xf009, fontFamily: _family);
  static const refresh = IconData(0xf064, fontFamily: _family);
  static const restore = IconData(0xf080, fontFamily: _family);
  static const search = IconData(0xf0d1, fontFamily: _family);
  static const select_all = IconData(0xeb89, fontFamily: _family);
  static const settings = IconData(0xf0e6, fontFamily: _family);
  static const settings_outlined = IconData(0xf0e6, fontFamily: _family);
  static const swap_vert = IconData(0xf1cb, fontFamily: _family);
  static const tune = IconData(0xec9d, fontFamily: _family);
  static const upload_file = IconData(0xf250, fontFamily: _family);
  static const vertical_align_top = IconData(0xea76, fontFamily: _family);
  static const visibility = IconData(0xecb5, fontFamily: _family);
  static const visibility_off = IconData(0xecb7, fontFamily: _family);
  static const visibility_off_outlined = IconData(0xecb7, fontFamily: _family);
}

/// 统一图标 widget：[size] 边长，[color] 颜色。
class AppIconView extends StatelessWidget {
  const AppIconView(
    this.icon, {
    super.key,
    this.size = 24,
    this.color,
    this.stroke = 1.7,
  });

  final IconData icon;
  final double size;
  final Color? color;

  /// 保留参数以兼容旧调用；字体图标的线宽由字体本身决定。
  final double stroke;

  @override
  Widget build(BuildContext context) {
    return Icon(
      icon,
      size: size,
      color:
          color ??
          IconTheme.of(context).color ??
          Theme.of(context).colorScheme.onSurface,
    );
  }
}
