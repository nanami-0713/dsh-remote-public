import 'package:flutter/material.dart';

import '../main.dart';
import '../services/dsh_api.dart';

/// The result of the new-session flow. `null` fields mean "let the host pick
/// its default" and are omitted from the session.create / selectModel calls.
class NewSessionConfig {
  final String? agentPreset;
  final String? provider;
  final String? model;
  final String? reasoningEffort;
  final String? workspaceId;
  final String cwd;

  const NewSessionConfig({
    this.agentPreset,
    this.provider,
    this.model,
    this.reasoningEffort,
    this.workspaceId,
    this.cwd = '',
  });
}

/// Bottom sheet used by the phone app to choose preset + model before (well,
/// model selection is applied immediately after) a session is created.
class NewSessionSheet extends StatefulWidget {
  final DshApi api;
  final String initialCwd;

  const NewSessionSheet({
    super.key,
    required this.api,
    this.initialCwd = '',
  });

  @override
  State<NewSessionSheet> createState() => _NewSessionSheetState();
}

class _NewSessionSheetState extends State<NewSessionSheet> {
  static const _defaultOption = '';
  static const _customWorkspace = '__custom_path__';

  final _cwdController = TextEditingController();

  List<Map<String, dynamic>> _presets = [];
  List<Map<String, dynamic>> _groups = [];
  List<Map<String, dynamic>> _workspaces = [];
  String? _presetError;
  String? _modelError;
  String? _workspaceError;
  bool _loading = true;

  String _selectedPreset = _defaultOption;
  String _selectedProvider = _defaultOption;
  String _selectedModel = _defaultOption;
  String _selectedEffort = _defaultOption;
  String _selectedWorkspace = _defaultOption;

  @override
  void initState() {
    super.initState();
    _cwdController.text = widget.initialCwd;
    _load();
  }

  @override
  void dispose() {
    _cwdController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _presetError = null;
      _modelError = null;
      _workspaceError = null;
    });
    await Future.wait([_loadPresets(), _loadModels(), _loadWorkspaces()]);
    if (!mounted) return;
    setState(() => _loading = false);
  }

  Future<void> _loadPresets() async {
    try {
      final presets = await widget.api.listAgentPresets();
      if (!mounted) return;
      setState(() {
        _presets = presets;
        _selectedPreset = _defaultPresetId(presets);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _presetError = '预设列表加载失败：$e');
    }
  }

  Future<void> _loadModels() async {
    try {
      final value = await widget.api.listModels();
      if (!mounted) return;
      final groups = (value['groups'] as List<dynamic>? ?? [])
          .cast<Map<String, dynamic>>();
      setState(() {
        _groups = groups;
        _selectedProvider = _defaultOption;
        _selectedModel = _defaultOption;
        _selectedEffort = _defaultOption;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _modelError = '模型列表加载失败：$e');
    }
  }

  Future<void> _loadWorkspaces() async {
    try {
      final workspaces = await widget.api.listWorkspaces();
      if (!mounted) return;
      setState(() {
        _workspaces = workspaces;
        _selectedWorkspace = _workspaceForInitialCwd(workspaces);
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _workspaceError = '工作文件夹列表加载失败：$e';
        // Keep the pre-filled manual cwd usable instead of silently dropping it.
        if (widget.initialCwd.trim().isNotEmpty) {
          _selectedWorkspace = _customWorkspace;
        }
      });
    }
  }

  /// Pre-select the workspace matching the pre-filled manual cwd, or switch
  /// the dropdown to "manual path" when it is not a registered workspace.
  String _workspaceForInitialCwd(List<Map<String, dynamic>> workspaces) {
    final initial = widget.initialCwd.trim();
    if (initial.isEmpty) return _defaultOption;
    for (final workspace in workspaces) {
      final path = (workspace['path'] as String? ?? '').trim();
      if (path.isNotEmpty && path == initial) {
        return workspace['workspaceId'] as String? ?? _defaultOption;
      }
    }
    return _customWorkspace;
  }

  String _defaultPresetId(List<Map<String, dynamic>> presets) {
    for (final preset in presets) {
      if (preset['isDefault'] == true && preset['broken'] == null) {
        return preset['id'] as String? ?? _defaultOption;
      }
    }
    for (final preset in presets) {
      if (preset['broken'] == null) {
        return preset['id'] as String? ?? _defaultOption;
      }
    }
    return _defaultOption;
  }

  Map<String, dynamic>? get _selectedGroup {
    for (final group in _groups) {
      if (group['id'] == _selectedProvider) return group;
    }
    return null;
  }

  List<Map<String, dynamic>> get _selectedGroupModels {
    final models = _selectedGroup?['models'] as List<dynamic>? ?? [];
    return models.cast<Map<String, dynamic>>();
  }

  Map<String, dynamic>? get _selectedModelEntry {
    for (final model in _selectedGroupModels) {
      if (model['id'] == _selectedModel) return model;
    }
    return null;
  }

  List<Map<String, dynamic>> get _selectedModelEfforts {
    final reasoning =
        _selectedModelEntry?['reasoning'] as Map<String, dynamic>?;
    final efforts = reasoning?['efforts'] as List<dynamic>? ?? [];
    return efforts.cast<Map<String, dynamic>>();
  }

  bool get _canSubmit {
    if (_selectedProvider.isNotEmpty && _selectedModel.isEmpty) return false;
    if (_selectedWorkspace == _customWorkspace &&
        _cwdController.text.trim().isEmpty) {
      return false;
    }
    return true;
  }

  String _workspaceLabel(Map<String, dynamic> workspace) {
    final title = workspace['title'] as String? ?? '';
    final path = workspace['path'] as String? ?? '';
    if (title.isEmpty) return path;
    if (path.isEmpty) return title;
    return '$title · $path';
  }

  String _presetLabel(Map<String, dynamic> preset) {
    final name = preset['name'] as String?;
    final id = preset['id'] as String? ?? '';
    final broken = preset['broken'] as String?;
    if (broken != null && broken.isNotEmpty) {
      return name == null || name.isEmpty ? '$id（不可用）' : '$name（不可用）';
    }
    return name == null || name.isEmpty ? id : '$name（$id）';
  }

  String _modelLabel(Map<String, dynamic> model) {
    final name = model['name'] as String?;
    final id = model['id'] as String? ?? '';
    if (name == null || name.isEmpty || name == id) return id;
    return '$name（$id）';
  }

  void _submit() {
    if (!_canSubmit) return;
    final customCwd = _selectedWorkspace == _customWorkspace;
    Navigator.of(context).pop(
      NewSessionConfig(
        agentPreset: _selectedPreset.isEmpty ? null : _selectedPreset,
        provider: _selectedProvider.isEmpty ? null : _selectedProvider,
        model: _selectedModel.isEmpty ? null : _selectedModel,
        reasoningEffort: _selectedEffort.isEmpty ? null : _selectedEffort,
        workspaceId: !customCwd && _selectedWorkspace.isNotEmpty
            ? _selectedWorkspace
            : null,
        cwd: customCwd ? _cwdController.text.trim() : '',
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        top: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: SafeArea(
        top: false,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Expanded(
                    child: Text(
                      '新建会话',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              const Text(
                '选择这个会话使用的预设、模型和工作文件夹；不选则使用电脑端的默认配置。',
                style: TextStyle(fontSize: 12, color: kTextSecondary),
              ),
              const SizedBox(height: 16),
              if (_loading)
                const Center(
                  child: Padding(
                    padding: EdgeInsets.all(24),
                    child: CircularProgressIndicator(),
                  ),
                )
              else ...[
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: '预设（agent preset）',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedPreset,
                      items: [
                        const DropdownMenuItem(
                          value: _defaultOption,
                          child: Text('系统默认'),
                        ),
                        for (final preset in _presets)
                          DropdownMenuItem(
                            value: preset['id'] as String? ?? '',
                            enabled:
                                (preset['broken'] as String?)?.isEmpty ?? true,
                            child: Text(_presetLabel(preset)),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _selectedPreset = value);
                      },
                    ),
                  ),
                ),
                if (_presetError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _presetError!,
                    style: const TextStyle(
                      color: Color(0xFFB91C1C),
                      fontSize: 12,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: '模型供应商',
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedProvider,
                      items: [
                        const DropdownMenuItem(
                          value: _defaultOption,
                          child: Text('跟随电脑端默认'),
                        ),
                        for (final group in _groups)
                          DropdownMenuItem(
                            value: group['id'] as String? ?? '',
                            child: Text(
                              group['name'] as String? ??
                                  group['id'] as String? ??
                                  '',
                            ),
                          ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          _selectedProvider = value;
                          _selectedModel = _defaultOption;
                          _selectedEffort = _defaultOption;
                          if (value.isNotEmpty &&
                              _selectedGroupModels.isNotEmpty) {
                            _selectedModel =
                                _selectedGroupModels.first['id'] as String? ??
                                    _defaultOption;
                          }
                        });
                      },
                    ),
                  ),
                ),
                if (_modelError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _modelError!,
                    style: const TextStyle(
                      color: Color(0xFFB91C1C),
                      fontSize: 12,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _loadModels,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试加载模型'),
                  ),
                ],
                if (_selectedProvider.isNotEmpty &&
                    _selectedGroupModels.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: '模型',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedModel,
                        items: [
                          const DropdownMenuItem(
                            value: _defaultOption,
                            child: Text('不指定'),
                          ),
                          for (final model in _selectedGroupModels)
                            DropdownMenuItem(
                              value: model['id'] as String? ?? '',
                              child: Text(_modelLabel(model)),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() {
                            _selectedModel = value;
                            _selectedEffort = _defaultOption;
                            final reasoning = _selectedModelEntry?['reasoning']
                                as Map<String, dynamic>?;
                            final defaultEffort =
                                reasoning?['defaultEffort'] as String?;
                            final efforts = _selectedModelEfforts;
                            if (defaultEffort != null &&
                                efforts.any((e) => e['id'] == defaultEffort)) {
                              _selectedEffort = defaultEffort;
                            }
                          });
                        },
                      ),
                    ),
                  ),
                ],
                if (_selectedProvider.isNotEmpty &&
                    _selectedGroupModels.isEmpty) ...[
                  const SizedBox(height: 12),
                  const Text(
                    '该供应商当前没有可用模型。',
                    style: TextStyle(
                      color: kTextSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_selectedModelEfforts.isNotEmpty) ...[
                  const SizedBox(height: 12),
                  InputDecorator(
                    decoration: InputDecoration(
                      labelText: '推理强度',
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 4),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        isExpanded: true,
                        value: _selectedEffort,
                        items: [
                          const DropdownMenuItem(
                            value: _defaultOption,
                            child: Text('跟随默认'),
                          ),
                          for (final effort in _selectedModelEfforts)
                            DropdownMenuItem(
                              value: effort['id'] as String? ?? '',
                              child: Text(
                                effort['name'] as String? ??
                                    effort['id'] as String? ??
                                    '',
                              ),
                            ),
                        ],
                        onChanged: (value) {
                          if (value == null) return;
                          setState(() => _selectedEffort = value);
                        },
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                InputDecorator(
                  decoration: InputDecoration(
                    labelText: '工作文件夹',
                    prefixIcon: const Icon(Icons.folder_outlined, size: 20),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    contentPadding:
                        const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: _selectedWorkspace,
                      items: [
                        const DropdownMenuItem(
                          value: _defaultOption,
                          child: Text('跟随电脑端默认'),
                        ),
                        for (final workspace in _workspaces)
                          DropdownMenuItem(
                            value: workspace['workspaceId'] as String? ?? '',
                            child: Text(
                              _workspaceLabel(workspace),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        const DropdownMenuItem(
                          value: _customWorkspace,
                          child: Text('手动输入路径…'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => _selectedWorkspace = value);
                      },
                    ),
                  ),
                ),
                if (_workspaceError != null) ...[
                  const SizedBox(height: 6),
                  Text(
                    _workspaceError!,
                    style: const TextStyle(
                      color: Color(0xFFB91C1C),
                      fontSize: 12,
                    ),
                  ),
                  TextButton.icon(
                    onPressed: _loadWorkspaces,
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('重试加载工作文件夹'),
                  ),
                ],
                if (_selectedWorkspace == _customWorkspace) ...[
                  const SizedBox(height: 12),
                  TextField(
                    controller: _cwdController,
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: '手动输入工作目录',
                      hintText: '/path/to/workspace',
                      prefixIcon:
                          Icon(Icons.edit_location_alt_outlined, size: 20),
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _canSubmit ? _submit : null,
                    child: const Text('创建会话'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
