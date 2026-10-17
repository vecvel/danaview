/// Pages reachable from the Settings screen; [path] is the route segment under `/settings`.
enum SettingsDestination {
  profile('profile'),
  speedTest('speed-test'),
  streamCheck('stream-check'),
  mediaInfo('media-info'),
  dataUsage('data-usage'),
  storage('storage'),
  about('about'),
  privacy('privacy'),
  terms('terms');

  const SettingsDestination(this.path);

  final String path;
}
