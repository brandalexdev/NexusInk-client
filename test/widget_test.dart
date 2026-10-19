import 'package:flutter_test/flutter_test.dart';
import 'package:nexusink_client/main.dart';

void main() {
  testWidgets('NexusInkClientApp smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const NexusInkClientApp());
    expect(find.byType(NexusInkClientApp), findsOneWidget);
  });
}
