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
  SlashCommandItem(
    name: 'init',
    description: 'Initialize project configuration & guidelines (CLAUDE.md)',
    icon: LucideIcons.sparkles,
  ),
  SlashCommandItem(
    name: 'compact',
    description: 'Manually compact the session context',
    icon: LucideIcons.minimize2,
  ),
  SlashCommandItem(
    name: 'new',
    description: 'Start a new session',
    icon: LucideIcons.plus,
  ),
  SlashCommandItem(
    name: 'clear',
    description: 'Clear the conversation context in place, keeping the session',
    icon: LucideIcons.trash2,
  ),
  SlashCommandItem(
    name: 'model',
    description: 'Switch model for this session',
    icon: LucideIcons.cpu,
  ),
  SlashCommandItem(
    name: 'goal',
    description: 'Toggle goal mode (persistent autonomous objective for this session)',
    icon: LucideIcons.target,
  ),
  SlashCommandItem(
    name: 'guided-goal',
    description: 'Have the agent interview you in chat, then set up goal mode',
    icon: LucideIcons.compass,
  ),
  SlashCommandItem(
    name: 'loop',
    description: 'Toggle loop mode. While enabled, the next prompt you send re-submits after every yield. Esc cancels the current iteration; /loop again to disable.',
    icon: LucideIcons.repeat,
  ),
  SlashCommandItem(
    name: 'queue',
    description: 'Queue a message for after the agent yields',
    icon: LucideIcons.listPlus,
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
    description: 'Open settings menu',
    icon: LucideIcons.settings,
  ),
  SlashCommandItem(
    name: 'export',
    description: 'Export session to HTML file',
    icon: LucideIcons.download,
  ),
  SlashCommandItem(
    name: 'undo',
    description: 'Undo the last user message and assistant turn',
    icon: LucideIcons.undo2,
  ),
  SlashCommandItem(
    name: 'fork',
    description: 'Create a new fork from a previous message',
    icon: LucideIcons.gitFork,
  ),
  SlashCommandItem(
    name: 'branch',
    description: 'Rewind to a previous message, keeping the old path as a branch',
    icon: LucideIcons.gitCommitVertical,
  ),
  SlashCommandItem(
    name: 'resume',
    description: 'Resume a different session',
    icon: LucideIcons.play,
  ),
  SlashCommandItem(
    name: 'tree',
    description: 'Navigate session tree (switch branches)',
    icon: LucideIcons.folderTree,
  ),
  SlashCommandItem(
    name: 'todo',
    description: 'View or modify the agent\'s todo list',
    icon: LucideIcons.checkSquare,
  ),
  SlashCommandItem(
    name: 'jobs',
    description: 'Show async background jobs status',
    icon: LucideIcons.clock,
  ),
  SlashCommandItem(
    name: 'usage',
    description: 'Show provider usage and limits',
    icon: LucideIcons.barChart2,
  ),
  SlashCommandItem(
    name: 'stats',
    description: 'Launch the local stats dashboard',
    icon: LucideIcons.pieChart,
  ),
  SlashCommandItem(
    name: 'session',
    description: 'Session management commands',
    icon: LucideIcons.folderGit2,
  ),
  SlashCommandItem(
    name: 'tools',
    description: 'Show tools currently visible to the agent',
    icon: LucideIcons.hammer,
  ),
  SlashCommandItem(
    name: 'context',
    description: 'Show estimated context usage breakdown',
    icon: LucideIcons.layers,
  ),
  SlashCommandItem(
    name: 'git',
    description: 'Open the git UI (split diff viewer, staging, commit composer)',
    icon: LucideIcons.gitBranch,
  ),
  SlashCommandItem(
    name: 'hub',
    description: 'Open the live Agent Hub',
    icon: LucideIcons.network,
  ),
  SlashCommandItem(
    name: 'agents',
    description: 'Open the agents hub (per-agent model, prewalk, and advisor)',
    icon: LucideIcons.bot,
  ),
  SlashCommandItem(
    name: 'mcp',
    description: 'Manage MCP servers (add, list, remove, test)',
    icon: LucideIcons.server,
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
  SlashCommandItem(
    name: 'security',
    description: 'Plan, run, inspect, import, and compare OMP-native security scans',
    icon: LucideIcons.shieldCheck,
  ),
  SlashCommandItem(
    name: 'setup',
    description: 'Open provider setup',
    icon: LucideIcons.wrench,
  ),
  SlashCommandItem(
    name: 'plan',
    description: 'Toggle plan mode (agent plans before executing)',
    icon: LucideIcons.listTodo,
  ),
  SlashCommandItem(
    name: 'plan-review',
    description: 'Re-open the plan review for the latest plan (plan mode only)',
    icon: LucideIcons.fileCheck,
  ),
  SlashCommandItem(
    name: 'vibe',
    description: 'Toggle vibe mode (direct persistent fast/good worker sessions; read-only toolset)',
    icon: LucideIcons.zap,
  ),
  SlashCommandItem(
    name: 'switch',
    description: 'Switch model for this session (same as alt+p)',
    icon: LucideIcons.arrowLeftRight,
  ),
  SlashCommandItem(
    name: 'fast',
    description: 'Toggle priority service tier (OpenAI service_tier=priority, Anthropic speed=fast)',
    icon: LucideIcons.gauge,
  ),
  SlashCommandItem(
    name: 'extended-context',
    description: 'Toggle premium long-context windows',
    icon: LucideIcons.maximize2,
  ),
  SlashCommandItem(
    name: 'computer',
    description: 'Toggle the native computer-use tool for this session',
    icon: LucideIcons.monitor,
  ),
  SlashCommandItem(
    name: 'vision',
    description: 'Control the inspect_image vision-delegation tool for this session',
    icon: LucideIcons.eye,
  ),
  SlashCommandItem(
    name: 'prewalk',
    description: 'Switch to a fast/cheap model at the next action (works even without --prewalk)',
    icon: LucideIcons.footprints,
  ),
  SlashCommandItem(
    name: 'advisor',
    description: 'Toggle the advisor (a second model that reviews each turn and injects notes)',
    icon: LucideIcons.userCheck,
  ),
  SlashCommandItem(
    name: 'trace',
    description: 'Open this session\'s trace in the stats dashboard',
    icon: LucideIcons.activity,
  ),
  SlashCommandItem(
    name: 'dump',
    description: 'Copy session transcript to clipboard (and write LLM request JSON to tmp)',
    icon: LucideIcons.clipboardCopy,
  ),
  SlashCommandItem(
    name: 'share',
    description: 'Share session via an encrypted link (share server or secret gist)',
    icon: LucideIcons.share2,
  ),
  SlashCommandItem(
    name: 'collab',
    description: 'Share this session live via a relay',
    icon: LucideIcons.users,
  ),
  SlashCommandItem(
    name: 'join',
    description: 'Join a shared collab session',
    icon: LucideIcons.logIn,
  ),
  SlashCommandItem(
    name: 'leave',
    description: 'Leave the collab session',
    icon: LucideIcons.logOut,
  ),
  SlashCommandItem(
    name: 'browser',
    description: 'Toggle browser headless vs visible mode',
    icon: LucideIcons.globe,
  ),
  SlashCommandItem(
    name: 'copy',
    description: 'Pick text or code from the conversation to copy',
    icon: LucideIcons.copy,
  ),
  SlashCommandItem(
    name: 'changelog',
    description: 'Show changelog entries',
    icon: LucideIcons.newspaper,
  ),
  SlashCommandItem(
    name: 'hotkeys',
    description: 'Show all keyboard shortcuts',
    icon: LucideIcons.keyboard,
  ),
  SlashCommandItem(
    name: 'extensions',
    description: 'Open Extension Control Center dashboard',
    icon: LucideIcons.blocks,
  ),
  SlashCommandItem(
    name: 'login',
    description: 'Login with OAuth provider',
    icon: LucideIcons.key,
  ),
  SlashCommandItem(
    name: 'logout',
    description: 'Logout from OAuth provider',
    icon: LucideIcons.logOut,
  ),
  SlashCommandItem(
    name: 'ssh',
    description: 'Manage SSH hosts (add, list, remove)',
    icon: LucideIcons.terminal,
  ),
  SlashCommandItem(
    name: 'fresh',
    description: 'Reset provider stream state without changing the local transcript',
    icon: LucideIcons.refreshCw,
  ),
  SlashCommandItem(
    name: 'drop',
    description: 'Delete the current session and start a new one',
    icon: LucideIcons.trash,
  ),
  SlashCommandItem(
    name: 'shake',
    description: 'Drop heavy content from context (tool results, large blocks)',
    icon: LucideIcons.scissors,
  ),
  SlashCommandItem(
    name: 'handoff',
    description: 'Hand off session context to a new session',
    icon: LucideIcons.arrowRightCircle,
  ),
  SlashCommandItem(
    name: 'pin',
    description: 'Pin or unpin a session at the top of the resume list',
    icon: LucideIcons.pin,
  ),
  SlashCommandItem(
    name: 'btw',
    description: 'Ask an ephemeral side question using the current session context',
    icon: LucideIcons.messageCircleQuestion,
  ),
  SlashCommandItem(
    name: 'tan',
    description: 'Run a full background agent on tangential work',
    icon: LucideIcons.split,
  ),
  SlashCommandItem(
    name: 'omfg',
    description: 'Forge a TTSR rule from a complaint to stop a recurring behavior',
    icon: LucideIcons.alertTriangle,
  ),
  SlashCommandItem(
    name: 'cleanse',
    description: 'Detect and fix project diagnostics with weighted parallel subagents',
    icon: LucideIcons.stethoscope,
  ),
  SlashCommandItem(
    name: 'retry',
    description: 'Retry the last failed agent turn',
    icon: LucideIcons.rotateCcw,
  ),
  SlashCommandItem(
    name: 'debug',
    description: 'Open debug tools selector',
    icon: LucideIcons.bug,
  ),
  SlashCommandItem(
    name: 'memory',
    description: 'Inspect and operate memory maintenance',
    icon: LucideIcons.hardDrive,
  ),
  SlashCommandItem(
    name: 'rename',
    description: 'Rename the current session',
    icon: LucideIcons.edit3,
  ),
  SlashCommandItem(
    name: 'move',
    description: 'Move the current session to a different directory',
    icon: LucideIcons.folderInput,
  ),
  SlashCommandItem(
    name: 'add-dir',
    description: 'Add a workspace directory to this session (multi-root)',
    icon: LucideIcons.folderPlus,
  ),
  SlashCommandItem(
    name: 'remove-dir',
    description: 'Remove a workspace directory from this session',
    icon: LucideIcons.folderMinus,
  ),
  SlashCommandItem(
    name: 'dirs',
    description: 'List this session\'s workspace directories',
    icon: LucideIcons.folder,
  ),
  SlashCommandItem(
    name: 'exit',
    description: 'Exit the application',
    icon: LucideIcons.power,
  ),
  SlashCommandItem(
    name: 'restart',
    description: 'Restart omp with the same launch flags, resuming this session',
    icon: LucideIcons.rotateCw,
  ),
  SlashCommandItem(
    name: 'marketplace',
    description: 'Manage marketplace plugin sources and installed plugins',
    icon: LucideIcons.store,
  ),
  SlashCommandItem(
    name: 'plugins',
    description: 'View and manage installed plugins',
    icon: LucideIcons.plug,
  ),
  SlashCommandItem(
    name: 'reload-plugins',
    description: 'Reload all plugins (skills, commands, hooks, tools, agents, MCP)',
    icon: LucideIcons.refreshCw,
  ),
  SlashCommandItem(
    name: 'force',
    description: 'Force next turn to use a specific tool',
    icon: LucideIcons.shieldAlert,
  ),
  SlashCommandItem(
    name: 'live',
    description: 'Start Codex-backed realtime voice mode',
    icon: LucideIcons.mic,
  ),
  SlashCommandItem(
    name: 'pause',
    description: 'Freeze all agents (main, subagents, advisor) until resumed',
    icon: LucideIcons.pause,
  ),
  SlashCommandItem(
    name: 'quit',
    description: 'Quit the application',
    icon: LucideIcons.xCircle,
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
