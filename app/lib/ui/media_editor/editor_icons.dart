import 'package:flutter/widgets.dart';
import 'package:phosphor_flutter/phosphor_flutter.dart';

/// Photo-editor glyphs (same Phosphor family as `AppIcons`, kept here so the
/// shared icon vocabulary only grows when other screens need them).
abstract final class EditorIcons {
  static const IconData edit = PhosphorIconsRegular.pencilSimple;
  static const IconData crop = PhosphorIconsRegular.crop;
  static const IconData rotateLeft = PhosphorIconsRegular.arrowCounterClockwise;
  static const IconData flip = PhosphorIconsRegular.flipHorizontal;
  static const IconData draw = PhosphorIconsRegular.scribbleLoop;
  static const IconData pen = PhosphorIconsRegular.pencilSimpleLine;
  static const IconData highlighter = PhosphorIconsRegular.highlighter;
  static const IconData text = PhosphorIconsRegular.textAa;
  static const IconData textBg = PhosphorIconsRegular.textT;
  static const IconData sticker = PhosphorIconsRegular.sticker;
  static const IconData emoji = PhosphorIconsRegular.smiley;
  static const IconData hide = PhosphorIconsRegular.eyeSlash;
  static const IconData pixelate = PhosphorIconsRegular.checkerboard;
  static const IconData blur = PhosphorIconsRegular.dropHalf;
  static const IconData filter = PhosphorIconsRegular.magicWand;
  static const IconData undo = PhosphorIconsRegular.arrowUUpLeft;
  static const IconData redo = PhosphorIconsRegular.arrowUUpRight;
  static const IconData reset = PhosphorIconsRegular.arrowCounterClockwise;
  static const IconData save = PhosphorIconsRegular.downloadSimple;
  static const IconData send = PhosphorIconsRegular.paperPlaneRight;
  static const IconData forward = PhosphorIconsRegular.shareFat;
  static const IconData close = PhosphorIconsRegular.x;
  static const IconData check = PhosphorIconsRegular.check;
  static const IconData delete = PhosphorIconsRegular.trash;
  static const IconData hd = PhosphorIconsRegular.highDefinition;
  static const IconData privacy = PhosphorIconsRegular.shieldCheck;
  static const IconData add = PhosphorIconsRegular.plus;
  static const IconData animation = PhosphorIconsRegular.filmStrip;
  static const IconData fit = PhosphorIconsRegular.cornersIn;
}
