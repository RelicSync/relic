import 'package:flutter_test/flutter_test.dart';
import 'package:relic_app/main.dart';

void main() {
  testWidgets('gallery boots', (tester) async {
    await tester.pumpWidget(const GalleryApp());
    await tester.pump();
    expect(find.byType(GalleryApp), findsOneWidget);
  });
}
