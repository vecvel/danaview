import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:danaview_editor/danaview_editor.dart';
import 'package:danaview_features/danaview_features.dart';

String folderLocation(String path) => '/folder?path=${Uri.encodeQueryComponent(path)}';

String playlistLocation(String name) => '/playlist/${Uri.encodeComponent(name)}';

String settingsLocation(SettingsDestination destination) => '/settings/${destination.path}';

/// The Projects screen of the video editor (ARCH §17.1).
const projectsLocation = '/projects';

/// The editor's settings, an explicit child of `/settings` (not a [SettingsDestination] value).
const editorSettingsLocation = '/settings/editor';

/// The editor on [id], seeking exactly to [initialPlayhead] (µs) on open (ARCH §17.1).
String editorLocation(ProjectId id, {TimeUs? initialPlayhead}) {
  final path = '/editor/${Uri.encodeComponent(id)}';
  return initialPlayhead == null ? path : '$path?t=$initialPlayhead';
}

/// Opens the Projects screen (Home edit button, Settings › Storage "Open projects").
void openProjects(BuildContext context) => context.push(projectsLocation);

/// Whether the editor is reachable: iOS/Android with `DANAVIEW_EDITOR` (D-17, D-31) and wired by
/// `EditorBootstrap` (a failed wiring hides it like an unsupported platform).
bool editorReachable(BuildContext context) {
  if (!EditorAvailability.showsEntryPoints) return false;
  final container = ProviderScope.containerOf(context, listen: false);
  return container.read(editorRuntimeProvider) != null;
}

String? _editorGate(BuildContext context, GoRouterState state) => editorReachable(context) ? null : '/';

/// The `t` query parameter (µs, non-negative), or null.
TimeUs? _initialPlayheadOf(GoRouterState state) {
  final t = int.tryParse(state.uri.queryParameters['t'] ?? '');
  return t == null || t < 0 ? null : t;
}

void _back(BuildContext context) => context.canPop() ? context.pop() : context.go('/');

Widget _settingsPage(BuildContext context, SettingsDestination destination) {
  void back() => _back(context);
  return switch (destination) {
    SettingsDestination.profile => DanaviewProfileScreen(onBack: back),
    SettingsDestination.speedTest => DanaviewSpeedTestScreen(onBack: back),
    SettingsDestination.streamCheck => DanaviewStreamCheckScreen(onBack: back, onOpenPlayer: () => context.push('/player')),
    SettingsDestination.mediaInfo => DanaviewMediaInfoScreen(onBack: back),
    SettingsDestination.dataUsage => DanaviewDataUsageScreen(onBack: back),
    SettingsDestination.storage => DanaviewStorageScreen(onBack: back),
    SettingsDestination.about => DanaviewAboutScreen(
        onBack: back,
        onOpenPrivacy: () => context.push(settingsLocation(SettingsDestination.privacy)),
        onOpenTerms: () => context.push(settingsLocation(SettingsDestination.terms)),
      ),
    SettingsDestination.privacy => DanaviewLegalScreen(document: LegalDocument.privacy, onBack: back),
    SettingsDestination.terms => DanaviewLegalScreen(document: LegalDocument.terms, onBack: back),
  };
}

/// Pages are nested under Home so Back always has somewhere to go, even after a deep link.
GoRouter createAppRouter() => GoRouter(
      initialLocation: '/',
      // Unknown locations (e.g. a file URL the OS handed over) land on Home instead of an error page.
      onException: (context, state, router) => router.go('/'),
      routes: [
        GoRoute(
          path: '/',
          name: 'home',
          builder: (context, state) => DanaviewHomeScreen(
            onOpenPlayer: () => context.push('/player'),
            onOpenFolder: (path) => context.push(folderLocation(path)),
            onOpenPlaylist: (name) => context.push(playlistLocation(name)),
            onOpenSettings: () => context.push('/settings'),
            onOpenEditor: editorReachable(context) ? () => openProjects(context) : null,
          ),
          routes: [
            GoRoute(
              path: 'settings',
              name: 'settings',
              builder: (context, state) => DanaviewSettingsScreen(
                onBack: () => _back(context),
                onNavigate: (destination) => context.push(settingsLocation(destination)),
                onOpenEditorSettings: editorReachable(context) ? () => context.push(editorSettingsLocation) : null,
              ),
              routes: [
                for (final destination in SettingsDestination.values)
                  GoRoute(
                    path: destination.path,
                    builder: (context, state) => _settingsPage(context, destination),
                  ),
                GoRoute(
                  path: 'editor',
                  name: 'editorSettings',
                  redirect: _editorGate,
                  builder: (context, state) => EditorSettingsScreen(onBack: () => _back(context)),
                ),
              ],
            ),
            GoRoute(
              path: 'projects',
              name: 'projects',
              redirect: _editorGate,
              builder: (context, state) => ProjectsScreen(
                onBack: () => _back(context),
                onOpenProject: (id, {initialPlayhead}) => context.push(editorLocation(id, initialPlayhead: initialPlayhead)),
                onManageStorage: () => context.push(settingsLocation(SettingsDestination.storage)),
              ),
            ),
            GoRoute(
              path: 'editor/:projectId',
              name: 'editor',
              redirect: _editorGate,
              builder: (context, state) {
                final id = ProjectId(state.pathParameters['projectId']!);
                return EditorScreen(
                  key: ValueKey(id),
                  projectId: id,
                  initialPlayhead: _initialPlayheadOf(state),
                  onClose: () => _back(context),
                  onOpenProjects: () => context.go(projectsLocation),
                );
              },
            ),
            GoRoute(
              path: 'player',
              name: 'player',
              builder: (context, state) => DanaviewPlayerScreen(onBack: () => _back(context)),
            ),
            GoRoute(
              path: 'folder',
              name: 'folder',
              redirect: (context, state) => (state.uri.queryParameters['path'] ?? '').isEmpty ? '/' : null,
              builder: (context, state) {
                final path = state.uri.queryParameters['path']!;
                return DanaviewFolderScreen(
                  key: ValueKey(path),
                  path: path,
                  onBack: () => _back(context),
                  onOpenFolder: (child) => context.push(folderLocation(child)),
                  onJumpToFolder: (ancestor) => context.go(folderLocation(ancestor)),
                  onOpenPlayer: () => context.push('/player'),
                );
              },
            ),
            GoRoute(
              path: 'playlist/:name',
              name: 'playlist',
              builder: (context, state) {
                final name = state.pathParameters['name']!;
                return DanaviewPlaylistScreen(
                  key: ValueKey(name),
                  name: name,
                  onBack: () => _back(context),
                  onOpenPlayer: () => context.push('/player'),
                  onRenamed: (newName) => context.replace(playlistLocation(newName)),
                );
              },
            ),
          ],
        ),
      ],
    );
