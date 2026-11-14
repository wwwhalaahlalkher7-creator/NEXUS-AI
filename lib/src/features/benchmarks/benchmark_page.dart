import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../models/model_record.dart';
import '../runtime/model_runtime_manager.dart';
import 'benchmark_generation_port.dart';
import 'benchmark_repository.dart';
import 'benchmark_run_record.dart';
import 'benchmark_runner.dart';

class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({
    super.key,
    required this.models,
    required this.runtimeManager,
  });

  final List<ModelRecord> models;
  final ModelRuntimeManager runtimeManager;

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> {
  late final BenchmarkRunRepository _repository;
  late final BenchmarkRunner _runner;
  late final List<ModelRecord> _models;
  late Future<List<BenchmarkRunRecord>> _history;
  String? _selectedModelId;
  int _contextTokens = 2048;
  late int _cpuThreads;
  bool _running = false;
  String? _message;

  @override
  void initState() {
    super.initState();
    _models = widget.models
        .where((model) =>
            model.runtime == ModelRuntime.llamaCpp &&
            model.status == ModelInstallStatus.installed &&
            model.localPath != null &&
            model.localPath!.isNotEmpty)
        .toList(growable: false);
    _repository = BenchmarkRunRepository();
    _runner = BenchmarkRunner(
      runtimeManager: widget.runtimeManager,
      generationPort: const RustBenchmarkGenerationPort(),
      environmentReader: LocalBenchmarkEnvironmentReader(),
      repository: _repository,
    );
    _selectedModelId = _models.isEmpty ? null : _models.first.id;
    _cpuThreads = Platform.numberOfProcessors.clamp(1, 8).toInt();
    _history = _repository.list();
  }

  ModelRecord? get _selectedModel {
    for (final model in _models) {
      if (model.id == _selectedModelId) return model;
    }
    return null;
  }

  List<int> _contextOptions(ModelRecord model) {
    const values = [512, 1024, 2048, 4096];
    final declared = model.contextLength;
    final options = values
        .where((value) => declared == null || declared <= 0 || value <= declared)
        .toList(growable: false);
    return options.isEmpty ? const [512] : options;
  }

  Future<void> _run() async {
    final model = _selectedModel;
    if (model == null || _running) return;
    final approved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('تشغيل اختبار الأداء؟'),
        content: Text(
          'سيُحمّل «${model.displayName}» مرتين، ثم ينفّذ توليداً قصيراً واختبار إلغاء. '
          'قد يستهلك الاختبار البطارية ويرفع حرارة الجهاز. سيُفرّغ النموذج بعد انتهاء القياس، '
          'ولا يمكن بدء الاختبار أثناء وجود جلسة نشطة.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('إلغاء'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('بدء الاختبار'),
          ),
        ],
      ),
    );
    if (approved != true || !mounted) return;

    setState(() {
      _running = true;
      _message = 'جارٍ تحميل النموذج وقياس الأداء المحلي…';
    });
    try {
      final result = await _runner.run(
        model,
        contextTokens: _contextTokens,
        cpuThreads: _cpuThreads,
      );
      if (!mounted) return;
      setState(() {
        _message = result.message;
        _history = _repository.list(modelId: model.id);
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _message = 'تعذر تشغيل الاختبار: $error');
    } finally {
      if (mounted) setState(() => _running = false);
    }
  }

  String _duration(int? milliseconds) =>
      milliseconds == null ? 'غير متاح' : '$milliseconds ms';

  String _memory(int? bytes) {
    if (bytes == null || bytes <= 0) return 'غير متاح';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
  }

  String _thermal(int? value) {
    if (value == null) return 'غير متاح';
    return switch (value) {
      0 => 'طبيعي',
      1 => 'خفيف',
      2 => 'متوسط',
      3 => 'شديد',
      4 => 'حرج',
      5 => 'طارئ',
      6 => 'إيقاف',
      _ => 'غير معروف',
    };
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final model = _selectedModel;
    final contextOptions = model == null ? const <int>[] : _contextOptions(model);
    if (model != null && !contextOptions.contains(_contextTokens)) {
      _contextTokens = contextOptions.last;
    }
    return Scaffold(
      appBar: AppBar(title: const Text('قياس أداء النماذج')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('اختبار محلي قابل للتكرار',
                      style: Theme.of(context).textTheme.titleLarge),
                  const SizedBox(height: 6),
                  Text(
                    'يقيس التحميل الأول وإعادة التحميل وسرعة التوليد وزمن استجابة الإلغاء، '
                    'ويحفظ قياسات الحرارة والبطارية وVmHWM للعملية. قياس VmHWM تراكمي منذ بدء التطبيق، وليس ذروة ذاكرة خاصة بهذا الاختبار أو بالنموذج وحده.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                  const SizedBox(height: 16),
                  if (_models.isEmpty)
                    const Text('لا توجد نماذج GGUF مثبتة قابلة للقياس.')
                  else ...[
                    DropdownButtonFormField<String>(
                      value: _selectedModelId,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'النموذج'),
                      items: _models
                          .map((item) => DropdownMenuItem<String>(
                                value: item.id,
                                child: Text(item.displayName,
                                    overflow: TextOverflow.ellipsis),
                              ))
                          .toList(growable: false),
                      onChanged: _running
                          ? null
                          : (value) => setState(() => _selectedModelId = value),
                    ),
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _contextTokens,
                            decoration: const InputDecoration(labelText: 'السياق'),
                            items: contextOptions
                                .map((value) => DropdownMenuItem<int>(
                                      value: value,
                                      child: Text('$value'),
                                    ))
                                .toList(growable: false),
                            onChanged: _running
                                ? null
                                : (value) => setState(() {
                                      if (value != null) _contextTokens = value;
                                    }),
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: DropdownButtonFormField<int>(
                            value: _cpuThreads,
                            decoration: const InputDecoration(labelText: 'خيوط CPU'),
                            items: List.generate(
                              Platform.numberOfProcessors.clamp(1, 8).toInt(),
                              (index) => index + 1,
                            ).map((value) => DropdownMenuItem<int>(
                                  value: value,
                                  child: Text('$value'),
                                )).toList(growable: false),
                            onChanged: _running
                                ? null
                                : (value) => setState(() {
                                      if (value != null) _cpuThreads = value;
                                    }),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: FilledButton.icon(
                        onPressed: _running || !_runner.isAvailable ? null : _run,
                        icon: _running
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              )
                            : const Icon(Icons.speed_rounded),
                        label: Text(_running ? 'جارٍ القياس…' : 'تشغيل الاختبار'),
                      ),
                    ),
                  ],
                  if (_message != null) ...[
                    const SizedBox(height: 12),
                    Text(_message!, style: Theme.of(context).textTheme.bodySmall),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: 18),
          Text('السجل المحفوظ', style: Theme.of(context).textTheme.titleLarge),
          const SizedBox(height: 8),
          FutureBuilder<List<BenchmarkRunRecord>>(
            future: _history,
            builder: (context, snapshot) {
              if (snapshot.connectionState == ConnectionState.waiting) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError) {
                return Text('تعذر تحميل سجل القياسات: ${snapshot.error}');
              }
              final runs = snapshot.data ?? const <BenchmarkRunRecord>[];
              if (runs.isEmpty) return const Text('لا توجد قياسات محفوظة بعد.');
              return Column(
                children: [
                  for (final run in runs)
                    Card(
                      margin: const EdgeInsets.only(bottom: 10),
                      child: Padding(
                        padding: const EdgeInsets.all(14),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(run.modelName,
                                      style: Theme.of(context).textTheme.titleMedium),
                                ),
                                Icon(
                                  run.status == 'completed'
                                      ? Icons.check_circle_outline
                                      : Icons.warning_amber_rounded,
                                  color: run.status == 'completed'
                                      ? colors.primary
                                      : colors.error,
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            _MetricLine(label: 'السياق الفعلي', value: '${run.contextTokens} رمز'),
                            _MetricLine(label: 'خيوط CPU الفعلية', value: '${run.cpuThreads}'),
                            _MetricLine(label: 'التحميل الأول', value: _duration(run.firstLoadMs)),
                            _MetricLine(label: 'إعادة التحميل', value: _duration(run.repeatLoadMs)),
                            _MetricLine(
                              label: 'سرعة التوليد',
                              value: run.tokensPerSecond == null
                                  ? 'غير متاح'
                                  : '${run.tokensPerSecond!.toStringAsFixed(2)} token/s',
                            ),
                            _MetricLine(label: 'أعلى VmHWM للعملية منذ بدء التطبيق', value: _memory(run.peakResidentBytes)),
                            _MetricLine(
                              label: 'زمن الإلغاء',
                              value: run.cancelLatencyMs == null
                                  ? 'لم يُقَس'
                                  : '${run.cancelLatencyMs} ms',
                            ),
                            _MetricLine(
                              label: 'الحالة الحرارية',
                              value: '${_thermal(run.startingThermalStatus)} ← ${_thermal(run.endingThermalStatus)}',
                            ),
                            _MetricLine(
                              label: 'البطارية',
                              value: '${run.startingBatteryPercent?.toString() ?? '—'}% ← ${run.endingBatteryPercent?.toString() ?? '—'}%',
                            ),
                            if (run.error != null) ...[
                              const SizedBox(height: 6),
                              Text(run.error!,
                                  style: TextStyle(color: colors.error)),
                            ],
                          ],
                        ),
                      ),
                    ),
                ],
              );
            },
          ),
        ],
      ),
    );
  }
}

class _MetricLine extends StatelessWidget {
  const _MetricLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(
          children: [
            Expanded(child: Text(label, style: Theme.of(context).textTheme.bodySmall)),
            const SizedBox(width: 12),
            Flexible(
              child: Text(value, textAlign: TextAlign.end,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontWeight: FontWeight.w700,
                      )),
            ),
          ],
        ),
      );
}
