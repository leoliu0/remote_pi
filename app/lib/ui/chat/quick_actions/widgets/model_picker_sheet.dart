import 'package:app/data/actions/actions_repository.dart';
import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:app/ui/chat/quick_actions/viewmodels/quick_actions_viewmodel.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

/// Plan/28 Wave C — Model sub-picker pushed from the Quick Actions sheet.
/// Lists every model the Pi reports as available, optionally filtered by
/// provider. Tapping a row dispatches `model_set` via the parent
/// [QuickActionsViewModel] and closes the sub-picker on success.
Future<void> showModelPickerSheet(
  BuildContext context, {
  required QuickActionsViewModel vm,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: context.colors.bg,
    barrierColor: Colors.black.withValues(alpha: 0.6),
    isScrollControlled: true,
    showDragHandle: false,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return ChangeNotifierProvider<QuickActionsViewModel>.value(
        value: vm,
        child: const _ModelPickerBody(),
      );
    },
  );
}

class _ModelPickerBody extends StatefulWidget {
  const _ModelPickerBody();

  @override
  State<_ModelPickerBody> createState() => _ModelPickerBodyState();
}

class _ModelPickerBodyState extends State<_ModelPickerBody> {
  late Future<ModelsCatalogue> _future;
  String? _providerFilter;
  String _searchQuery = '';
  final TextEditingController _searchController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _future = _load(forceRefresh: true);
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<ModelsCatalogue> _load({required bool forceRefresh}) {
    final vm = context.read<QuickActionsViewModel>();
    return vm.loadModels(forceRefresh: forceRefresh);
  }

  Future<void> _refresh() async {
    setState(() {
      _future = _load(forceRefresh: true);
    });
    await _future.catchError((Object _) => const ModelsCatalogue(models: []));
  }

  Future<void> _onPick(WireModel model) async {
    final vm = context.read<QuickActionsViewModel>();
    final messenger = ScaffoldMessenger.maybeOf(context);
    try {
      await vm.setModel(model);
      if (!mounted) return;
      Navigator.of(context).pop();
    } catch (e) {
      final msg = e is ActionFailure
          ? e.message
          : 'Failed to switch to ${model.name}';
      messenger?.showSnackBar(
        SnackBar(
          content: Text(msg),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 4),
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final mq = MediaQuery.of(context);
    final maxHeight = mq.size.height * 0.85;
    return SafeArea(
      top: false,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: Padding(
          padding: EdgeInsets.only(bottom: mq.viewInsets.bottom),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 10),
              _DragHandle(),
              const SizedBox(height: 8),
              _Header(onRefresh: _refresh),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
                child: Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: colors.surface,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: colors.border),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      Icon(LucideIcons.search, size: 16, color: colors.muted),
                      const SizedBox(width: 8),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          onChanged: (v) => setState(() => _searchQuery = v.trim().toLowerCase()),
                          style: TextStyle(
                            fontFamily: kMonoFamily,
                            fontSize: 12,
                            color: colors.text,
                          ),
                          decoration: InputDecoration(
                            hintText: 'Search models, providers, or IDs...',
                            hintStyle: TextStyle(
                              fontFamily: kMonoFamily,
                              fontSize: 12,
                              color: colors.muted,
                            ),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.zero,
                          ),
                        ),
                      ),
                      if (_searchQuery.isNotEmpty)
                        GestureDetector(
                          onTap: () {
                            _searchController.clear();
                            setState(() => _searchQuery = '');
                          },
                          child: Icon(LucideIcons.x, size: 14, color: colors.muted),
                        ),
                    ],
                  ),
                ),
              ),
              Divider(color: colors.border, height: 1, thickness: 1),
              Flexible(
                child: FutureBuilder<ModelsCatalogue>(
                  future: _future,
                  builder: (ctx, snap) {
                    if (snap.connectionState != ConnectionState.done) {
                      return const _LoadingState();
                    }
                    if (snap.hasError) {
                      return _ErrorState(
                        message: snap.error is ActionFailure
                            ? (snap.error as ActionFailure).message
                            : 'Failed to load models',
                        onRetry: _refresh,
                      );
                    }
                    final cat = snap.data!;
                    if (cat.models.isEmpty) {
                      return const _EmptyState();
                    }
                    return _ProviderTabs(
                      catalogue: cat,
                      selectedProvider: _providerFilter,
                      searchQuery: _searchQuery,
                      onProviderTap: (p) =>
                          setState(() => _providerFilter = p),
                      onModelPick: _onPick,
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------

class _DragHandle extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 4,
      decoration: BoxDecoration(
        color: context.colors.border,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}

class _Header extends StatelessWidget {
  final VoidCallback onRefresh;
  const _Header({required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 6, 8, 10),
      child: Row(
        children: [
          IconButton(
            icon: Icon(LucideIcons.arrowLeft, size: 18, color: colors.muted),
            onPressed: () => Navigator.of(context).pop(),
            tooltip: 'Back',
          ),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              'Choose a model',
              style: TextStyle(
                fontFamily: kMonoFamily,
                fontSize: 13,
                color: colors.text,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          IconButton(
            key: const Key('model-picker-refresh'),
            icon: Icon(LucideIcons.refreshCw, size: 18, color: colors.muted),
            onPressed: onRefresh,
            tooltip: 'Refresh',
          ),
        ],
      ),
    );
  }
}

class _ProviderTabs extends StatelessWidget {
  final ModelsCatalogue catalogue;
  final String? selectedProvider;
  final String searchQuery;
  final ValueChanged<String?> onProviderTap;
  final ValueChanged<WireModel> onModelPick;
  const _ProviderTabs({
    required this.catalogue,
    required this.selectedProvider,
    required this.searchQuery,
    required this.onProviderTap,
    required this.onModelPick,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    final providerCounts = <String, int>{};
    for (final m in catalogue.models) {
      providerCounts[m.provider] = (providerCounts[m.provider] ?? 0) + 1;
    }
    final providers = providerCounts.keys.toList()..sort();
    final queryFiltered = searchQuery.isEmpty
        ? catalogue.models
        : catalogue.models.where((m) {
            final q = searchQuery;
            return m.name.toLowerCase().contains(q) ||
                m.id.toLowerCase().contains(q) ||
                m.provider.toLowerCase().contains(q);
          }).toList();

    final filtered = selectedProvider == null
        ? queryFiltered
        : queryFiltered
            .where((m) => m.provider == selectedProvider)
            .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (providers.length > 1)
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                _Chip(
                  label: 'all (${catalogue.models.length})',
                  selected: selectedProvider == null,
                  onTap: () => onProviderTap(null),
                ),
                const SizedBox(width: 6),
                for (final p in providers) ...[
                  _Chip(
                    label: '$p (${providerCounts[p]})',
                    selected: selectedProvider == p,
                    onTap: () => onProviderTap(p),
                  ),
                  const SizedBox(width: 6),
                ],
              ],
            ),
          ),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                searchQuery.isNotEmpty
                    ? 'No models match "$searchQuery"'
                    : 'No models available',
                style: TextStyle(
                  fontFamily: kMonoFamily,
                  fontSize: 12,
                  color: colors.muted,
                ),
              ),
            ),
          )
        else
          Flexible(
            child: ListView.separated(
              padding: const EdgeInsets.only(bottom: 18),
              shrinkWrap: true,
              itemCount: filtered.length,
              separatorBuilder: (_, _) =>
                  Divider(color: colors.border, height: 1, thickness: 1),
              itemBuilder: (_, i) {
                final m = filtered[i];
                final isCurrent = (catalogue.current?.id == m.id &&
                        catalogue.current?.provider == m.provider) ||
                    catalogue.current?.id.toLowerCase() == m.id.toLowerCase() ||
                    catalogue.current?.name.toLowerCase() == m.name.toLowerCase();
                return _ModelTile(
                  model: m,
                  current: isCurrent,
                  onTap: () => onModelPick(m),
                );
              },
            ),
          ),
      ],
    );
  }
}

class _Chip extends StatelessWidget {
  final String label;
  final bool selected;
  final VoidCallback onTap;
  const _Chip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          border: Border.all(
            color: selected ? colors.accent : colors.border,
          ),
          color: selected ? colors.accent.withValues(alpha: 0.12) : colors.bg,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 11,
            color: selected ? colors.accent : colors.muted,
          ),
        ),
      ),
    );
  }
}

class _ModelTile extends StatelessWidget {
  final WireModel model;
  final bool current;
  final VoidCallback onTap;
  const _ModelTile({
    required this.model,
    required this.current,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: current ? colors.accent.withValues(alpha: 0.08) : Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          model.name,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontFamily: kMonoFamily,
                            fontSize: 13,
                            fontWeight: current ? FontWeight.w600 : FontWeight.w500,
                            color: current ? colors.accent : colors.text,
                          ),
                        ),
                      ),
                      if (model.reasoning) ...[
                        const SizedBox(width: 6),
                        const _Badge(label: 'reasoning'),
                      ],
                    ],
                  ),
                  const SizedBox(height: 3),
                  Text(
                    _subtitle(model),
                    style: TextStyle(
                      fontFamily: kMonoFamily,
                      fontSize: 10,
                      color: current ? colors.accent.withValues(alpha: 0.8) : colors.muted,
                    ),
                  ),
                ],
              ),
            ),
            if (current)
              Icon(LucideIcons.check, color: colors.accent, size: 18),
          ],
        ),
      ),
    );
  }

  static String _subtitle(WireModel m) {
    final ctx = m.contextWindow;
    if (ctx <= 0) return m.provider;
    final humanized = ctx >= 1000 ? '${(ctx / 1000).round()}k' : '$ctx';
    return '${m.provider} · ctx $humanized';
  }
}

class _Badge extends StatelessWidget {
  final String label;
  const _Badge({required this.label});
  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: colors.accent.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontFamily: kMonoFamily,
          fontSize: 9,
          color: colors.accent,
        ),
      ),
    );
  }
}

class _LoadingState extends StatelessWidget {
  const _LoadingState();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(
            strokeWidth: 1.6,
            color: context.colors.accent,
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 120,
      child: Center(
        child: Text(
          'No models available',
          style: TextStyle(
            fontFamily: kMonoFamily,
            fontSize: 12,
            color: context.colors.muted,
          ),
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorState({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    final colors = context.colors;
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            message,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontFamily: kMonoFamily,
              fontSize: 12,
              color: colors.error,
            ),
          ),
          const SizedBox(height: 14),
          OutlinedButton(
            onPressed: onRetry,
            style: OutlinedButton.styleFrom(
              foregroundColor: colors.accent,
              side: BorderSide(color: colors.border),
            ),
            child: const Text(
              'Retry',
              style: TextStyle(fontFamily: kMonoFamily, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
