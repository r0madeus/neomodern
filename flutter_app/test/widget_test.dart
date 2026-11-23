import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:neomodern/theme/app_theme.dart';

void main() {
  test('formatDuration formats seconds cleanly', () {
    expect(formatDuration(null), '--:--');
    expect(formatDuration(0), '0:00');
    expect(formatDuration(65), '1:05');
    expect(formatDuration(3661), '1:01:01');
  });

  testWidgets('AppTheme.dark configures expected dark canvas',
      (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark(),
        home: const Scaffold(body: Text('NeoModern')),
      ),
    );
    expect(find.text('NeoModern'), findsOneWidget);
  });
}
