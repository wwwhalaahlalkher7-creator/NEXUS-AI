class BenchmarkMetrics {
  const BenchmarkMetrics._();

  static double? tokensPerSecond({
    required int generatedTokens,
    required int elapsedMilliseconds,
  }) {
    if (generatedTokens <= 0 || elapsedMilliseconds <= 0) return null;
    return generatedTokens * 1000 / elapsedMilliseconds;
  }

  static int? maximumKnown(Iterable<int?> values) {
    final known = values.whereType<int>().toList(growable: false);
    if (known.isEmpty) return null;
    return known.reduce((left, right) => left > right ? left : right);
  }

  static int? maximumThermalStatus(Iterable<int?> values) {
    final known = values.whereType<int>().toList(growable: false);
    if (known.isEmpty) return null;
    return known.reduce((left, right) => left > right ? left : right);
  }
}
