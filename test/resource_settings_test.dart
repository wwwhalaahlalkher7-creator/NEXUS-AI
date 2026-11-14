import 'package:flutter_test/flutter_test.dart';
import 'package:nexus_app/src/features/resources/resource_settings.dart';

void main() {
  group('ResourceSettings', () {
    const available = 1024 * 1024 * 512;
    const snapshot = ResourceSnapshot(
      availableMemoryBytes: available,
      totalMemoryBytes: available * 2,
    );

    test('allocates dynamically larger working budgets by mode', () {
      final balanced = ResourceSettings(mode: ResourceMode.balanced);
      final performance = ResourceSettings(mode: ResourceMode.performance);
      final unrestricted = ResourceSettings(mode: ResourceMode.unrestricted);
      expect(
        balanced.importBudgetBytes(snapshot),
        lessThan(performance.importBudgetBytes(snapshot)!),
      );
      expect(unrestricted.importBudgetBytes(snapshot), isNull);
      expect(unrestricted.searchCandidateBudget(snapshot), isNull);
    });

    test('unrestricted mode has no fixed result, document, or tool-call cap', () {
      const settings = ResourceSettings(mode: ResourceMode.unrestricted);
      expect(settings.retrievalResultLimit, isNull);
      expect(settings.maxResultsPerDocument, isNull);
      expect(settings.maxToolCallsPerTurn, isNull);
      expect(settings.maxToolArgumentBytes, isNull);
      expect(settings.maxToolOutputCharacters, isNull);
      expect(settings.importBudgetBytes(null), isNull);
      expect(settings.importBudgetBytes(snapshot), isNull);
      expect(settings.searchCandidateBudget(null), isNull);
      expect(settings.searchCandidateBudget(snapshot), isNull);
    });

    test('unknown stored modes fall back to balanced', () {
      expect(ResourceSettings.fromValue('unknown').mode, ResourceMode.balanced);
    });
  });
}
