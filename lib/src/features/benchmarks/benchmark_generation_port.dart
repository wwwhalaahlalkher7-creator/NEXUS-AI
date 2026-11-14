import 'dart:async';
import 'dart:io';

import '../../rust/api/simple.dart' as rust_api;
import '../runtime/rust_bridge_initializer.dart';

class BenchmarkGenerationSample {
  const BenchmarkGenerationSample({
    required this.generatedTokens,
    required this.elapsedMilliseconds,
    required this.completed,
    required this.cancelled,
    this.cancellationLatencyMilliseconds,
    this.error,
  });

  final int generatedTokens;
  final int elapsedMilliseconds;
  final bool completed;
  final bool cancelled;
  final int? cancellationLatencyMilliseconds;
  final String? error;
}


class BenchmarkNativeGenerationStuck implements Exception {
  const BenchmarkNativeGenerationStuck();

  @override
  String toString() =>
      'لم يؤكد محرك النموذج انتهاء التوليد بعد طلب الإلغاء؛ أُبقيت الجلسة محجوزة لحماية الذاكرة الأصلية. أعد تشغيل التطبيق لاستعادة المحرك.';
}

abstract interface class BenchmarkGenerationPort {
  bool get isAvailable;

  Future<BenchmarkGenerationSample> generate({
    required String prompt,
    required int maxTokens,
    Duration? cancelAfter,
  });
}

class RustBenchmarkGenerationPort implements BenchmarkGenerationPort {
  const RustBenchmarkGenerationPort();

  @override
  bool get isAvailable => Platform.isAndroid;

  @override
  Future<BenchmarkGenerationSample> generate({
    required String prompt,
    required int maxTokens,
    Duration? cancelAfter,
  }) async {
    if (!isAvailable) {
      throw UnsupportedError('قياس توليد GGUF متاح على Android فقط.');
    }
    if (prompt.trim().isEmpty || maxTokens < 1 || maxTokens > 1024) {
      throw ArgumentError('مدخلات اختبار التوليد غير صالحة.');
    }

    await RustBridgeInitializer.ensureInitialized();
    final watch = Stopwatch()..start();
    final terminal = Completer<BenchmarkGenerationSample>();
    late final StreamSubscription<rust_api.InferenceEventDto> subscription;
    Timer? cancellationTimer;
    var generatedTokens = 0;
    var cancelled = false;
    var cancelAccepted = false;
    Stopwatch? cancellationWatch;
    var nativeMayStillBeActive = false;

    void finish({required bool completed, String? error}) {
      if (terminal.isCompleted) return;
      watch.stop();
      cancellationWatch?.stop();
      terminal.complete(BenchmarkGenerationSample(
        generatedTokens: generatedTokens,
        elapsedMilliseconds: watch.elapsedMilliseconds,
        completed: completed,
        cancelled: cancelled,
        cancellationLatencyMilliseconds:
            cancelAccepted ? cancellationWatch?.elapsedMilliseconds : null,
        error: error,
      ));
    }

    final stream = rust_api.generateText(
      messages: [
        rust_api.ChatMessageInputDto(role: 'user', content: prompt),
      ],
      maxTokens: maxTokens,
      temperature: 0.7,
      topK: 40,
      topP: 0.92,
      seed: 7,
    );

    subscription = stream.listen(
      (event) {
        if (event.generatedTokens > generatedTokens) {
          generatedTokens = event.generatedTokens;
        }
        if (!event.done) return;
        cancelled = event.cancelled;
        finish(
          completed: event.error == null && !event.cancelled,
          error: event.error,
        );
      },
      onError: (Object error, StackTrace stackTrace) {
        finish(completed: false, error: error.toString());
      },
      onDone: () {
        if (!terminal.isCompleted) {
          finish(completed: false, error: 'انتهى تدفق التوليد دون حدث نهائي.');
        }
      },
      cancelOnError: true,
    );

    if (cancelAfter != null) {
      cancellationTimer = Timer(cancelAfter, () async {
        if (terminal.isCompleted) return;
        final cancelWatch = Stopwatch()..start();
        try {
          final accepted = await rust_api.cancelTextGeneration();
          if (accepted) {
            cancelAccepted = true;
            cancellationWatch = cancelWatch;
          } else {
            cancelWatch.stop();
          }
        } catch (error) {
          cancelWatch.stop();
          if (!terminal.isCompleted) {
            finish(completed: false, error: 'فشل إرسال طلب الإلغاء: $error');
          }
        }
      });
    }

    try {
      return await terminal.future.timeout(const Duration(minutes: 3));
    } on TimeoutException {
      try {
        await rust_api.cancelTextGeneration();
      } on Object {
        // Still wait for a terminal event before allowing the caller to unload.
      }
      try {
        await terminal.future.timeout(const Duration(seconds: 30));
      } on TimeoutException {
        // No terminal event means native code may still own the context/KV.
        // The runner must retain its generation lease and must not unload.
        nativeMayStillBeActive = true;
        throw const BenchmarkNativeGenerationStuck();
      }
      // The native stream has now terminated safely; report the original
      // benchmark timeout without treating the cancelled sample as a result.
      throw TimeoutException('تجاوز التوليد مهلة القياس البالغة ثلاث دقائق.');
    } finally {
      cancellationTimer?.cancel();
      try {
        await subscription.cancel();
      } on Object {
        // A missing terminal event is handled by retaining the native lease;
        // stream-subscription cleanup must not mask that safety signal.
        if (!nativeMayStillBeActive && !terminal.isCompleted) rethrow;
      }
    }
  }
}
