const allSourcesEnabled = bool.fromEnvironment('ALL_SOURCES');
const televisionOnly = bool.fromEnvironment('TELEVISION_ONLY');
const appName = allSourcesEnabled ? '真果鉴' : '红果鉴';
const appSlug = allSourcesEnabled ? 'zhenguojian' : 'hongguojian';
