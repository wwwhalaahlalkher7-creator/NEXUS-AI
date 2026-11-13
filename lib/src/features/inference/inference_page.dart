import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../rust/api/simple.dart' as rust_api;
import '../conversations/conversation_record.dart';
import '../conversations/conversation_repository.dart';
import '../runtime/model_runtime_manager.dart';
import '../runtime/rust_bridge_initializer.dart';

/// Local chat UI backed by SQLite and the active native GGUF session.
/// Prompt history is stored locally; multi-turn prompt composition is a later
/// stage.
class InferencePage extends StatefulWidget {
  InferencePage({
    super.key,
    required this.runtimeManager,
    ConversationRepository? conversationRepository,
  }) : conversationRepository =
            conversationRepository ?? ConversationRepository();

  final ModelRuntimeManager runtimeManager;
  final ConversationRepository conversationRepository;

  @override
  State<InferencePage> createState() => _InferencePageState();
}

class _InferencePageState extends State<InferencePage> {
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  StreamSubscription<rust_api.InferenceEventDto>? _generationSubscription;

  List<MessageRecord> _messages = const [];
  String? _activeConversationId;
  String? _currentAssistantMessageId;
  String _response = '';
  String? _error;
  bool _generating = false;
  bool _canCancel = false;
  bool _generationCancelled = false;
  bool _historyLoading = false;
  bool _storageAvailable = true;
  bool _finalizing = false;
  int _maxTokens = 128;
  int _generatedTokens = 0;
  int _lastPersistedTokenCount = 0;
  Future<void> _messageWriteTail = Future<void>.value();

  ConversationRepository get _repository => widget.conversationRepository;

  @override
  void initState() {
    super.initState();
    widget.runtimeManager.addListener(_handleRuntimeChange);
    if (Platform.isAndroid) unawaited(_initializeHistory());
  }

  @override
  void dispose() {
    widget.runtimeManager.removeListener(_handleRuntimeChange);
    if (_generating && Platform.isAndroid) {
      unawaited(
        rust_api.cancelTextGeneration().catchError((Object _) => false),
      );
    }
    final subscription = _generationSubscription;
    if (subscription != null) unawaited(subscription.cancel());
    _promptController.dispose();
    _chatScrollController.dispose();
    super.dispose();
  }

  Future<void> _initializeHistory() async {
    try {
      await _repository.recoverInterruptedMessages();
      final conversations = await _repository.list();
      if (!mounted || conversations.isEmpty) return;
      await _openConversation(conversations.first.id);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _storageAvailable = false;
        _error = 'تعذر فتح سجل المحادثات المحلي: $error';
      });
    }
  }

  void _handleRuntimeChange() {
    if (mounted) setState(() {});
  }

  void _startNewConversation() {
    if (_generating || _finalizing) return;
    setState(() {
      _activeConversationId = null;
      _currentAssistantMessageId = null;
      _messages = const [];
      _response = '';
      _error = null;
      _generationCancelled = false;
      _generatedTokens = 0;
      _promptController.clear();
    });
  }

  Future<void> _openConversation(String conversationId) async {
    if (_generating || _finalizing) return;
    setState(() => _historyLoading = true);
    try {
      final record = await _repository.get(conversationId);
      if (record == null) {
        if (!mounted) return;
        _startNewConversation();
        return;
      }
      final messages = await _repository.messages(conversationId);
      if (!mounted) return;
      setState(() {
        _activeConversationId = conversationId;
        _messages = messages;
        _currentAssistantMessageId = null;
        _response = '';
        _error = null;
        _generationCancelled = false;
        _generatedTokens = 0;
        _promptController.clear();
      });
      _scrollToBottom();
    } catch (error) {
      if (mounted) setState(() => _error = 'تعذر تحميل المحادثة: $error');
    } finally {
      if (mounted) setState(() => _historyLoading = false);
    }
  }

  Future<void> _showConversationHistory() async {
    if (_generating || _finalizing || _historyLoading) return;
    setState(() => _historyLoading = true);
    try {
      await _repository.recoverInterruptedMessages();
      var conversations = await _repository.list();
      if (!mounted) return;
      setState(() => _historyLoading = false);
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (sheetContext) {
          return StatefulBuilder(
            builder: (historyContext, setSheetState) {
              return SafeArea(
                child: SizedBox(
                  height: MediaQuery.of(historyContext).size.height * 0.72,
                  child: Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                        child: Row(
                          children: [
                            Expanded(
                              child: Text(
                                'سجل المحادثات',
                                style: Theme.of(historyContext)
                                    .textTheme.titleLarge?.copyWith(
                                  fontWeight: FontWeight.w800,
                                ),
                              ),
                            ),
                            Text('${conversations.length} محادثة'),
                          ],
                        ),
                      ),
                      const Divider(height: 1),
                      Expanded(
                        child: conversations.isEmpty
                            ? const Center(
                                child: Text('لا توجد محادثات محفوظة بعد.'),
                              )
                            : ListView.separated(
                                padding:
                                    const EdgeInsets.symmetric(vertical: 8),
                                itemCount: conversations.length,
                                separatorBuilder: (_, __) =>
                                    const Divider(height: 1),
                                itemBuilder: (rowContext, index) {
                                  final record = conversations[index];
                                  final selected =
                                      record.id == _activeConversationId;
                                  final historyColors =
                                      Theme.of(rowContext).colorScheme;
                                  return ListTile(
                                    leading: CircleAvatar(
                                      backgroundColor: selected
                                          ? historyColors.primaryContainer
                                          : historyColors.surfaceContainerHighest,
                                      child: Icon(
                                        Icons.chat_bubble_outline_rounded,
                                        color: selected
                                            ? historyColors.primary
                                            : historyColors.onSurfaceVariant,
                                      ),
                                    ),
                                    title: Text(
                                      record.title,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    subtitle: Text(
                                      record.lastMessagePreview.isEmpty
                                          ? 'لا توجد رسائل'
                                          : record.lastMessagePreview,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                    onTap: () {
                                      Navigator.of(sheetContext).pop();
                                      unawaited(_openConversation(record.id));
                                    },
                                    trailing: IconButton(
                                      tooltip: 'حذف المحادثة',
                                      onPressed: () async {
                                        final confirmed =
                                            await showDialog<bool>(
                                          context: sheetContext,
                                          builder: (dialogContext) =>
                                              AlertDialog(
                                            title: const Text('حذف المحادثة؟'),
                                            content: const Text(
                                              'سيتم حذف المحادثة ورسائلها من هذا الجهاز نهائياً.',
                                            ),
                                            actions: [
                                              TextButton(
                                                onPressed: () => Navigator.pop(
                                                  dialogContext,
                                                  false,
                                                ),
                                                child: const Text('إلغاء'),
                                              ),
                                              FilledButton(
                                                onPressed: () => Navigator.pop(
                                                  dialogContext,
                                                  true,
                                                ),
                                                child: const Text('حذف'),
                                              ),
                                            ],
                                          ),
                                        );
                                        if (confirmed != true) return;
                                        try {
                                          await _repository.delete(record.id);
                                          if (record.id ==
                                              _activeConversationId) {
                                            _startNewConversation();
                                          }
                                          conversations =
                                              await _repository.list();
                                          if (sheetContext.mounted) {
                                            setSheetState(() {});
                                          }
                                        } catch (error) {
                                          if (mounted) {
                                            setState(() {
                                              _error =
                                                  'تعذر حذف المحادثة: $error';
                                            });
                                          }
                                        }
                                      },
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                    ),
                                  );
                                },
                              ),
                      ),
                    ],
                  ),
                ),
              );
            },
          );
        },
      );
    } catch (error) {
      if (mounted) setState(() => _error = 'تعذر قراءة سجل المحادثات: $error');
    } finally {
      if (mounted && _historyLoading) {
        setState(() => _historyLoading = false);
      }
    }
  }

  Future<void> _startGeneration() async {
    final prompt = _promptController.text.trim();
    if (!Platform.isAndroid) {
      setState(() {
        _error = 'التوليد المحلي متاح حالياً على Android ARM64 فقط.';
      });
      return;
    }
    if (!_storageAvailable) {
      setState(() {
        _error = 'التخزين المحلي غير متاح؛ لا يمكن بدء محادثة محفوظة.';
      });
      return;
    }
    if (!widget.runtimeManager.snapshot.isLoaded) {
      setState(() => _error = 'حمّل نموذج GGUF من صفحة النماذج أولاً.');
      return;
    }
    if (prompt.isEmpty) {
      setState(() => _error = 'اكتب سؤالاً أو تعليماً قبل بدء التوليد.');
      return;
    }
    if (_generating || _finalizing) return;

    await _generationSubscription?.cancel();
    setState(() {
      _generating = true;
      _canCancel = false;
      _generationCancelled = false;
      _response = '';
      _error = null;
      _generatedTokens = 0;
      _lastPersistedTokenCount = 0;
      _finalizing = false;
    });

    try {
      final activeId = _activeConversationId;
      final existingConversation = activeId == null
          ? null
          : await _repository.get(activeId);
      final conversationId = existingConversation?.id ??
          (await _repository.create(title: _titleFromPrompt(prompt))).id;
      if (mounted && conversationId != _activeConversationId) {
        setState(() => _activeConversationId = conversationId);
      }

      await _repository.appendMessage(
        conversationId: conversationId,
        role: MessageRole.user,
        content: prompt,
      );
      final assistantDraft =
          await _repository.createAssistantDraft(conversationId);
      _currentAssistantMessageId = assistantDraft.id;
      final initialMessages = await _repository.messages(conversationId);
      if (mounted) {
        setState(() {
          _messages = initialMessages;
          _promptController.clear();
        });
      }

      await RustBridgeInitializer.ensureInitialized();
      if (!mounted || !_generating) return;
      if (!widget.runtimeManager.snapshot.isLoaded) {
        throw StateError(
          'تم تفريغ النموذج قبل بدء التوليد. حمّله مجدداً ثم حاول مرة أخرى.',
        );
      }

      final stream = rust_api.generateText(
        prompt: prompt,
        maxTokens: _maxTokens,
        temperature: 0.7,
        topK: 40,
        topP: 0.92,
        seed: 0,
      );
      _generationSubscription = stream.listen(
        _handleGenerationEvent,
        onError: (Object error) {
          if (!mounted) return;
          setState(() {
            _generating = false;
            _canCancel = false;
            _generationCancelled = false;
            _error = 'تعذر إكمال التوليد: $error';
          });
          unawaited(_finalizeAssistant(
            MessageStatus.failed,
            fallback: 'فشل التوليد: $error',
          ));
        },
        onDone: () {
          if (!mounted || !_generating || _finalizing) return;
          setState(() {
            _generating = false;
            _canCancel = false;
            _error ??= 'انتهى تدفق الاستجابة دون إشارة اكتمال.';
          });
          unawaited(_finalizeAssistant(
            MessageStatus.failed,
            fallback: 'انتهى تدفق الاستجابة دون إشارة اكتمال.',
          ));
        },
        cancelOnError: true,
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _canCancel = false;
        _generationCancelled = false;
        _error = 'تعذر بدء محرك التوليد: $error';
      });
      await _finalizeAssistant(
        MessageStatus.failed,
        fallback: 'تعذر بدء التوليد: $error',
      );
    }
  }

  void _handleGenerationEvent(rust_api.InferenceEventDto event) {
    if (!mounted) return;
    setState(() {
      if (event.started) _canCancel = true;
      _response += event.delta;
      _generatedTokens = event.generatedTokens;
      if (event.done) {
        _generating = false;
        _canCancel = false;
        _generationCancelled = event.cancelled;
        _error = event.error;
      }
    });

    if (event.generatedTokens - _lastPersistedTokenCount >= 16 &&
        _response.isNotEmpty) {
      _lastPersistedTokenCount = event.generatedTokens;
      _queueAssistantCheckpoint();
    }
    if (event.delta.isNotEmpty) _scrollToBottom();

    if (event.done) {
      final status = event.cancelled
          ? MessageStatus.cancelled
          : event.error != null || _response.trim().isEmpty
              ? MessageStatus.failed
              : MessageStatus.complete;
      final fallback = event.cancelled
          ? 'تم إيقاف التوليد قبل إنتاج نص.'
          : event.error ?? 'لم ينتج النموذج أي نص.';
      unawaited(_finalizeAssistant(status, fallback: fallback));
    }
  }

  void _queueAssistantCheckpoint() {
    final messageId = _currentAssistantMessageId;
    final conversationId = _activeConversationId;
    final content = _response;
    if (messageId == null || conversationId == null || content.isEmpty) return;
    _messageWriteTail = _messageWriteTail.then((_) async {
      await _repository.updateMessage(
        messageId: messageId,
        conversationId: conversationId,
        content: content,
        status: MessageStatus.streaming,
      );
    }).catchError((Object error) {
      if (mounted) setState(() => _error = 'تعذر حفظ تقدم الاستجابة: $error');
    });
  }

  Future<void> _finalizeAssistant(
    MessageStatus status, {
    required String fallback,
  }) async {
    if (_finalizing) return;
    _finalizing = true;
    final messageId = _currentAssistantMessageId;
    final conversationId = _activeConversationId;
    if (messageId == null || conversationId == null) {
      if (mounted) setState(() => _finalizing = false);
      return;
    }

    final content = _response.trim().isEmpty ? fallback : _response.trim();
    _messageWriteTail = _messageWriteTail.then((_) async {
      await _repository.updateMessage(
        messageId: messageId,
        conversationId: conversationId,
        content: content,
        status: status,
      );
    }).catchError((Object error) {
      if (mounted) setState(() => _error = 'تعذر حفظ نتيجة التوليد: $error');
    });
    await _messageWriteTail;
    if (!mounted) return;
    try {
      final messages = await _repository.messages(conversationId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _currentAssistantMessageId = null;
        _finalizing = false;
      });
      _scrollToBottom();
    } catch (error) {
      if (mounted) {
        setState(() {
          _error = 'تم التوليد لكن تعذرت إعادة تحميل السجل: $error';
          _finalizing = false;
        });
      }
    }
  }

  Future<void> _cancelGeneration() async {
    if (!_generating || !_canCancel || !Platform.isAndroid) return;
    try {
      await rust_api.cancelTextGeneration();
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'تعذر إرسال طلب الإيقاف: $error');
    }
  }

  String _titleFromPrompt(String prompt) {
    final normalized = prompt.replaceAll(RegExp(r'\s+'), ' ').trim();
    return normalized.length > 45
        ? '${normalized.substring(0, 42)}…'
        : normalized;
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScrollController.hasClients) {
        _chatScrollController.jumpTo(
          _chatScrollController.position.maxScrollExtent,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final session = widget.runtimeManager.snapshot;
    final androidSupported = Platform.isAndroid;
    final modelLoaded = session.isLoaded;

    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'المحادثة المحلية',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                            fontWeight: FontWeight.w800,
                          ),
                    ),
                    const SizedBox(height: 3),
                    Text(
                      _activeConversationId == null
                          ? 'محادثة جديدة'
                          : 'سجل محفوظ على هذا الجهاز',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colors.onSurfaceVariant,
                          ),
                    ),
                  ],
                ),
              ),
              if (_generatedTokens > 0)
                Padding(
                  padding: const EdgeInsetsDirectional.only(end: 4),
                  child: Text(
                    '$_generatedTokens رمز',
                    style: Theme.of(context).textTheme.labelSmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ),
              IconButton(
                tooltip: 'محادثة جديدة',
                onPressed: _generating || _finalizing
                    ? null
                    : _startNewConversation,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: 'سجل المحادثات',
                onPressed: !androidSupported ||
                        _generating ||
                        _finalizing ||
                        !_storageAvailable
                    ? null
                    : _showConversationHistory,
                icon: const Icon(Icons.history_rounded),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: colors.surfaceContainerLow,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: colors.outlineVariant),
            ),
            child: Row(
              children: [
                Icon(
                  modelLoaded ? Icons.memory_rounded : Icons.memory_outlined,
                  color: modelLoaded ? colors.primary : colors.onSurfaceVariant,
                  size: 20,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    modelLoaded
                        ? 'النموذج محمّل · سياق ${session.contextTokens ?? 0} رمز'
                        : 'حمّل نموذج GGUF من صفحة النماذج للبدء',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: colors.onSurfaceVariant,
                        ),
                  ),
                ),
                if (_historyLoading)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
          ),
        ),
        if (!androidSupported)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: _NoticeCard(
              message:
                  'واجهة التوليد الأصلية مفعّلة في هذه المرحلة لأجهزة Android ARM64 فقط.',
              icon: Icons.phone_android_rounded,
            ),
          ),
        Expanded(
          child: _messages.isEmpty
              ? _EmptyConversation(colors: colors)
              : ListView.builder(
                  controller: _chatScrollController,
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
                  itemCount: _messages.length,
                  itemBuilder: (context, index) {
                    final message = _messages[index];
                    final content = message.id == _currentAssistantMessageId
                        ? _response
                        : message.content;
                    return _MessageBubble(
                      message: message,
                      content: content,
                      isLive: message.id == _currentAssistantMessageId &&
                          _generating,
                    );
                  },
                ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _NoticeCard(
              message: _error!,
              icon: Icons.error_outline_rounded,
              isError: true,
            ),
          ),
        if (_generationCancelled)
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _NoticeCard(
              message: 'أوقفت التوليد. تم حفظ الجزء الذي أنتجه النموذج.',
              icon: Icons.info_outline_rounded,
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'السجل محفوظ محلياً؛ لكن النموذج لا يستخدم الرسائل السابقة في التوليد بعد.',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
        ),
        if (_generating) const LinearProgressIndicator(minHeight: 2),
        Container(
          padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
          decoration: BoxDecoration(
            color: colors.surface,
            border: Border(top: BorderSide(color: colors.outlineVariant)),
          ),
          child: SafeArea(
            top: false,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: _promptController,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 4000,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: 'اكتب رسالتك إلى النموذج المحلي…',
                    counterText: '',
                    filled: true,
                    fillColor: colors.surfaceContainerHighest,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(16),
                      borderSide: BorderSide.none,
                    ),
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                  ),
                  enabled: !_generating && modelLoaded && _storageAvailable,
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 122,
                      child: DropdownButtonFormField<int>(
                        value: _maxTokens,
                        isDense: true,
                        decoration: const InputDecoration(
                          labelText: 'حد الإخراج',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 9,
                          ),
                        ),
                        items: const [64, 128, 256, 512].map((value) {
                          return DropdownMenuItem<int>(
                            value: value,
                            child: Text('$value رمز'),
                          );
                        }).toList(),
                        onChanged: _generating
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _maxTokens = value);
                                }
                              },
                      ),
                    ),
                    const Spacer(),
                    if (_generating)
                      FilledButton.icon(
                        onPressed: _canCancel ? _cancelGeneration : null,
                        icon: const Icon(Icons.stop_rounded),
                        label: const Text('إيقاف'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.error,
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _finalizing ||
                                !androidSupported ||
                                !modelLoaded ||
                                !_storageAvailable
                            ? null
                            : _startGeneration,
                        icon: const Icon(Icons.send_rounded),
                        label: const Text('إرسال'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _EmptyConversation extends StatelessWidget {
  const _EmptyConversation({required this.colors});

  final ColorScheme colors;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 68,
              height: 68,
              decoration: BoxDecoration(
                color: colors.primaryContainer,
                borderRadius: BorderRadius.circular(22),
              ),
              child: Icon(
                Icons.auto_awesome_rounded,
                size: 32,
                color: colors.primary,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'ابدأ محادثة محلية',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w800,
                  ),
            ),
            const SizedBox(height: 6),
            Text(
              'رسائلك واستجابات النموذج تحفظ محلياً على جهازك، ولا تُرسل إلى خادم خارجي.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: colors.onSurfaceVariant,
                    height: 1.5,
                  ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MessageBubble extends StatelessWidget {
  const _MessageBubble({
    required this.message,
    required this.content,
    required this.isLive,
  });

  final MessageRecord message;
  final String content;
  final bool isLive;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final isUser = message.role == MessageRole.user;
    final background =
        isUser ? colors.primaryContainer : colors.surfaceContainerLow;
    final foreground = isUser ? colors.onPrimaryContainer : colors.onSurface;
    final statusLabel = switch (message.status) {
      MessageStatus.streaming => 'جارٍ التوليد',
      MessageStatus.cancelled => 'تم الإيقاف',
      MessageStatus.failed => 'لم تكتمل الاستجابة',
      MessageStatus.complete => null,
    };

    return Align(
      alignment: isUser
          ? AlignmentDirectional.centerEnd
          : AlignmentDirectional.centerStart,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.88,
        ),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.only(
              topLeft: const Radius.circular(16),
              topRight: const Radius.circular(16),
              bottomLeft: Radius.circular(isUser ? 16 : 5),
              bottomRight: Radius.circular(isUser ? 5 : 16),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                isUser ? 'أنت' : 'NEXUS AI',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: foreground.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                content.isEmpty && isLive ? 'جارٍ تجهيز الاستجابة…' : content,
                textDirection: Directionality.of(context),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      height: 1.55,
                    ),
              ),
              if (isLive || statusLabel != null) ...[
                const SizedBox(height: 8),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (isLive) ...[
                      const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 1.7),
                      ),
                      const SizedBox(width: 7),
                    ],
                    Text(
                      isLive ? 'جارٍ التوليد' : statusLabel!,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                            color: foreground.withValues(alpha: 0.72),
                          ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _NoticeCard extends StatelessWidget {
  const _NoticeCard({
    required this.message,
    required this.icon,
    this.isError = false,
  });

  final String message;
  final IconData icon;
  final bool isError;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isError ? colors.errorContainer : colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            icon,
            size: 18,
            color: isError ? colors.onErrorContainer : colors.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: isError
                        ? colors.onErrorContainer
                        : colors.onSurfaceVariant,
                  ),
            ),
          ),
        ],
      ),
    );
  }
}
