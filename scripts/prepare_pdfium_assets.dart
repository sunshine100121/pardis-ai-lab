// CI only: Dart's package build hooks prepare the existing locked native asset.
// ignore: depend_on_referenced_packages
import 'package:pdfium_dart/pdfium_dart.dart';

void main() {
  // Reference the package without loading PDFium through Flutter's tester path.
  print('PDFium package build hooks prepared: ${getPdfium.runtimeType}');
}
