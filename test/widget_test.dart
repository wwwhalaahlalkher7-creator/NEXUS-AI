import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/main.dart';

void main() {
  testWidgets(
    'dashboard shell renders without claiming an active model',
    (tester) async {
      await tester.pumpWidget(const NexusApp());

      expect(find.text('NEXUS AI'), findsOneWidget);
      expect(find.text('مرحباً بك في NEXUS'), findsOneWidget);
      expect(
        find.textContaining('لا يوجد نموذج ذكاء اصطناعي نشط'),
        findsOneWidget,
      );
    },
  );
}
