import 'dart:async';
import 'dart:io';

import 'package:material_ui/material_ui.dart';

import '../../rust/api/simple.dart' as rust_api;
import '../agents/agent_record.dart';
import '../agents/agent_repository.dart';
import '../conversations/conversation_context_builder.dart';
import '../conversations/conversation_record.dart';
import '../conversations/conversation_repository.dart';
import '../models/model_record.dart';
import '../models/model_repository.dart';
import '../runtime/model_runtime_manager.dart';
import '../runtime/rust_bridge_initializer.dart';
import '../tools/local_tool.dart';
import '../tools/local_tool_command_parser.dart';
import '../tools/model_tool_call.dart';
import '../knowledge/knowledge_repository.dart';
import '../knowledge/knowledge_retriever.dart';
import '../resources/resource_settings.dart';

/// Local chat UI backed by SQLite and the active native GGUF session.
/// Completed role-aware messages are sent through the model's chat template.
class InferencePage extends StatefulWidget {
  InferencePage({
    super.key,
    required this.runtimeManager,
    ConversationRepository? conversationRepository,
    AgentStore? agentRepository,
    ModelStore? modelRepository,
    LocalToolRegistry? localToolRegistry,
    KnowledgeRepository? knowledgeRepository,
  })  : modelRepository = modelRepository ?? ModelRepository(),
        conversationRepository =
            conversationRepository ?? ConversationRepository(),
        agentRepository = agentRepository ?? AgentRepository(),
        localToolRegistry = localToolRegistry ?? LocalToolRegistry.standard(),
        knowledgeRepository = knowledgeRepository ?? KnowledgeRepository();

  final ModelRuntimeManager runtimeManager;
  final ConversationRepository conversationRepository;
  final AgentStore agentRepository;
  final ModelStore modelRepository;
  final LocalToolRegistry localToolRegistry;
  final KnowledgeRepository knowledgeRepository;

  @override
  State<InferencePage> createState() => _InferencePageState();
}

class _InferencePageState extends State<InferencePage> {
  static const _generalConversationAgent = '__nexus_general_conversation__';
  final TextEditingController _promptController = TextEditingController();
  final ScrollController _chatScrollController = ScrollController();
  StreamSubscription<rust_api.InferenceEventDto>? _generationSubscription;

  List<MessageRecord> _messages = const [];
  List<AgentRecord> _agents = const [];
  String? _selectedAgentId;
  String? _activeConversationId;
  String? _currentAssistantMessageId;
  String _response = '';
  String? _error;
  String? _contextNotice;
  int _contextTrimmedMessages = 0;
  bool _generating = false;
  bool _startingGeneration = false;
  bool _generationLeaseHeld = false;
  bool _canCancel = false;
  bool _generationCancelled = false;
  bool _historyLoading = false;
  bool _agentsLoading = Platform.isAndroid;
  bool _switchingAgentModel = false;
  bool _toolExecutionActive = false;
  bool _handlingModelToolCall = false;
  bool _toolTurnCancelled = false;
  LocalToolExecutionSession? _toolExecutionSession;
  bool _storageAvailable = true;
  bool _knowledgeEnabled = true;
  ResourceSettings _resourceSettings = const ResourceSettings();
  final ResourceSettingsRepository _resourceSettingsRepository =
      ResourceSettingsRepository();
  String _activeKnowledgePrompt = '';
  String _knowledgeNotice = '';
  bool _finalizing = false;
  int _maxTokens = 128;
  int _generatedTokens = 0;
  int _lastPersistedTokenCount = 0;
  Future<void> _messageWriteTail = Future<void>.value();

  ConversationRepository get _repository => widget.conversationRepository;
  AgentStore get _agentRepository => widget.agentRepository;
  ModelStore get _modelRepository => widget.modelRepository;

  AgentRecord? get _selectedAgent {
    final id = _selectedAgentId;
    if (id == null) {
      return null;
    }
    for (final agent in _agents) {
      if (agent.id == id) {
        return agent;
      }
    }
    return null;
  }

  bool get _selectedAgentNeedsModelSwitch {
    final agent = _selectedAgent;
    if (agent == null || agent.status != AgentRecordStatus.ready) {
      return false;
    }
    final assignedModelId = agent.modelId;
    if (assignedModelId == null || assignedModelId.isEmpty) {
      return false;
    }
    final session = widget.runtimeManager.snapshot;
    return !session.isLoaded || session.modelId != assignedModelId;
  }

  @override
  void initState() {
    super.initState();
    widget.runtimeManager.addListener(_handleRuntimeChange);
    if (Platform.isAndroid) {
      unawaited(_initializeHistory());
      unawaited(_loadAgents());
    }
  }

  @override
  void dispose() {
    widget.runtimeManager.removeListener(_handleRuntimeChange);
    _toolExecutionSession?.cancelCurrent();
    if (_generationLeaseHeld && Platform.isAndroid) {
      // Keep the stream subscribed until the native worker emits its terminal
      // event; releasing the lease earlier could allow an unsafe model unload.
      unawaited(
        rust_api.cancelTextGeneration().catchError((Object _) => false),
      );
    } else {
      final subscription = _generationSubscription;
      if (subscription != null) unawaited(subscription.cancel());
    }
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

  Future<void> _loadAgents() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      final agents = await _agentRepository.list();
      if (!mounted) {
        return;
      }
      setState(() {
        _agents = agents;
        _agentsLoading = false;
        if (_selectedAgentId != null &&
            !agents.any((agent) => agent.id == _selectedAgentId)) {
          _selectedAgentId = null;
        }
      });
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _agentsLoading = false;
        _error = 'تعذر تحميل قائمة الوكلاء: $error';
      });
    }
  }

  Future<void> _changeAgent(String? agentId) async {
    if (_generating ||
        _startingGeneration ||
        _switchingAgentModel ||
        _toolExecutionActive ||
        _finalizing ||
        _historyLoading) {
      return;
    }
    final previousAgentId = _selectedAgentId;
    if (agentId == previousAgentId) {
      return;
    }
    setState(() {
      _selectedAgentId = agentId;
      _error = null;
    });
    final conversationId = _activeConversationId;
    if (conversationId == null) {
      return;
    }
    try {
      await _repository.updateAgent(conversationId, agentId);
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _selectedAgentId = previousAgentId;
        _error = 'تعذر ربط الوكيل بالمحادثة: $error';
      });
    }
  }

  Future<void> _switchToSelectedAgentModel() async {
    if (_switchingAgentModel ||
        _generating ||
        _startingGeneration ||
        _toolExecutionActive ||
        _finalizing ||
        _historyLoading ||
        widget.runtimeManager.isBusy ||
        widget.runtimeManager.isGenerating) {
      return;
    }

    final agent = _selectedAgent;
    final assignedModelId = agent?.modelId;
    if (agent == null || assignedModelId == null || assignedModelId.isEmpty) {
      setState(
        () => _error = 'الوكيل المحدد لا يملك نموذجاً مرتبطاً.',
      );
      return;
    }
    if (agent.status != AgentRecordStatus.ready) {
      setState(() => _error = 'فعّل الوكيل قبل تحميل نموذجه.');
      return;
    }

    setState(() {
      _switchingAgentModel = true;
      _error = null;
    });
    try {
      final models = await _modelRepository.list();
      ModelRecord? target;
      for (final model in models) {
        if (model.id == assignedModelId) {
          target = model;
          break;
        }
      }
      final targetModel = target;
      if (targetModel == null) {
        throw StateError(
          'النموذج المرتبط بالوكيل غير موجود في المكتبة المحلية.',
        );
      }
      final modelPath = targetModel.localPath;
      if (targetModel.runtime != ModelRuntime.llamaCpp ||
          targetModel.status != ModelInstallStatus.installed ||
          modelPath == null ||
          modelPath.isEmpty) {
        throw StateError(
          'النموذج المرتبط غير مثبت أو غير متاح للتشغيل المحلي.',
        );
      }
      if (!mounted) {
        return;
      }

      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('تحميل نموذج الوكيل؟'),
          content: Text(
            'سيتم تحميل «${targetModel.displayName}» للوكيل «${agent.name}». '
              'سيُفرّغ النموذج الحالي أولاً، وسيحاول المحرك استعادته إذا فشل التحميل.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('إلغاء'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('تحميل النموذج'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) {
        return;
      }

      final result = await widget.runtimeManager.switchTo(targetModel);
      if (!mounted) {
        return;
      }
      if (!result.isLoaded || result.modelId != targetModel.id) {
        setState(() => _error = result.message);
        return;
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('تم تحميل نموذج الوكيل: ${targetModel.displayName}'),
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _error = 'تعذر تحميل نموذج الوكيل: $error');
      }
    } finally {
      if (mounted) {
        setState(() => _switchingAgentModel = false);
      }
    }
  }

  void _handleRuntimeChange() {
    if (mounted) setState(() {});
  }

  String? _composeContextNotice() {
    final notices = <String>[
      if (_knowledgeNotice.isNotEmpty) _knowledgeNotice,
      if (_contextTrimmedMessages > 0)
        'اختُصرت $_contextTrimmedMessages رسالة قديمة لتناسب نافذة سياق النموذج.',
    ];
    return notices.isEmpty ? null : notices.join(' ');
  }

  void _startNewConversation() {
    if (_generating ||
        _startingGeneration ||
        _switchingAgentModel ||
        _toolExecutionActive ||
        _finalizing) {
      return;
    }
    setState(() {
      _activeConversationId = null;
      _selectedAgentId = null;
      _currentAssistantMessageId = null;
      _messages = const [];
      _response = '';
      _error = null;
      _contextNotice = null;
      _contextTrimmedMessages = 0;
      _activeKnowledgePrompt = '';
      _knowledgeNotice = '';
      _generationCancelled = false;
      _toolExecutionSession = null;
      _toolTurnCancelled = false;
      _generatedTokens = 0;
      _promptController.clear();
    });
  }

  Future<void> _openConversation(String conversationId) async {
    if (_generating ||
        _startingGeneration ||
        _switchingAgentModel ||
        _toolExecutionActive ||
        _finalizing) {
      return;
    }
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
        _selectedAgentId = record.agentId;
        _messages = messages;
        _currentAssistantMessageId = null;
        _response = '';
        _error = null;
        _generationCancelled = false;
        _contextNotice = null;
        _contextTrimmedMessages = 0;
        _activeKnowledgePrompt = '';
        _knowledgeNotice = '';
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
    if (_generating ||
        _startingGeneration ||
        _switchingAgentModel ||
        _finalizing ||
        _historyLoading) {
      return;
    }
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

  void _releaseGenerationLease() {
    if (!_generationLeaseHeld) return;
    _generationLeaseHeld = false;
    widget.runtimeManager.endGeneration();
  }

  Future<bool> _tryRunLocalToolCommand(String prompt) async {
    ParsedLocalToolCommand? command;
    try {
      command = LocalToolCommandParser.parse(prompt);
    } on FormatException catch (error) {
      setState(() => _error = error.message.toString());
      return true;
    }
    if (command == null) return false;

    setState(() {
      _startingGeneration = true;
      _error = null;
    });
    try {
      final startedAt = DateTime.now();
      final LocalToolExecutionResult result;
      if (command.showHelp) {
        result = LocalToolExecutionResult(
          callId: 'tool-${startedAt.microsecondsSinceEpoch}',
          toolName: 'registry',
          status: LocalToolResultStatus.succeeded,
          output: LocalToolCommandParser.helpText,
          durationMs: 0,
        );
      } else {
        result = await widget.localToolRegistry.createSession(settings: _resourceSettings).execute(
              toolName: command.toolName!,
              arguments: command.arguments,
            );
      }

      final activeId = _activeConversationId;
      final existingConversation = activeId == null
          ? null
          : await _repository.get(activeId);
      final conversationId = existingConversation?.id ??
          (await _repository.create(
            title: _titleFromPrompt(prompt),
            agentId: _selectedAgentId,
          )).id;
      await _repository.appendMessage(
        conversationId: conversationId,
        role: MessageRole.user,
        content: prompt,
      );
      await _repository.appendMessage(
        conversationId: conversationId,
        role: MessageRole.tool,
        content: result.toAuditContent(),
      );
      final messages = await _repository.messages(conversationId);
      if (!mounted) return true;
      setState(() {
        _activeConversationId = conversationId;
        _messages = messages;
        _promptController.clear();
        _startingGeneration = false;
        _error = null;
      });
      _scrollToBottom();
    } catch (error) {
      if (mounted) {
        setState(() {
          _startingGeneration = false;
          _error = 'تعذر حفظ نتيجة الأداة المحلية: $error';
        });
      }
    } finally {
      if (mounted && _startingGeneration) {
        setState(() => _startingGeneration = false);
      }
    }
    return true;
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
    if (prompt.isEmpty) {
      setState(() => _error = 'اكتب سؤالاً أو تعليماً قبل بدء التوليد.');
      return;
    }
    if (_generating ||
        _finalizing ||
        _startingGeneration ||
        _switchingAgentModel ||
        _toolExecutionActive) {
      return;
    }
    if (await _tryRunLocalToolCommand(prompt)) {
      return;
    }
    if (!widget.runtimeManager.snapshot.isLoaded) {
      setState(() => _error = 'حمّل نموذج GGUF من صفحة النماذج أولاً.');
      return;
    }

    AgentRecord? selectedAgent;
    final selectedAgentId = _selectedAgentId;
    if (selectedAgentId != null) {
      if (_agentsLoading) {
        setState(() {
          _error = 'قائمة الوكلاء ما زالت قيد التحميل. حاول مجدداً.';
        });
        return;
      }
      for (final agent in _agents) {
        if (agent.id == selectedAgentId) {
          selectedAgent = agent;
          break;
        }
      }
      if (selectedAgent == null) {
        setState(() {
          _error = 'الوكيل المحدد غير متاح. اختر وكيلاً آخر.';
        });
        return;
      }
      if (selectedAgent.status != AgentRecordStatus.ready) {
        setState(() {
          _error = 'الوكيل المحدد ليس بحالة جاهز. فعّله من صفحة الوكلاء أولاً.';
        });
        return;
      }
      final assignedModelId = selectedAgent.modelId;
      final loadedModelId = widget.runtimeManager.snapshot.modelId;
      if (assignedModelId != null && assignedModelId != loadedModelId) {
        setState(() {
          _error = 'النموذج المرتبط بهذا الوكيل غير محمّل. '
              'حمّل النموذج المخصص له من صفحة النماذج.';
        });
        return;
      }
    }

    try {
      _resourceSettings = await _resourceSettingsRepository.load();
    } on Object {
      // Settings are a preference, not a dependency for local inference.
      _resourceSettings = const ResourceSettings();
    }
    _toolExecutionSession = widget.localToolRegistry.createSession(
      settings: _resourceSettings,
    );
    _toolTurnCancelled = false;
    setState(() => _startingGeneration = true);
    try {
      await _generationSubscription?.cancel();
      if (!mounted) return;
      widget.runtimeManager.beginGeneration();
      _generationLeaseHeld = true;
    } catch (error) {
      _toolExecutionSession = null;
      _toolTurnCancelled = false;
      if (mounted) {
        setState(() {
          _startingGeneration = false;
          _error = 'تعذر حجز جلسة النموذج للتوليد: $error';
        });
      }
      return;
    }
    setState(() {
      _startingGeneration = false;
      _generating = true;
      _canCancel = false;
      _generationCancelled = false;
      _response = '';
      _error = null;
      _contextNotice = null;
      _contextTrimmedMessages = 0;
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
          (await _repository.create(
            title: _titleFromPrompt(prompt),
            agentId: selectedAgent?.id,
          )).id;
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
      _activeKnowledgePrompt = '';
      _knowledgeNotice = '';
      if (_knowledgeEnabled && !prompt.trim().startsWith('/')) {
        final contextTokens = widget.runtimeManager.snapshot.contextTokens ?? 0;
        final retrievalBudget = KnowledgePromptBuilder.budgetForContext(
          contextTokens: contextTokens,
          maxOutputTokens: _maxTokens,
          reservedCharacters:
              prompt.length + (selectedAgent?.systemPrompt.length ?? 0),
        );
        if (retrievalBudget == 0) {
          _knowledgeNotice =
              'تجاوزت مساحة السياق المحجوزة حد إرفاق المراجع؛ يمكنك '
              'تقليل حد الإخراج أو تحميل النموذج بسياق أكبر.';
        } else {
          try {
            final knowledgeHits =
                await widget.knowledgeRepository.search(
                  prompt,
                  settings: _resourceSettings,
                );
            _activeKnowledgePrompt = KnowledgePromptBuilder.build(
              knowledgeHits,
              maxCharacters: retrievalBudget,
            );
            if (_activeKnowledgePrompt.isNotEmpty) {
              final sourceCount =
                  knowledgeHits.map((hit) => hit.documentId).toSet().length;
              final sources = knowledgeHits
                  .map((hit) => '[${hit.referenceNumber}] ${hit.title}')
                  .toSet()
                  .join(' · ');
              _knowledgeNotice =
                  'استُرجعت ${knowledgeHits.length} مقاطع من '
                  '$sourceCount وثيقة: $sources';
            }
          } catch (_) {
            _knowledgeNotice =
                'تعذّر البحث في المكتبة؛ ستستمر المحادثة '
                'دون مراجع محلية.';
          }
        }
      }
      final contextSelection = ConversationContextBuilder.build(
        initialMessages,
        maxMessages: _resourceSettings.maxConversationMessages,
        maxBytes: _resourceSettings.maxConversationBytes,
        systemPrompt: selectedAgent?.systemPrompt,
        additionalSystemPrompts: [
          LocalToolCallingPromptBuilder.build(
            widget.localToolRegistry,
            allowToolCalls: true,
          ),
        ],
        userContextSuffix: _activeKnowledgePrompt,
      );
      final boundedPromptMessages = contextSelection.messages
          .map((message) => rust_api.ChatMessageInputDto(
                role: message.role,
                content: message.content,
              ))
          .toList(growable: false);
      if (mounted) {
        setState(() {
          _messages = initialMessages;
          _promptController.clear();
        });
      }

      if (mounted) {
        setState(() {
          _contextTrimmedMessages = contextSelection.droppedMessages;
          _contextNotice = _composeContextNotice();
        });
      }

      await RustBridgeInitializer.ensureInitialized();
      if (!mounted || !_generating) {
        _releaseGenerationLease();
        return;
      }
      if (!widget.runtimeManager.snapshot.isLoaded) {
        throw StateError(
          'تم تفريغ النموذج قبل بدء التوليد. حمّله مجدداً ثم حاول مرة أخرى.',
        );
      }

      final stream = rust_api.generateText(
        messages: boundedPromptMessages,
        maxTokens: _maxTokens,
        temperature: 0.7,
        topK: 40,
        topP: 0.92,
        seed: 0,
      );
      _subscribeToGeneration(stream);
    } catch (error) {
      _releaseGenerationLease();
      if (!mounted) return;
      setState(() {
        _generating = false;
        _canCancel = false;
        _generationCancelled = false;
        _toolExecutionSession = null;
        _toolTurnCancelled = false;
        _error = 'تعذر بدء محرك التوليد: $error';
      });
      await _finalizeAssistant(
        MessageStatus.failed,
        fallback: 'تعذر بدء التوليد: $error',
      );
    }
  }

  void _subscribeToGeneration(Stream<rust_api.InferenceEventDto> stream) {
    _generationSubscription = stream.listen(
      _handleGenerationEvent,
      onError: (Object error) {
        _releaseGenerationLease();
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
        _releaseGenerationLease();
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
  }

  Future<void> _handleModelToolCall(ModelToolCall request) async {
    if (_handlingModelToolCall) return;
    final conversationId = _activeConversationId;
    final messageId = _currentAssistantMessageId;
    if (conversationId == null || messageId == null) return;

    _handlingModelToolCall = true;
    final session = _toolExecutionSession ??=
        widget.localToolRegistry.createSession(settings: _resourceSettings);
    final budgetWasExhausted = session.budgetExhausted;
    final assistantRequest = _response.trim();
    setState(() {
      _toolExecutionActive = true;
      _canCancel = true;
      _generating = false;
      _error = null;
    });

    try {
      await _generationSubscription?.cancel();
      _generationSubscription = null;
      await _messageWriteTail;
      await _repository.updateMessage(
        messageId: messageId,
        conversationId: conversationId,
        content: assistantRequest,
        status: MessageStatus.complete,
      );
      _currentAssistantMessageId = null;

      final result = _toolTurnCancelled
          ? LocalToolExecutionResult(
              callId: 'tool-${DateTime.now().microsecondsSinceEpoch}',
              toolName: request.name,
              status: LocalToolResultStatus.cancelled,
              output: 'أُلغي الطلب قبل بدء تنفيذ الأداة.',
              durationMs: 0,
            )
          : await ModelToolCallExecutor.executeResponse(
              response: assistantRequest,
              session: session,
            );
      if (result == null) {
        throw StateError('تعذر تحليل طلب الأداة الصادر من النموذج.');
      }
      await _repository.appendMessage(
        conversationId: conversationId,
        role: MessageRole.tool,
        content: result.toAuditContent(),
      );
      final messages = await _repository.messages(conversationId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _toolExecutionActive = false;
        _canCancel = false;
        _response = '';
        _generatedTokens = 0;
        _lastPersistedTokenCount = 0;
      });
      _scrollToBottom();

      if (_toolTurnCancelled ||
          result.status == LocalToolResultStatus.cancelled) {
        await _persistAssistantNotice(
          conversationId,
          'أوقفت تنفيذ الأداة بناءً على طلبك. لم تُنفّذ خطوات إضافية.',
          status: MessageStatus.cancelled,
        );
        return;
      }
      if (budgetWasExhausted) {
        await _persistAssistantNotice(
          conversationId,
          'تم إيقاف دورة الأدوات بعد بلوغ الحد الأقصى المسموح لهذه المهمة. '
          'يمكنك بدء طلب جديد لمتابعة العمل.',
        );
        return;
      }

      await _startContinuationGeneration(conversationId);
    } catch (error) {
      _releaseGenerationLease();
      if (!mounted) return;
      setState(() {
        _toolExecutionActive = false;
        _canCancel = false;
        _error = 'تعذر تنفيذ طلب الأداة: $error';
      });
      if (_currentAssistantMessageId != null) {
        await _finalizeAssistant(
          MessageStatus.failed,
          fallback: 'تعذر تنفيذ طلب الأداة: $error',
        );
      } else {
        await _persistAssistantNotice(
          conversationId,
          'تعذر تنفيذ طلب الأداة: $error',
          status: MessageStatus.failed,
        );
      }
    } finally {
      _handlingModelToolCall = false;
      if (mounted && _toolExecutionActive) {
        setState(() {
          _toolExecutionActive = false;
          _canCancel = false;
        });
      }
    }
  }

  Future<void> _startContinuationGeneration(String conversationId) async {
    if (!mounted) return;
    setState(() {
      _startingGeneration = true;
      _toolExecutionActive = false;
      _canCancel = false;
      _error = null;
    });
    try {
      final records = await _repository.messages(conversationId);
      final session = _toolExecutionSession ??=
          widget.localToolRegistry.createSession(settings: _resourceSettings);
      final selectedAgent = _selectedAgent;
      final contextSelection = ConversationContextBuilder.build(
        records,
        maxMessages: _resourceSettings.maxConversationMessages,
        maxBytes: _resourceSettings.maxConversationBytes,
        systemPrompt: selectedAgent?.systemPrompt,
        additionalSystemPrompts: [
          LocalToolCallingPromptBuilder.build(
            widget.localToolRegistry,
            allowToolCalls: !session.budgetExhausted,
          ),
        ],
        userContextSuffix: _activeKnowledgePrompt,
      );
      final boundedPromptMessages = contextSelection.messages
          .map((message) => rust_api.ChatMessageInputDto(
                role: message.role,
                content: message.content,
              ))
          .toList(growable: false);

      await RustBridgeInitializer.ensureInitialized();
      if (!mounted) return;
      if (!widget.runtimeManager.snapshot.isLoaded) {
        throw StateError('تم تفريغ النموذج أثناء تنفيذ الأداة.');
      }
      widget.runtimeManager.beginGeneration();
      _generationLeaseHeld = true;
      final draft = await _repository.createAssistantDraft(conversationId);
      _currentAssistantMessageId = draft.id;
      final updatedMessages = await _repository.messages(conversationId);
      if (!mounted) {
        _releaseGenerationLease();
        return;
      }
      setState(() {
        _messages = updatedMessages;
        _response = '';
        _generating = true;
        _startingGeneration = false;
        _canCancel = false;
        _generatedTokens = 0;
        _lastPersistedTokenCount = 0;
        _generationCancelled = false;
        _contextTrimmedMessages += contextSelection.droppedMessages;
        _contextNotice = _composeContextNotice();
      });
      final stream = rust_api.generateText(
        messages: boundedPromptMessages,
        maxTokens: _maxTokens,
        temperature: 0.7,
        topK: 40,
        topP: 0.92,
        seed: 0,
      );
      _subscribeToGeneration(stream);
      _scrollToBottom();
    } catch (error) {
      _releaseGenerationLease();
      if (!mounted) return;
      setState(() {
        _startingGeneration = false;
        _generating = false;
        _canCancel = false;
        _error = 'تعذر استكمال الإجابة بعد الأداة: $error';
      });
      if (_currentAssistantMessageId != null) {
        await _finalizeAssistant(
          MessageStatus.failed,
          fallback: 'تعذر استكمال الإجابة بعد تنفيذ الأداة: $error',
        );
      } else {
        await _persistAssistantNotice(
          conversationId,
          'تعذر استكمال الإجابة بعد تنفيذ الأداة: $error',
          status: MessageStatus.failed,
        );
      }
    }
  }

  Future<void> _persistAssistantNotice(
    String conversationId,
    String content, {
    MessageStatus status = MessageStatus.complete,
  }) async {
    final draft = await _repository.createAssistantDraft(conversationId);
    await _repository.updateMessage(
      messageId: draft.id,
      conversationId: conversationId,
      content: content,
      status: status,
    );
    final messages = await _repository.messages(conversationId);
    if (!mounted) return;
    setState(() {
      _messages = messages;
      _currentAssistantMessageId = null;
      _response = '';
      _generating = false;
      _startingGeneration = false;
      _toolExecutionActive = false;
      _canCancel = false;
      _toolExecutionSession = null;
      _toolTurnCancelled = false;
      _finalizing = false;
      _activeKnowledgePrompt = '';
      _knowledgeNotice = '';
    });
    _scrollToBottom();
  }

  void _handleGenerationEvent(rust_api.InferenceEventDto event) {
    if (event.done) _releaseGenerationLease();
    if (!mounted) return;
    setState(() {
      if (event.started) {
        _canCancel = true;
      }
      _response += event.delta;
      _generatedTokens = event.generatedTokens;
      if (event.done) {
        _generating = false;
        _canCancel = false;
        _generationCancelled = event.cancelled;
        _error = event.error;
        _contextTrimmedMessages += event.trimmedMessages;
        _contextNotice = _composeContextNotice();
      }
    });

    if (event.generatedTokens - _lastPersistedTokenCount >= 16 &&
        _response.isNotEmpty) {
      _lastPersistedTokenCount = event.generatedTokens;
      _queueAssistantCheckpoint();
    }
    if (event.delta.isNotEmpty) {
      _scrollToBottom();
    }

    if (event.done) {
      if (!event.cancelled && event.error == null) {
        final activeToolSession = _toolExecutionSession ??=
            widget.localToolRegistry.createSession(settings: _resourceSettings);
        final toolCall = ModelToolCall.tryParse(
          _response,
          maxBytes: activeToolSession.maxToolCallEnvelopeBytes,
        );
        if (toolCall != null) {
          unawaited(_handleModelToolCall(toolCall));
          return;
        }
      }
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
      if (mounted) {
        setState(() => _error = 'تعذر حفظ تقدم الاستجابة: $error');
      }
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
      _toolExecutionSession = null;
      _toolTurnCancelled = false;
      _activeKnowledgePrompt = '';
      _knowledgeNotice = '';
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
      if (mounted) {
        setState(() => _error = 'تعذر حفظ نتيجة التوليد: $error');
      }
    });
    await _messageWriteTail;
    if (!mounted) return;
    try {
      final messages = await _repository.messages(conversationId);
      if (!mounted) return;
      setState(() {
        _messages = messages;
        _currentAssistantMessageId = null;
        _toolExecutionSession = null;
        _toolTurnCancelled = false;
        _finalizing = false;
        _activeKnowledgePrompt = '';
        _knowledgeNotice = '';
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
    if (!_canCancel || !Platform.isAndroid) return;
    if (_toolExecutionActive) {
      _toolTurnCancelled = true;
      _toolExecutionSession?.cancelCurrent();
      if (mounted) {
        setState(() => _canCancel = false);
      }
      return;
    }
    if (!_generating) return;
    try {
      await rust_api.cancelTextGeneration();
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = 'تعذر إرسال طلب الإيقاف: $error');
    }
  }

  String _agentStatusLabel(AgentRecordStatus status) {
    return switch (status) {
      AgentRecordStatus.draft => 'مسودة',
      AgentRecordStatus.ready => 'جاهز',
      AgentRecordStatus.paused => 'متوقف',
    };
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
                onPressed: _generating ||
                        _startingGeneration ||
                        _switchingAgentModel ||
                        _finalizing
                    ? null
                    : _startNewConversation,
                icon: const Icon(Icons.add_comment_outlined),
              ),
              IconButton(
                tooltip: 'سجل المحادثات',
                onPressed: !androidSupported ||
                        _generating ||
                        _startingGeneration ||
                        _switchingAgentModel ||
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
        if (_contextNotice != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: _NoticeCard(
              message: _contextNotice!,
              icon: Icons.history_toggle_off_rounded,
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
        if (androidSupported)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: DropdownButtonFormField<String>(
              value: _selectedAgentId ?? _generalConversationAgent,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'وكيل المحادثة',
                helperText:
                    'اختر وكيلاً جاهزاً. يمكن تحميل نموذجه المرتبط من هنا بعد التأكيد.',
                border: OutlineInputBorder(),
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 9,
                ),
              ),
              items: [
                const DropdownMenuItem<String>(
                  value: _generalConversationAgent,
                  child: Text('محادثة عامة بدون وكيل'),
                ),
                if (_selectedAgentId != null &&
                    !_agents.any((agent) => agent.id == _selectedAgentId))
                  DropdownMenuItem<String>(
                    value: _selectedAgentId!,
                    child: const Text('وكيل غير متاح على هذا الجهاز'),
                  ),
                for (final agent in _agents)
                  DropdownMenuItem<String>(
                    value: agent.id,
                    child: Text(
                      '${agent.name} · ${_agentStatusLabel(agent.status)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: _generating ||
                      _startingGeneration ||
                      _toolExecutionActive ||
                      _finalizing ||
                      _historyLoading ||
                      _switchingAgentModel
                  ? null
                  : (agentKey) => unawaited(
                      _changeAgent(
                        agentKey == _generalConversationAgent ? null : agentKey,
                      ),
                    ),
            ),
          ),
        if (androidSupported && _selectedAgentNeedsModelSwitch)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: OutlinedButton.icon(
                onPressed: _switchingAgentModel ||
                        _generating ||
                        _startingGeneration ||
                        _finalizing ||
                        _historyLoading ||
                        widget.runtimeManager.isBusy ||
                        widget.runtimeManager.isGenerating
                    ? null
                    : _switchToSelectedAgentModel,
                icon: _switchingAgentModel
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.swap_horiz_rounded),
                label: Text(
                  _switchingAgentModel
                      ? 'جارٍ تحميل نموذج الوكيل…'
                      : 'التبديل إلى نموذج الوكيل',
                ),
              ),
            ),
          ),
        if (_agentsLoading)
          const Padding(
            padding: EdgeInsetsDirectional.only(start: 18, end: 18, bottom: 6),
            child: LinearProgressIndicator(minHeight: 2),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Text(
            'يستخدم النموذج أدوار المحادثة السابقة؛ وتُختصر الأدوار الأقدم تلقائياً عند امتلاء السياق.',
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
          ),
        ),
        if (_generating || _startingGeneration || _toolExecutionActive)
          const LinearProgressIndicator(minHeight: 2),
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
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: FilterChip(
                    selected: _knowledgeEnabled,
                    onSelected: _generating ||
                            _startingGeneration ||
                            _toolExecutionActive
                        ? null
                        : (selected) =>
                            setState(() => _knowledgeEnabled = selected),
                    avatar: const Icon(Icons.menu_book_outlined, size: 18),
                    label: const Text('استخدم مكتبتي المعرفية'),
                    showCheckmark: true,
                  ),
                ),
                TextField(
                  controller: _promptController,
                  minLines: 1,
                  maxLines: 4,
                  maxLength: 4000,
                  textInputAction: TextInputAction.newline,
                  onChanged: (_) => setState(() {}),
                  decoration: InputDecoration(
                    hintText: 'اكتب رسالة أو أمراً محلياً…',
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
                  enabled: androidSupported &&
                      !_generating &&
                      !_toolExecutionActive &&
                      !_startingGeneration &&
                      !_switchingAgentModel &&
                      !_finalizing &&
                      _storageAvailable,
                ),
                if (androidSupported && _storageAvailable)
                  Padding(
                    padding: const EdgeInsetsDirectional.only(
                      start: 4,
                      top: 5,
                      bottom: 2,
                    ),
                    child: Align(
                      alignment: AlignmentDirectional.centerStart,
                      child: Text(
                        'أوامر محلية: /احسب تعبير · /وقت · /إحصاء نص · /الأدوات',
                        style: Theme.of(context).textTheme.labelSmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                      ),
                    ),
                  ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    SizedBox(
                      width: 148,
                      child: DropdownButtonFormField<int>(
                        value: _maxTokens,
                        isExpanded: true,
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
                        onChanged: _generating ||
                                _startingGeneration ||
                                _toolExecutionActive ||
                                _switchingAgentModel
                            ? null
                            : (value) {
                                if (value != null) {
                                  setState(() => _maxTokens = value);
                                }
                              },
                      ),
                    ),
                    const Spacer(),
                    if (_generating || _toolExecutionActive)
                      FilledButton.icon(
                        onPressed: _canCancel ? _cancelGeneration : null,
                        icon: const Icon(Icons.stop_rounded),
                        label: Text(_toolExecutionActive ? 'إيقاف الأداة' : 'إيقاف'),
                        style: FilledButton.styleFrom(
                          backgroundColor: colors.error,
                        ),
                      )
                    else
                      FilledButton.icon(
                        onPressed: _finalizing ||
                                _startingGeneration ||
                                _switchingAgentModel ||
                                !androidSupported ||
                                (!modelLoaded &&
                                    !_promptController.text
                                        .trim()
                                        .startsWith('/')) ||
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
    final isTool = message.role == MessageRole.tool;
    final toolResult = isTool
        ? LocalToolExecutionResult.tryParseAuditContent(content)
        : null;
    final modelToolCall = !isUser && !isTool && !isLive
        ? ModelToolCall.tryParse(content)
        : null;
    final isPendingToolCall = isLive &&
        content.trimLeft().startsWith('{\"nexus_tool_call\":');
    final background = isUser
        ? colors.primaryContainer
        : isTool
            ? colors.secondaryContainer
            : colors.surfaceContainerLow;
    final foreground = isUser
        ? colors.onPrimaryContainer
        : isTool
            ? colors.onSecondaryContainer
            : colors.onSurface;
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
                isUser
                    ? 'أنت'
                    : isTool
                        ? 'أداة محلية · ${toolResult?.toolName ?? 'نتيجة أداة'}'
                        : modelToolCall != null
                            ? 'طلب أداة من الوكيل'
                            : 'NEXUS AI',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: foreground.withValues(alpha: 0.72),
                      fontWeight: FontWeight.w800,
                    ),
              ),
              const SizedBox(height: 6),
              SelectableText(
                toolResult?.output ??
                    modelToolCall?.displaySummary ??
                    (isPendingToolCall
                        ? 'يطلب الوكيل تنفيذ أداة محلية…'
                        : content.isEmpty && isLive
                            ? 'جارٍ تجهيز الاستجابة…'
                            : content),
                textDirection: Directionality.of(context),
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: foreground,
                      height: 1.55,
                    ),
              ),
              if (isTool && toolResult != null && !toolResult.succeeded) ...[
                const SizedBox(height: 8),
                Text(
                  'حالة الأداة: ${toolResult.status.name}',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: colors.error,
                      ),
                ),
              ],
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
