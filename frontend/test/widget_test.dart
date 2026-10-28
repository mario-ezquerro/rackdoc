import 'package:flutter_test/flutter_test.dart';
import 'package:rackdoc_frontend/main.dart';

void main() {
  testWidgets('RackDoc app smoke test', (WidgetTester tester) async {
    await tester.pumpWidget(const RackDocApp());
    expect(find.text('RackDoc DCIM'), findsOneWidget);
  });
}
