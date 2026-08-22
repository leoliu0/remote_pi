import 'package:app/protocol/protocol.dart';
import 'package:app/ui/core/themes/themes.dart';
import 'package:flutter/material.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class SlashCommandItem {
  final String name;
  final String description;
  final String category;
  final IconData icon;

  const SlashCommandItem({
    required this.name,
    required this.description,
    this.category = 'Command',
    this.icon = LucideIcons.terminal,
  });
}

const List<SlashCommandItem> kSlashCommands = [
  // Core Commands
  SlashCommandItem(
    name: 'init',
    description: 'Initialize project configuration & guidelines (CLAUDE.md)',
    icon: LucideIcons.sparkles,
  ),
  SlashCommandItem(
    name: 'compact',
    description: 'Compact and summarize conversation history to save context',
    icon: LucideIcons.minimize2,
  ),
  SlashCommandItem(
    name: 'new',
    description: 'Start a fresh, clean conversation session',
    icon: LucideIcons.plus,
  ),
  SlashCommandItem(
    name: 'clear',
    description: 'Clear the current conversation context',
    icon: LucideIcons.trash2,
  ),
  SlashCommandItem(
    name: 'model',
    description: 'Select or change active LLM model & provider',
    icon: LucideIcons.cpu,
  ),
  SlashCommandItem(
    name: 'thinking',
    description: 'Configure thinking and reasoning level (off to max)',
    icon: LucideIcons.brain,
  ),
  SlashCommandItem(
    name: 'help',
    description: 'Show available commands, skills, and usage guide',
    icon: LucideIcons.helpCircle,
  ),
  SlashCommandItem(
    name: 'settings',
    description: 'Open session and app settings',
    icon: LucideIcons.settings,
  ),
  SlashCommandItem(
    name: 'export',
    description: 'Export session conversation to HTML or Markdown',
    icon: LucideIcons.download,
  ),
  SlashCommandItem(
    name: 'undo',
    description: 'Undo the last user message and assistant turn',
    icon: LucideIcons.undo2,
  ),
  SlashCommandItem(
    name: 'fork',
    description: 'Fork conversation from a previous point into a new branch',
    icon: LucideIcons.gitFork,
  ),
  SlashCommandItem(
    name: 'remote-pi',
    description: 'Remote Pi device pairing, status, and relay controls',
    icon: LucideIcons.smartphone,
  ),
  SlashCommandItem(
    name: 'rc',
    description: 'Shortcut for /remote-pi commands',
    icon: LucideIcons.smartphone,
  ),

  // Academic & Coding Skills
  SlashCommandItem(
    name: 'academic-research-suite',
    description: 'Academic research workflows, literature review & manuscript design',
    category: 'Skill',
    icon: LucideIcons.graduationCap,
  ),
  SlashCommandItem(
    name: 'audit-paper',
    description: 'Audit manuscripts, LaTeX tables, figures, and claims',
    category: 'Skill',
    icon: LucideIcons.fileSearch,
  ),
  SlashCommandItem(
    name: 'dataworks',
    description: 'Empirical Stata/R/Python pipelines and data reproducibility',
    category: 'Skill',
    icon: LucideIcons.database,
  ),
  SlashCommandItem(
    name: 'format-tables',
    description: 'Standardize and format academic LaTeX tables & notes',
    category: 'Skill',
    icon: LucideIcons.table,
  ),
  SlashCommandItem(
    name: 'improve-writing',
    description: 'Tighten, structure, and polish academic economics/finance prose',
    category: 'Skill',
    icon: LucideIcons.penTool,
  ),
  SlashCommandItem(
    name: 'slides',
    description: 'Create & edit PowerPoint presentation decks with PptxGenJS',
    category: 'Skill',
    icon: LucideIcons.presentation,
  ),
  SlashCommandItem(
    name: 'security-threat-model',
    description: 'Repository-grounded threat modeling and abuse path analysis',
    category: 'Skill',
    icon: LucideIcons.shieldAlert,
  ),
  SlashCommandItem(
    name: 'jupyter-notebook',
    description: 'Create, scaffold, and edit clean Jupyter notebooks',
    category: 'Skill',
    icon: LucideIcons.bookOpen,
  ),
  SlashCommandItem(
    name: 'ref-report',
    description: 'Produce and validate source-grounded academic referee reports',
    category: 'Skill',
    icon: LucideIcons.fileText,
  ),
  SlashCommandItem(
    name: 'ref-letter-draft',
    description: 'Draft and revise response-to-referee letters for papers',
    category: 'Skill',
    icon: LucideIcons.mail,
  ),
  SlashCommandItem(
    name: 'scoped-text-edit',
    description: 'Lightly edit specified passage for grammar, flow, and continuity',
    category: 'Skill',
    icon: LucideIcons.scissors,
  ),
  SlashCommandItem(
    name: 'verify-theory',
    description: 'Verify formal economics/finance model mathematics & proofs',
    category: 'Skill',
    icon: LucideIcons.checkCheck,
  ),
];

List<SlashCommandItem> filterSlashCommands(
  String input, [
  List<WireSkill>? dynamicSkills,
]) {
  if (!input.startsWith('/')) return const [];
  final raw = input.substring(1);
  if (raw.contains(' ')) return const []; // Command name already completed
  final query = raw.trim().toLowerCase();

  final List<SlashCommandItem> catalog = [
    ...kSlashCommands,
    if (dynamicSkills != null)
      for (final s in dynamicSkills)
        if (!kSlashCommands.any((c) => c.name == s.name))
          SlashCommandItem(
            name: s.name,
            description: s.description,
            category: 'Skill',
            icon: LucideIcons.sparkles,
          ),
  ];

  if (query.isEmpty) return catalog;

  return catalog.where((cmd) {
    return cmd.name.toLowerCase().contains(query) ||
        cmd.description.toLowerCase().contains(query);
  }).toList();
}

class SlashCommandMenu extends StatelessWidget {
  final List<SlashCommandItem> items;
  final ValueChanged<SlashCommandItem> onSelect;

  const SlashCommandMenu({
    super.key,
    required this.items,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    final colors = context.colors;
    final typo = context.typo;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      constraints: const BoxConstraints(maxHeight: 220),
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.border),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.25),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              color: colors.bg,
              child: Row(
                children: [
                  Icon(LucideIcons.slash, size: 13, color: colors.accent),
                  const SizedBox(width: 6),
                  Text(
                    'Commands & Skills',
                    style: typo.mono.copyWith(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: colors.muted,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    '${items.length} available',
                    style: typo.mono.copyWith(
                      fontSize: 10,
                      color: colors.muted,
                    ),
                  ),
                ],
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                itemCount: items.length,
                separatorBuilder: (_, __) => Divider(
                  color: colors.border.withValues(alpha: 0.5),
                  height: 1,
                ),
                itemBuilder: (context, index) {
                  final item = items[index];
                  final isSkill = item.category == 'Skill';

                  return Material(
                    color: Colors.transparent,
                    child: InkWell(
                      onTap: () => onSelect(item),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 9,
                        ),
                        child: Row(
                          children: [
                            Icon(
                              item.icon,
                              size: 15,
                              color: isSkill ? colors.accent : colors.muted,
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Row(
                                    children: [
                                      Text(
                                        '/${item.name}',
                                        style: typo.mono.copyWith(
                                          fontSize: 13,
                                          fontWeight: FontWeight.bold,
                                          color: colors.text,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1,
                                        ),
                                        decoration: BoxDecoration(
                                          color: isSkill
                                              ? colors.accent.withValues(alpha: 0.15)
                                              : colors.border.withValues(alpha: 0.5),
                                          borderRadius: BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          item.category,
                                          style: typo.mono.copyWith(
                                            fontSize: 9,
                                            fontWeight: FontWeight.w600,
                                            color: isSkill ? colors.accent : colors.muted,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 2),
                                  Text(
                                    item.description,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: typo.mono.copyWith(
                                      fontSize: 11,
                                      color: colors.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
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
  }
}
