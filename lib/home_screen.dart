import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'app_layout.dart';
import 'core_bridge.dart';
import 'catalog_filters.dart';
import 'catalog_browser.dart';
import 'catalog_sort.dart';
import 'catalog_sort_sheet.dart';
import 'recommendations_screen.dart';
import 'rankings_screen.dart';
import 'detail_screen.dart';
import 'downloads_screen.dart';
import 'local_store.dart';
import 'lan_screen.dart';
import 'models.dart';
import 'remote_widgets.dart';
import 'widgets.dart';
import 'vip_icon.dart';
import 'settings_screen.dart';
import 'profiles_screen.dart';
import 'source_gate_dialog.dart';
import 'source_gate_taps.dart';
import 'sources_screen.dart';
import 'batch_download_screen.dart';
import 'batch_downloads.dart';
import 'drama_actions.dart';
import 'library_updater.dart';
import 'saved_library.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key, required this.repository, required this.store});
  final AppRepository repository;
  final LocalStore store;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  static const _recommendationCategory = 'app:recommendations';
  final _search = TextEditingController();
  final _scroll = ScrollController();
  Timer? _debounce;
  late SourceSite _source;
  bool _allSources = false;
  List<Drama> _items = [];
  bool _loading = true;
  bool _loadingMore = false;
  bool _hasMore = true;
  String? _error;
  int _generation = 0;
  int _tab = 0;
  String _submittedQuery = '';
  bool _failedMore = false;
  final _categorySelections = <String, String>{};
  late final CatalogBrowser _browser;
  bool _categoriesLoading = false;
  String? _categoriesError;
  int _categoryGeneration = 0;
  late final LibraryUpdater _updater;
  final _changedSources = <String>{};
  final _selectedDramas = <String, Drama>{};
  Timer? _cacheRefreshTimer;
  bool _refreshingUpdatedCache = false;
  bool _updateNotice = false;
  bool _selectionMode = false;
  bool _showRecommendations = false;
  final _recentTaps = RepeatTapGate();
  String _sourceSignature = '';
  List<SourceGroup> get _sourceGroups {
    final groups = SourceGroup.fromSources(widget.store.sources);
    return [
      if (groups.length > 1) SourceGroup('all', '全部站源', widget.store.sources),
      ...groups,
    ];
  }

  SourceGroup get _group =>
      _sourceGroups
          .where((group) => group.id == (_allSources ? 'all' : _source.groupId))
          .firstOrNull ??
      SourceGroup(_source.groupId, _source.groupName, [_source]);
  bool get _onlineSearch => _group.sources.any((source) => source.onlineSearch);
  bool get _searchSuggestions =>
      _group.sources.any((source) => source.searchSuggestions);

  String get _category => _categorySelections[_group.id] ?? '';
  List<CatalogCategory> get _categories => _browser.categories(_group);
  String get _displayCategory =>
      _showRecommendations ? _recommendationCategory : _category;
  List<CatalogCategory> get _displayCategories => [
    CatalogCategory.all,
    if (_group.id == 'hongguo')
      const CatalogCategory(_recommendationCategory, '推荐'),
    ..._categories.where((entry) => entry.id.isNotEmpty),
  ];

  Future<void> _loadCategories({
    bool force = false,
    bool cacheOnly = false,
  }) async {
    final generation = ++_categoryGeneration;
    final group = _group;
    setState(() {
      _categoriesLoading = true;
      _categoriesError = null;
    });
    final error = await _browser.loadCategories(
      group,
      force: force,
      cacheOnly: cacheOnly,
    );
    if (!mounted ||
        generation != _categoryGeneration ||
        group.id != _group.id) {
      return;
    }
    setState(() {
      _categoriesLoading = false;
      _categoriesError = error;
    });
    if (!_showRecommendations &&
        _category.isNotEmpty &&
        !_categories.any((entry) => entry.id == _category)) {
      _changeCategory('');
    }
  }

  Future<void> _refreshCatalog() async {
    if (widget.repository.supportsSourceManagement) {
      if (_group.sources.any((source) => _updater.busy(source.id))) return;
      _pauseCatalog();
      setState(() => _updateNotice = true);
      await _updater.update(_group.sources);
      return;
    }
    await _loadCategories(force: true);
    if (mounted) await _load(force: true);
  }

  void _updateChanged() {
    if (mounted) setState(() {});
  }

  /// 密码锁切换后可见站源会变，这里把当前站源归一化到仍然可见的站源。
  void _sourcesChanged() {
    if (!mounted) return;
    final visible = widget.store.sources;
    final signature = visible.map((site) => site.id).join(',');
    if (signature == _sourceSignature) return;
    final wasEmpty = _sourceSignature.isEmpty;
    _sourceSignature = signature;
    if (visible.isEmpty) {
      setState(() {
        _items = [];
        _hasMore = false;
        _loading = false;
        _loadingMore = false;
      });
      return;
    }
    final allowed = visible.map((site) => site.id).toSet();
    if (!wasEmpty &&
        allowed.contains(_source.id) &&
        _source.id == widget.store.source) {
      return;
    }
    _changeSource(SourceSite.byId(widget.store.source));
  }

  void _catalogUpdated(String source) {
    if (!mounted) return;
    _changedSources.add(source);
    _cacheRefreshTimer?.cancel();
    _cacheRefreshTimer = Timer(const Duration(milliseconds: 100), () {
      unawaited(_reloadUpdatedCache());
    });
  }

  Future<void> _reloadUpdatedCache() async {
    if (_refreshingUpdatedCache) return;
    _refreshingUpdatedCache = true;
    final epoch = widget.store.profileEpoch;
    try {
      while (mounted &&
          _changedSources.isNotEmpty &&
          epoch == widget.store.profileEpoch) {
        final sources = Set.of(_changedSources);
        _changedSources.clear();
        final updates = <String, Drama>{};
        for (final source in sources) {
          if (!widget.store.allowsSource(source)) continue;
          try {
            final cached = await widget.repository.cached(source);
            for (final drama in cached.items) {
              if (widget.store.allowsSource(drama.source)) {
                updates[drama.id] = drama;
              }
            }
          } catch (error) {
            if (mounted && epoch == widget.store.profileEpoch) {
              setState(() => _error = '更新后读取缓存失败：$error');
            }
          }
        }
        if (!mounted || epoch != widget.store.profileEpoch) return;
        _browser.updateDramas(updates.values);
        setState(() {
          _items = [
            for (final item in _items)
              updates[item.id] == null ? item : item.merge(updates[item.id]!),
          ];
          for (final id in _selectedDramas.keys.toList()) {
            if (updates[id] != null) {
              _selectedDramas[id] = _selectedDramas[id]!.merge(updates[id]!);
            }
          }
        });
        await saveUserChange(
          context,
          () => widget.store.refreshDramas(updates.values),
        );
        if (!mounted || epoch != widget.store.profileEpoch) return;
        if (_group.sources.any((source) => sources.contains(source.id))) {
          await _loadCategories(cacheOnly: true);
          if (mounted &&
              !_loading &&
              !_loadingMore &&
              (!_onlineSearch || _search.text.trim().isEmpty)) {
            await _load(cacheOnly: true);
          }
        }
      }
    } finally {
      _refreshingUpdatedCache = false;
    }
  }

  void _changeGroup(SourceGroup group) {
    if (_group.id != group.id) {
      _changeSource(group.sources.first, allSources: group.id == 'all');
    }
  }

  void _changeCategory(String category) {
    if (category == _recommendationCategory && _group.id == 'hongguo') {
      if (_showRecommendations) return;
      _pauseCatalog();
      setState(() {
        _showRecommendations = true;
        _selectionMode = false;
        _selectedDramas.clear();
        _search.clear();
        _submittedQuery = '';
      });
      return;
    }
    if (_category == category && !_showRecommendations) return;
    _debounce?.cancel();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _categorySelections[_group.id] = category;
      if (_onlineSearch) {
        _search.clear();
        _submittedQuery = '';
      }
      _items = [];
      _hasMore = true;
      _error = null;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _load(useCache: true);
  }

  void _toggleSearch() => unawaited(_televisionSearch());

  void _openRankings() {
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => RankingsScreen(
          repository: widget.repository,
          store: widget.store,
          initialGroup: _group.id,
        ),
      ),
    );
  }

  Future<void> _manageSources() async {
    _pauseCatalog();
    await Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => SourcesScreen(
          repository: widget.repository,
          store: widget.store,
          initialSource: _source.id,
        ),
      ),
    );
    if (!mounted) return;
    await _loadCategories();
    if (mounted && (!_onlineSearch || _submittedQuery.isEmpty)) {
      await _load(useCache: true);
    }
  }

  Future<void> _televisionSearch() async {
    final query = await showDialog<String>(
      context: context,
      builder: (_) => TelevisionSearchDialog(
        initialValue: _search.text,
        title: _group.id == 'all'
            ? '搜索已开放站源'
            : _onlineSearch
            ? '搜索${_group.name}短剧'
            : '筛选当前已加载短剧',
        recentSearches: widget.store.recentSearches,
        onCancel: () => unawaited(widget.repository.cancelSuggestions()),
        suggestions: _searchSuggestions ? widget.repository.suggestions : null,
      ),
    );
    if (query != null && mounted) {
      _submitSearch(query);
    }
  }

  void _televisionBack() {
    if (_selectionMode) {
      _cancelSelection();
    } else if (_tab != 0) {
      setState(() => _tab = 0);
    } else if (_search.text.isNotEmpty) {
      _search.clear();
      _searchChanged('');
    }
  }

  @override
  void initState() {
    super.initState();
    _source = SourceSite.byId(widget.store.source);
    _allSources = widget.store.catalogView.allSources;
    _sourceSignature = widget.store.sources.map((site) => site.id).join(',');
    _browser = CatalogBrowser(widget.repository);
    _scroll.addListener(_maybeLoadMore);
    _updater = LibraryUpdater(
      widget.repository,
      widget.store,
      onCatalogChanged: _catalogUpdated,
    )..addListener(_updateChanged);
    _updater.startWatching();
    widget.store.addListener(_sourcesChanged);
    widget.repository.catalogUpdates.addListener(_metadataChanged);
    if (widget.store.sources.isNotEmpty) {
      _load(useCache: true);
      _loadCategories();
    } else {
      _loading = false;
    }
  }

  @override
  void dispose() {
    _updater.removeListener(_updateChanged);
    _updater.dispose();
    _cacheRefreshTimer?.cancel();
    widget.store.removeListener(_sourcesChanged);
    widget.repository.catalogUpdates.removeListener(_metadataChanged);
    _generation++;
    _categoryGeneration++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    _debounce?.cancel();
    _scroll.removeListener(_maybeLoadMore);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  /// 滚动接近底部时自动翻页（TVBox 影视壳式体验），无需手动点“加载更多”。
  /// 失败过的页不自动重试，避免滚动到底时反复打无效请求。
  void _maybeLoadMore() {
    if (!mounted || !_scroll.hasClients) return;
    if (_loading || _loadingMore || !_hasMore || _failedMore) return;
    if (_showRecommendations) return;
    final position = _scroll.position;
    if (!position.hasContentDimensions) return;
    if (position.pixels < position.maxScrollExtent - 400) return;
    unawaited(_load(more: true));
  }

  /// 目录底部状态：加载中 / 失败重试 / 可继续下滑 / 已到底。
  /// 自动翻页由 [_maybeLoadMore] 驱动，这里只在失败时给出可点的重试入口。
  ///
  /// 注意：非 loading 分支不能放 CircularProgressIndicator —— 无限动画会让
  /// widget 测试的 pumpAndSettle 永远等不到静止（已踩过这个坑）。
  Widget _catalogFooter(BuildContext context) {
    if (_loadingMore) {
      return const CircularProgressIndicator();
    }
    if (_failedMore) {
      return RemoteButton(
        label: '加载失败，重试',
        icon: Icons.refresh,
        onPressed: () => _load(more: true),
      );
    }
    final hint = Text(
      _hasMore ? '继续下滑自动加载' : '已经看到这里的全部剧集',
      style: TextStyle(
        color: Theme.of(context).colorScheme.onSurfaceVariant,
        fontSize: 12,
      ),
    );
    return hint;
  }

  void _metadataChanged() {
    final drama = widget.repository.catalogUpdates.latest;
    if (!mounted || drama == null || !widget.store.allowsSource(drama.source)) {
      return;
    }
    _browser.updateDrama(drama);
    setState(() {
      _items = [
        for (final item in _items)
          item.id == drama.id ? item.merge(drama) : item,
      ];
    });
    unawaited(saveUserChange(context, () => widget.store.refreshDrama(drama)));
  }

  Future<void> _load({
    bool more = false,
    bool useCache = false,
    bool force = false,
    bool cacheOnly = false,
  }) async {
    if (_showRecommendations) return;
    if (more && (_loading || _loadingMore || !_hasMore)) return;
    final generation = ++_generation;
    final group = _group;
    final query = _onlineSearch ? _search.text.trim() : '';
    setState(() {
      _error = null;
      if (query.isNotEmpty) _categorySelections[group.id] = '';
      _failedMore = false;
      if (more) {
        _loadingMore = true;
      } else {
        _loading = true;
        _loadingMore = false;
        if (query != _submittedQuery) _items = [];
      }
    });
    void accept(CatalogPage result, {bool cached = false}) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _items = result.items;
        _hasMore = result.hasMore;
        _submittedQuery = query;
        _loading = cached && !result.fresh;
        _loadingMore = false;
        _error = result.warning.isEmpty ? null : result.warning;
      });
      unawaited(
        saveUserChange(context, () => widget.store.refreshDramas(result.items)),
      );
    }

    try {
      final result = await _browser.load(
        group,
        category: _category,
        query: query,
        more: more,
        useCache: useCache,
        force: force,
        cacheOnly: cacheOnly,
        onCached: (result) => accept(result, cached: true),
      );
      accept(result);
    } catch (error) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _loading = false;
        _loadingMore = false;
        _error = error.toString();
        _failedMore = more;
      });
    }
  }

  void _changeSource(SourceSite source, {bool allSources = false}) {
    if (_source.id == source.id && _allSources == allSources) {
      return;
    }
    _debounce?.cancel();
    _search.clear();
    setState(() {
      _showRecommendations = false;
      _selectionMode = false;
      _selectedDramas.clear();
      _updateNotice = false;
      _source = source;
      _allSources = allSources;
      _items = [];
      _hasMore = true;
      _submittedQuery = '';
      _error = null;
    });
    unawaited(
      saveUserChange(
        context,
        () => widget.store.setCatalogSource(source.id, allSources: allSources),
      ),
    );
    if (_scroll.hasClients) {
      _scroll.jumpTo(0);
    }
    _load(useCache: true);
    _loadCategories();
  }

  void _searchChanged(String query) {
    _debounce?.cancel();
    _selectionMode = false;
    _selectedDramas.clear();
    if (_onlineSearch && (_loading || _loadingMore)) {
      _generation++;
      unawaited(_browser.cancel());
      _loading = _loadingMore = false;
    }
    setState(() {});
    if (_onlineSearch && query.trim().isEmpty) {
      _debounce = Timer(const Duration(milliseconds: 300), () => _load());
    }
  }

  void _submitSearch(String query) {
    if (_showRecommendations) {
      _showRecommendations = false;
      _categorySelections[_group.id] = '';
    }
    _selectionMode = false;
    _selectedDramas.clear();
    _search.text = query.trim();
    _debounce?.cancel();
    if (_search.text.isNotEmpty) {
      unawaited(
        saveUserChange(
          context,
          () => widget.store.rememberSearch(_search.text),
        ),
      );
    }
    if (_onlineSearch) {
      _load();
    } else {
      setState(() {});
    }
  }

  Future<void> _chooseCatalogView() async {
    final selected = await chooseCatalogView(context, widget.store.catalogView);
    if (selected != null && mounted) {
      await saveUserChange(
        context,
        () => widget.store.setCatalogView(selected),
      );
      if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
    }
  }

  void _openDrama(Drama drama, {bool resume = false, bool download = false}) {
    _pauseCatalog();
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => DetailScreen(
          drama: drama,
          repository: widget.repository,
          store: widget.store,
          resumeOnOpen: resume,
          downloadOnOpen: download,
        ),
      ),
    );
  }

  void _changeTab(int tab) => setState(() {
    _tab = tab;
    _selectionMode = false;
    _selectedDramas.clear();
  });

  /// 连点「最近观看」6 次弹出站源密码锁（用于启用 / 关闭密码功能）。
  void _onNavSelected(int tab) {
    if (tab == 2) {
      if (_recentTaps.register(tab)) {
        _openSourceGate();
        return;
      }
    } else {
      _recentTaps.reset();
    }
    _changeTab(tab);
  }

  void _openSourceGate() {
    _pauseCatalog();
    unawaited(showSourceGateDialog(context, widget.store));
  }

  void _cancelSelection() => setState(() {
    _selectionMode = false;
    _selectedDramas.clear();
  });

  void _selectDrama(Drama drama) {
    if (!widget.store.canDownload ||
        !widget.repository.supportsDownloads ||
        !widget.store.allowsSource(drama.source)) {
      return;
    }
    if (!_selectedDramas.containsKey(drama.id) &&
        _selectedDramas.length >= BatchDownloads.maxDramas) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('一次最多选择 50 部短剧，请分批下载')));
      return;
    }
    setState(() {
      _selectionMode = true;
      if (_selectedDramas.remove(drama.id) == null) {
        _selectedDramas[drama.id] = drama;
      }
    });
  }

  void _downloadSelected() {
    if (!widget.store.canDownload || _selectedDramas.isEmpty) return;
    _pauseCatalog();
    Navigator.push<void>(
      context,
      MaterialPageRoute(
        builder: (_) => BatchDownloadScreen(
          repository: widget.repository,
          store: widget.store,
          dramas: _selectedDramas.values.toList(),
        ),
      ),
    );
  }

  void _dramaActions(Drama drama) => showDramaActions(
    context,
    drama: drama,
    store: widget.store,
    onContinue: () => _openDrama(drama, resume: true),
    onDownload: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _openDrama(drama, download: true)
        : null,
    onSelect: widget.repository.supportsDownloads && widget.store.canDownload
        ? () => _selectDrama(drama)
        : null,
  );

  Widget _catalogTile(
    Drama drama, {
    FocusNode? focusNode,
    VoidCallback? onFocus,
  }) {
    final following = widget.store.following(drama.id);
    final canSelect =
        widget.store.canDownload && widget.repository.supportsDownloads;
    return DramaTile(
      key: ValueKey(drama.id),
      drama: drama,
      repository: widget.repository,
      focusNode: focusNode,
      onFocus: onFocus,
      onTap: () => _selectionMode ? _selectDrama(drama) : _openDrama(drama),
      onLongPress: canSelect ? () => _selectDrama(drama) : null,
      onMore: () => _dramaActions(drama),
      actions: DramaActionButton(
        drama: drama,
        onPressed: () => _dramaActions(drama),
      ),
      selected: _selectionMode ? _selectedDramas.containsKey(drama.id) : null,
      badge: following == null
          ? null
          : '${following.status.label}${following.newEpisodes > 0 ? ' · 更新 ${following.newEpisodes} 集' : ''}',
    );
  }

  void _pauseCatalog() {
    _debounce?.cancel();
    _generation++;
    unawaited(_browser.cancel());
    unawaited(widget.repository.cancelSuggestions());
    setState(() {
      _loading = false;
      _loadingMore = false;
    });
  }

  bool get _supportsVipFilter =>
      _group.sources.any((source) => source.id == 'huangdou');
  bool get _hideVip => _supportsVipFilter && widget.store.hideVip;

  List<Drama> get _visible {
    final query = _search.text.trim().toLowerCase();
    return sortCatalog(
      _items.where((drama) {
        if (!widget.store.allowsSource(drama.source)) return false;
        if (_category.startsWith('local:') &&
            categoryName(drama.category) != _category.substring(6)) {
          return false;
        }
        if (_hideVip && drama.source == 'huangdou' && drama.vip) {
          return false;
        }
        return _onlineSearch ||
            query.isEmpty ||
            matchesDramaQuery(drama, query);
      }),
      widget.store.catalogView,
    );
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.store,
    builder: (context, _) => LayoutBuilder(
      builder: (context, constraints) {
        final scaffold = Scaffold(
          appBar: AppBar(
            toolbarHeight: 64,
            titleSpacing: 12,
            title: _selectionMode
                ? const Text(
                    '选择短剧',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  )
                : _tab == 0
                ? PopupMenuButton<SourceGroup>(
                    key: const ValueKey('source-switch'),
                    tooltip: '切换站源',
                    enabled: _sourceGroups.length > 1,
                    onSelected: _changeGroup,
                    itemBuilder: (_) => [
                      for (final group in _sourceGroups)
                        PopupMenuItem(
                          value: group,
                          child: Row(
                            children: [
                              Expanded(child: Text(group.name)),
                              if (group.id == _group.id)
                                const Icon(Icons.check_rounded, size: 20),
                            ],
                          ),
                        ),
                    ],
                    child: SizedBox(
                      height: 48,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Flexible(
                            child: Text(
                              _group.name,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          if (_sourceGroups.length > 1)
                            const Icon(Icons.expand_more_rounded),
                        ],
                      ),
                    ),
                  )
                : const Text(appName),
            actions: [
              if (_selectionMode) ...[
                TextButton(
                  key: const ValueKey('clear-catalog-selection'),
                  onPressed: _selectedDramas.isEmpty
                      ? null
                      : () => setState(_selectedDramas.clear),
                  child: const Text('清空'),
                ),
                TextButton(
                  key: const ValueKey('cancel-catalog-selection'),
                  onPressed: _cancelSelection,
                  child: const Text('取消'),
                ),
              ] else ...[
                if (_tab == 1)
                  IconButton(
                    key: const ValueKey('follow-lan-sync'),
                    tooltip: '追剧同步',
                    onPressed: () => openLanSync(context),
                    icon: const Icon(Icons.sync_rounded),
                  ),
                if (_tab == 0) ...[
                  if (!_showRecommendations)
                    IconButton(
                      tooltip: '排序与筛选 · ${widget.store.catalogView.sort.label}',
                      onPressed: _chooseCatalogView,
                      color:
                          widget.store.catalogView.sort != CatalogSort.source ||
                              widget.store.catalogView.release.isNotEmpty
                          ? Theme.of(context).colorScheme.primary
                          : null,
                      icon: const Icon(Icons.sort_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('open-rankings'),
                    tooltip: '榜单',
                    onPressed: widget.store.sources.isEmpty
                        ? null
                        : _openRankings,
                    icon: const Icon(Icons.leaderboard_outlined),
                  ),
                  if (!_showRecommendations &&
                      widget.store.canDownload &&
                      widget.repository.supportsDownloads)
                    IconButton(
                      key: const ValueKey('select-catalog-dramas'),
                      tooltip: '多选下载',
                      onPressed: () => setState(() => _selectionMode = true),
                      icon: const Icon(Icons.checklist_rounded),
                    ),
                  IconButton(
                    key: const ValueKey('toggle-search'),
                    tooltip: '搜索',
                    icon: const Icon(Icons.search_rounded),
                    onPressed: _toggleSearch,
                  ),
                ],
                if (_tab == 0 &&
                    !_showRecommendations &&
                    constraints.maxWidth >= 400)
                  RefreshAction(
                    key: const ValueKey('catalog-refresh'),
                    loading:
                        _loading ||
                        _loadingMore ||
                        _categoriesLoading ||
                        _group.sources.any(
                          (source) => _updater.busy(source.id),
                        ),
                    tooltip: '更新剧库',
                    onPressed: widget.store.sources.isEmpty
                        ? null
                        : _refreshCatalog,
                  ),
                PopupMenuButton<String>(
                  tooltip: '更多',
                  onSelected: (value) {
                    if (value == 'update') {
                      _refreshCatalog();
                    } else if (value == 'sources') {
                      _manageSources();
                    } else if (value == 'settings') {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => SettingsScreen(
                            repository: widget.repository,
                            store: widget.store,
                          ),
                        ),
                      );
                    } else if (value == 'users') {
                      Navigator.push(
                        context,
                        MaterialPageRoute<void>(
                          builder: (_) => ProfilesScreen(store: widget.store),
                        ),
                      );
                    } else if (value == 'about') {
                      showAboutDialog(
                        context: context,
                        applicationName: appName,
                        applicationVersion: AppLayout.versionOf(context),
                        applicationIcon: const Icon(
                          Icons.play_circle_filled_rounded,
                          size: 48,
                          color: Color(0xFFFF765F),
                        ),
                        children: [
                          const Text('独立运行，打开即可浏览和播放。观看记录与追剧收藏保存在当前设备。'),
                        ],
                      );
                    }
                  },
                  itemBuilder: (_) => [
                    if (_tab == 0 &&
                        !_showRecommendations &&
                        constraints.maxWidth < 400)
                      PopupMenuItem(
                        value: 'update',
                        enabled:
                            widget.store.sources.isNotEmpty &&
                            !_group.sources.any(
                              (source) => _updater.busy(source.id),
                            ),
                        child: const Text('更新剧库'),
                      ),
                    if (widget.repository.supportsSourceManagement)
                      const PopupMenuItem(
                        value: 'sources',
                        child: Text('站源管理'),
                      ),
                    const PopupMenuItem(value: 'users', child: Text('用户管理')),
                    const PopupMenuItem(
                      value: 'settings',
                      child: Text('设置与备份'),
                    ),
                    const PopupMenuItem(
                      value: 'about',
                      child: Text('关于$appName'),
                    ),
                  ],
                ),
              ],
              const SizedBox(width: 8),
            ],
          ),
          body: SafeArea(
            top: false,
            child: Row(
              children: [
                SizedBox(
                  width: 164,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 24, 8, 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        for (final entry in [
                          (Icons.explore_rounded, '发现'),
                          (Icons.bookmark_rounded, '追剧'),
                          (Icons.history_rounded, '最近观看'),
                          if (widget.store.canDownload)
                            (Icons.download_rounded, '下载'),
                        ].indexed)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 14),
                            child: RemoteButton(
                              key: ValueKey('tv-nav-${entry.$1}'),
                              label: entry.$2.$2,
                              icon: entry.$2.$1,
                              selected: _tab == entry.$1,
                              autofocus: entry.$1 == 0,
                              onPressed: () => _onNavSelected(entry.$1),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: _tab == 0
                      ? widget.store.sources.isEmpty
                            ? const StatusPanel(
                                title: '暂无可用站源',
                                message: '请联系管理员为当前用户开放站源。',
                              )
                            : _catalog()
                      : _tab == 3
                      ? DownloadsScreen(
                          repository: widget.repository,
                          store: widget.store,
                          embedded: true,
                        )
                      : SavedLibrary(
                          key: ValueKey('saved-tab-$_tab'),
                          repository: widget.repository,
                          store: widget.store,
                          history: _tab == 2,
                          onOpen: _openDrama,
                          onContinue: (drama) =>
                              _openDrama(drama, resume: true),
                          onDownload:
                              widget.repository.supportsDownloads &&
                                  widget.store.canDownload
                              ? (drama) => _openDrama(drama, download: true)
                              : null,
                        ),
                ),
              ],
            ),
          ),
          );
        if (!_selectionMode) return scaffold;
        return PopScope(
          canPop: !_selectionMode && (_tab == 0 && _search.text.isEmpty),
          onPopInvokedWithResult: (didPop, result) {
            if (!didPop) _televisionBack();
          },
          child: CallbackShortcuts(
            bindings: {
              const SingleActivator(LogicalKeyboardKey.escape): () =>
                  Navigator.of(context).maybePop(),
              const SingleActivator(LogicalKeyboardKey.goBack): () =>
                  Navigator.of(context).maybePop(),
            },
            child: scaffold,
          ),
        );
      },
    ),
  );

  Widget _catalog() {
    final items = _visible;
    return Column(
      children: [
        CatalogFilters(
          key: ValueKey('filters-${_group.id}'),
          categories: _displayCategories,
          category: _displayCategory,
          error: _categoriesError,
          onCategory: _changeCategory,
          onRetry: () => _loadCategories(force: true),
          trailing: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_supportsVipFilter)
                IconButton(
                  tooltip: widget.store.hideVip ? 'VIP：隐藏' : 'VIP：显示',
                  onPressed: () => saveUserChange(
                    context,
                    () => widget.store.setHideVip(!widget.store.hideVip),
                  ),
                  icon: VipIcon(hidden: widget.store.hideVip),
                ),
            ],
          ),
        ),
        if (_showRecommendations)
          Expanded(
            child: RecommendationsScreen(
              repository: widget.repository,
              store: widget.store,
              embedded: true,
            ),
          )
        else ...[
          if (widget.repository.supportsSourceManagement &&
              (_updateNotice ||
                  _group.sources.any((source) => _updater.busy(source.id))))
            _updateStatus(),
          if (_loading && _items.isNotEmpty)
            const LinearProgressIndicator(minHeight: 2),
          if (_error != null && _items.isNotEmpty)
            Container(
              margin: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      _error!,
                      maxLines: 3,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onErrorContainer,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _loading || _loadingMore
                        ? null
                        : () => _load(more: _failedMore, force: true),
                    child: const Text('重试'),
                  ),
                  if (widget.repository.supportsSourceManagement)
                    IconButton(
                      tooltip: '站源诊断',
                      onPressed: _manageSources,
                      icon: const Icon(Icons.network_check),
                    ),
                ],
              ),
            ),
          Expanded(
            child: _loading && _items.isEmpty
                ? const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        CircularProgressIndicator(),
                        SizedBox(height: 18),
                        Text('正在加载剧集'),
                      ],
                    ),
                  )
                : _items.isEmpty && _error != null
                  ? StatusPanel(
                      title: '暂时无法加载',
                      message: _error!,
                      onRetry: () => _load(force: true),
                      secondaryAction:
                          widget.repository.supportsSourceManagement
                          ? TextButton(
                              onPressed: _manageSources,
                              child: const Text('站源诊断'),
                            )
                          : null,
                      icon: Icons.wifi_off_rounded,
                    )
                  : items.isEmpty
                  ? StatusPanel(
                      title: '没有找到匹配的短剧',
                      message: _hideVip
                          ? '可以换个搜索词，或显示 VIP 内容。'
                          : widget.store.sources.length > 1
                          ? '可以换个搜索词或切换站源。'
                          : '可以换个搜索词，或刷新后重试。',
                      onRetry:
                          _hasMore &&
                              !_loadingMore &&
                              (!_onlineSearch ||
                                  _search.text.isEmpty ||
                                  _group.sources.any(
                                    (source) => source.pagedSearch,
                                  ))
                          ? () => _load(more: true)
                          : null,
                      action: '重试',
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) => _televisionGrid(
                        items,
                        constraints.maxWidth,
                        key:
                            'catalog-${_group.id}-$_category-$_submittedQuery',
                        controller: _scroll,
                        footer: Padding(
                          padding: const EdgeInsets.fromLTRB(18, 0, 18, 24),
                          child: Center(
                            child: _catalogFooter(context),
                          ),
                        ),
                      ),
                    ),
          ),
          if (_selectionMode) _selectionBar(safeBottom: false),
        ],
      ],
    );
  }

  Widget _selectionBar({bool safeBottom = true}) {
    final theme = Theme.of(context);
    final count = _selectedDramas.length;
    return Material(
      color: theme.colorScheme.surface,
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          border: Border(
            top: BorderSide(color: theme.colorScheme.outlineVariant),
          ),
        ),
        child: SafeArea(
          top: false,
          bottom: safeBottom,
          minimum: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final summary = Semantics(
                liveRegion: true,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      count == 0 ? '点选要下载的短剧' : '已选 $count 部',
                      style: theme.textTheme.titleSmall?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      count == 0
                          ? '最多 ${BatchDownloads.maxDramas} 部'
                          : '下一步选择分集和画质',
                      style: theme.textTheme.bodySmall?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              );
              final next = FilledButton(
                key: const ValueKey('download-selected-dramas'),
                onPressed: count == 0 ? null : _downloadSelected,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(96, 48),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 20,
                    vertical: 12,
                  ),
                ),
                child: const Text('下一步'),
              );
              if (constraints.maxWidth < 320 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [summary, const SizedBox(height: 12), next],
                );
              }
              return Row(
                children: [
                  Expanded(child: summary),
                  const SizedBox(width: 16),
                  next,
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _updateStatus() {
    final sources = _group.sources;
    final busy = sources.any((source) => _updater.busy(source.id));
    final messages = <String>[];
    var failed = false;
    for (final source in sources) {
      final status = _updater.status(source.id);
      final error = [
        _updater.error(source.id),
        status?.error ?? '',
        status?.storageError ?? '',
      ].where((value) => value.isNotEmpty).toSet().join('；');
      if (error.isNotEmpty) {
        failed = true;
        messages.add('${source.name}：$error');
      } else if (status != null) {
        messages.add(
          '${source.name}：${status.stage.isEmpty ? '准备更新' : status.stage}'
          '${status.total > 0 ? ' ${status.completed}/${status.total}' : ''}'
          '${!status.running && status.added > 0 ? ' · 新增 ${status.added} 部' : ''}',
        );
      } else if (busy) {
        messages.add('${source.name}：正在启动');
      }
    }
    final colors = Theme.of(context).colorScheme;
    return Material(
      color: failed ? colors.errorContainer : colors.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 4, 4),
        child: Row(
          children: [
            Expanded(
              child: Text(
                messages.isEmpty ? '准备更新剧库' : messages.join('；'),
                maxLines: 3,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  color: failed ? colors.onErrorContainer : colors.onSurface,
                ),
              ),
            ),
            if (busy)
              TextButton(
                onPressed: () => _updater.stop(sources),
                child: const Text('停止'),
              ),
            IconButton(
              tooltip: '查看更新详情',
              onPressed: _manageSources,
              icon: const Icon(Icons.info_outline_rounded, size: 20),
            ),
            if (!busy)
              IconButton(
                tooltip: '收起更新提示',
                onPressed: () => setState(() => _updateNotice = false),
                icon: const Icon(Icons.close_rounded, size: 20),
              ),
          ],
        ),
      ),
    );
  }

  Widget _televisionGrid(
    List<Drama> items,
    double width, {
    required String key,
    ScrollController? controller,
    Widget? footer,
  }) {
    final columns = ((width - 36) / 150).floor().clamp(1, 8);
    final tileWidth = (width - 36 - (columns - 1) * 14) / columns;
    return RemoteGrid(
      key: ValueKey('tv-grid-$key'),
      itemKeys: items.map((item) => item.id).toList(),
      columns: columns,
      itemExtent: DramaTile.extentFor(context, tileWidth - 14) + 14,
      controller: controller,
      footer: footer,
      padding: const EdgeInsets.fromLTRB(18, 2, 18, 18),
      itemBuilder: (_, index, node, onFocus) =>
          _catalogTile(items[index], focusNode: node, onFocus: onFocus),
    );
  }
}
