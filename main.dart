// FLIX - Stream Unlimited Movies & TV Shows
// Flutter + Firebase (Firestore) + local fallback
// If Firebase is NOT connected yet, the app runs with admin-added
// movies saved locally (no sample / placeholder movies any more).
// Connect Firebase later (see README).
// IMPORTANT: Only add videos you own or have a licence for. The videoUrl
// field must be YOUR hosted link (Firebase Storage / your server), not a
// link copied from another streaming site.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:dio/dio.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:share_plus/share_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';
import 'package:webview_flutter/webview_flutter.dart';

// NEW: NexStream embed player
const Color kBg = Color(0xFF0B1220);
const Color kCard = Color(0xFF1A2436);
const Color kCard2 = Color(0xFF232F45);
const Color kRed = Color(0xFFE11D2E);
const Color kBlue = Color(0xFF4A90E2);
const Color kGrey = Color(0xFF8A94A6);

const String kBuildTag = 'dev';
const String kRepo = 'AbdulMannan2613/Flix';
const String kUpiId = 'mannanbhaii@fam';
const String kUpiPayee = 'Flix';

class UpdateChecker {
  static Future<({String tag, String apkUrl})?> fetchLatest() async {
    try {
      final res = await Dio().get('https://api.github.com/repos/$kRepo/releases/latest',
          options: Options(headers: {'Accept': 'application/vnd.github+json'}));
      final data = res.data as Map<String, dynamic>;
      final tag = (data['tag_name'] ?? '').toString();
      final assets = (data['assets'] as List?) ?? [];
      String apkUrl = '';
      for (final a in assets) {
        final m = Map<String, dynamic>.from(a as Map);
        if ((m['name'] ?? '').toString() == 'app-release.apk') {
          apkUrl = (m['browser_download_url'] ?? '').toString();
          break;
        }
      }
      if (tag.isEmpty || apkUrl.isEmpty) return null;
      return (tag: tag, apkUrl: apkUrl);
    } catch (_) {
      return null;
    }
  }

  static Future<void> checkAndPrompt(BuildContext context) async {
    if (kBuildTag == 'dev') return;
    final latest = await fetchLatest();
    if (latest == null || latest.tag == kBuildTag) return;
    final p = await SharedPreferences.getInstance();
    if (p.getString('dismissed_update_tag') == latest.tag) return;
    if (!context.mounted) return;
    final go = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: Text(Lang.t('newVersion')),
      content: Text(Lang.t('newVersionBody')),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(Lang.t('later'))),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white), onPressed: () => Navigator.pop(context, true), child: Text(Lang.t('downloadBtn'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
      ],
    ));
    if (go == true) {
      final uri = Uri.parse(latest.apkUrl);
      if (await canLaunchUrl(uri)) await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else {
      await p.setString('dismissed_update_tag', latest.tag);
    }
  }
}

// ---------------- TMDB ----------------
const String kTmdbApiKey = '8c6fe697df81d39205f246a5b41ed3e4';
bool get kUseTmdb => kTmdbApiKey.isNotEmpty && kTmdbApiKey != 'YOUR_TMDB_API_KEY';

class Tmdb {
  static const _genres = {
    28: 'Action', 12: 'Adventure', 16: 'Animation', 35: 'Comedy',
    80: 'Crime', 99: 'Documentary', 18: 'Drama', 10751: 'Family',
    14: 'Fantasy', 36: 'History', 27: 'Horror', 10402: 'Music',
    9648: 'Mystery', 10749: 'Romance', 878: 'Science Fiction',
    10770: 'TV Movie', 53: 'Thriller', 10752: 'War', 37: 'Western',
    10759: 'Action & Adventure', 10762: 'Kids', 10763: 'News',
    10764: 'Reality', 10765: 'Sci-Fi & Fantasy', 10766: 'Soap',
    10767: 'Talk', 10768: 'War & Politics',
  };

  static Movie _fromJson(Map<String, dynamic> j, bool trending, {bool hindiDubbed = false, bool isTv = false}) {
    final poster = (j['poster_path'] ?? '').toString();
    final backdrop = (j['backdrop_path'] ?? '').toString();
    final ids = (j['genre_ids'] as List?) ?? [];
    final cat = ids.isNotEmpty ? (_genres[ids.first] ?? 'Movie') : 'Movie';
    final rel = (j['release_date'] ?? j['first_air_date'] ?? '').toString();
    final year = int.tryParse(rel.length >= 4 ? rel.substring(0, 4) : '') ?? 2025;
    final lang = (j['original_language'] ?? '').toString().toUpperCase();
    return Movie(
      id: isTv ? 'tmdb_tv_${j['id']}' : 'tmdb_${j['id']}',
      title: (j['title'] ?? j['name'] ?? 'Untitled').toString(),
      description: (j['overview'] ?? '').toString(),
      category: cat,
      language: hindiDubbed ? 'HI' : (lang.isEmpty ? 'EN' : lang),
      posterUrl: poster.isEmpty ? '' : 'https://image.tmdb.org/t/p/w500$poster',
      backdropUrl: backdrop.isEmpty ? '' : 'https://image.tmdb.org/t/p/w1280$backdrop',
      videoUrl: '',
      type: isTv ? 'TV Show' : 'Movie',
      year: year,
      rating: ((j['vote_average'] ?? 7.0) as num).toDouble(),
      isTrending: trending,
      categories: [cat],
    );
  }

  static Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));

  static bool _hasHindiVersion(Map<String, dynamic> hi, Map<String, dynamic>? en) {
    final hiOv = (hi['overview'] ?? '').toString().trim();
    final hiTitle = ((hi['title'] ?? hi['name']) ?? '').toString().trim();
    final enTitle = ((en?['title'] ?? en?['name']) ?? '').toString().trim();
    if (en == null) return hiOv.isNotEmpty;
    if (hiTitle.isNotEmpty && enTitle.isNotEmpty && hiTitle != enTitle) return true;
    if (hiOv.isEmpty) return false;
    return hiOv != (en['overview'] ?? '').toString().trim();
  }

  static Future<List<Map<String, dynamic>>> _list(
      Dio dio, String path, Map<String, dynamic> qp) async {
    try {
      final r = await dio.get(path, queryParameters: qp)
          .timeout(const Duration(seconds: 8));
      return ((r.data?['results'] as List?) ?? [])
          .map((e) => Map<String, dynamic>.from(e as Map))
          .toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Movie>> fetchTrendingAndPopular({int hindiPages = 6}) async {
    if (!kUseTmdb) return [];
    try {
      final dio = _dio();
      final lists = await Future.wait([
        for (var p = 1; p <= hindiPages; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/movie',
              {'api_key': kTmdbApiKey, 'language': 'en-US', 'with_original_language': 'hi', 'sort_by': 'popularity.desc', 'page': p}),
        _list(dio, 'https://api.themoviedb.org/3/movie/popular',
            {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'page': 1}),
        _list(dio, 'https://api.themoviedb.org/3/movie/popular',
            {'api_key': kTmdbApiKey, 'language': 'en-US', 'page': 1}),
        for (var p = 1; p <= 2; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/movie',
              {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'with_original_language': 'ko', 'sort_by': 'popularity.desc', 'page': p}),
        for (var p = 1; p <= 2; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/movie',
              {'api_key': kTmdbApiKey, 'language': 'en-US', 'with_original_language': 'ko', 'sort_by': 'popularity.desc', 'page': p}),
        for (var p = 1; p <= 2; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/tv',
              {'api_key': kTmdbApiKey, 'language': 'en-US', 'with_original_language': 'hi', 'sort_by': 'popularity.desc', 'page': p}),
        _list(dio, 'https://api.themoviedb.org/3/tv/popular',
            {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'page': 1}),
        _list(dio, 'https://api.themoviedb.org/3/tv/popular',
            {'api_key': kTmdbApiKey, 'language': 'en-US', 'page': 1}),
        for (var p = 1; p <= 2; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/tv',
              {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'with_original_language': 'ko', 'sort_by': 'popularity.desc', 'page': p}),
        for (var p = 1; p <= 2; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/tv',
              {'api_key': kTmdbApiKey, 'language': 'en-US', 'with_original_language': 'ko', 'sort_by': 'popularity.desc', 'page': p}),
      ]).timeout(const Duration(seconds: 15));
      final popularHi = lists[hindiPages];
      final popularEn = lists[hindiPages + 1];
      final hiById = <String, Map<String, dynamic>>{
        for (final m in popularHi) '${m['id']}': m,
      };
      final koMovieHi = lists.sublist(hindiPages + 2, hindiPages + 4).expand((e) => e).toList();
      final koMovieEn = lists.sublist(hindiPages + 4, hindiPages + 6).expand((e) => e).toList();
      final tvHi = lists.sublist(hindiPages + 6, hindiPages + 8).expand((e) => e).toList();
      final tvPopHi = lists[hindiPages + 8];
      final tvPopEn = lists[hindiPages + 9];
      final koTvHi = lists.sublist(hindiPages + 10, hindiPages + 12).expand((e) => e).toList();
      final koTvEn = lists.sublist(hindiPages + 12, hindiPages + 14).expand((e) => e).toList();
      final out = <Movie>[];
      final seen = <String>{};
      void addRaw(Map<String, dynamic> j, bool hindiDubbed, {bool isTv = false}) {
        final m = _fromJson(j, false, hindiDubbed: hindiDubbed, isTv: isTv);
        if (seen.add(m.id)) out.add(m);
      }
      for (var i = 0; i < hindiPages; i++) {
        for (final j in lists[i]) {
          addRaw(j, false);
        }
      }
      if (out.isEmpty) {
        final retry = await _list(dio, 'https://api.themoviedb.org/3/discover/movie',
            {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'with_original_language': 'hi', 'sort_by': 'popularity.desc', 'page': 1});
        for (final j in retry) {
          addRaw(j, false);
        }
      }
      for (final j in popularEn) {
        if ((j['original_language'] ?? '').toString() == 'hi') {
          addRaw(j, false);
        } else if (_hasHindiVersion(hiById['${j['id']}'] ?? {}, j)) {
          addRaw(j, true);
        }
      }
      for (final j in tvHi) {
        addRaw(j, false, isTv: true);
      }
      final tvHiById = <String, Map<String, dynamic>>{
        for (final m in tvPopHi) '${m['id']}': m,
      };
      for (final j in tvPopEn) {
        if ((j['original_language'] ?? '').toString() == 'hi') {
          addRaw(j, false, isTv: true);
        } else if (_hasHindiVersion(tvHiById['${j['id']}'] ?? {}, j)) {
          addRaw(j, true, isTv: true);
        }
      }
      final koMovieHiById = <String, Map<String, dynamic>>{
        for (final m in koMovieHi) '${m['id']}': m,
      };
      for (final j in koMovieEn) {
        if (_hasHindiVersion(koMovieHiById['${j['id']}'] ?? {}, j)) {
          addRaw(j, true);
        }
      }
      final koTvHiById = <String, Map<String, dynamic>>{
        for (final m in koTvHi) '${m['id']}': m,
      };
      for (final j in koTvEn) {
        if (_hasHindiVersion(koTvHiById['${j['id']}'] ?? {}, j)) {
          addRaw(j, true, isTv: true);
        }
      }
      return out;
    } catch (_) {
      return [];
    }
  }

  static Future<List<Movie>> searchMovies(String query) async {
    if (!kUseTmdb || query.trim().isEmpty) return [];
    try {
      final dio = _dio();
      final results = await Future.wait([
        dio.get('https://api.themoviedb.org/3/search/movie',
            queryParameters: {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'query': query, 'page': 1, 'include_adult': false}),
        dio.get('https://api.themoviedb.org/3/search/movie',
            queryParameters: {'api_key': kTmdbApiKey, 'language': 'en-US', 'query': query, 'page': 1, 'include_adult': false}),
        dio.get('https://api.themoviedb.org/3/search/tv',
            queryParameters: {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'query': query, 'page': 1, 'include_adult': false}),
        dio.get('https://api.themoviedb.org/3/search/tv',
            queryParameters: {'api_key': kTmdbApiKey, 'language': 'en-US', 'query': query, 'page': 1, 'include_adult': false}),
      ]).timeout(const Duration(seconds: 10));
      final hiById = <String, Map<String, dynamic>>{};
      for (final raw in ((results[0].data?['results'] as List?) ?? [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        hiById['${m['id']}'] = m;
      }
      final tvHiById = <String, Map<String, dynamic>>{};
      for (final raw in ((results[2].data?['results'] as List?) ?? [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        tvHiById['${m['id']}'] = m;
      }
      final out = <Movie>[];
      final seen = <String>{};
      for (final raw in ((results[1].data?['results'] as List?) ?? [])) {
        final j = Map<String, dynamic>.from(raw as Map);
        final dubbed = (j['original_language'] ?? '').toString() != 'hi' &&
            _hasHindiVersion(hiById['${j['id']}'] ?? {}, j);
        final m = _fromJson(j, false, hindiDubbed: dubbed);
        if (seen.add(m.id)) out.add(m);
      }
      for (final raw in ((results[3].data?['results'] as List?) ?? [])) {
        final j = Map<String, dynamic>.from(raw as Map);
        final dubbed = (j['original_language'] ?? '').toString() != 'hi' &&
            _hasHindiVersion(tvHiById['${j['id']}'] ?? {}, j);
        final m = _fromJson(j, false, hindiDubbed: dubbed, isTv: true);
        if (seen.add(m.id)) out.add(m);
      }
      for (final raw in ((results[0].data?['results'] as List?) ?? [])) {
        final j = Map<String, dynamic>.from(raw as Map);
        final m = _fromJson(j, false);
        if (seen.add(m.id)) out.add(m);
      }
      for (final raw in ((results[2].data?['results'] as List?) ?? [])) {
        final j = Map<String, dynamic>.from(raw as Map);
        final m = _fromJson(j, false, isTv: true);
        if (seen.add(m.id)) out.add(m);
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}

// ---------------- NEXSTREAM (NEW) ----------------
// NexStream embed API for TMDB movies and TV shows. This class only
// builds the embed URL; playback happens in NexStreamPlayerScreen
// (WebView based) because NexStream serves an HTML embed page, not
// a direct .mp4 file. Existing non-TMDB movies (Admin-added with a
// real videoUrl) keep using the original PlayerScreen, unchanged.
class NexStreamHelper {
  static const String _apiKey = 'nx_0a870df2c80f0d4e0d59a723987e0be7';
  static const String _baseUrl = 'https://api.codespecters.com';

  /// A movie is played through NexStream when it is a TMDB title
  /// (id starts with tmdb_) and has no direct videoUrl of its own.
  static bool canPlay(Movie movie) =>
      movie.id.startsWith('tmdb_') && movie.videoUrl.isEmpty;

  /// Extract the numeric TMDB ID from the app's internal id.
  static String? _tmdbId(Movie movie) {
    final raw = movie.id;
    if (raw.startsWith('tmdb_tv_')) return raw.replaceFirst('tmdb_tv_', '');
    if (raw.startsWith('tmdb_')) return raw.replaceFirst('tmdb_', '');
    return null;
  }

  /// Build the NexStream embed URL. For TV shows, season defaults to 1
  /// and episode = episodeIndex + 1 (episodeIndex is 0-based).
  static String buildEmbedUrl(Movie movie,
      {int episodeIndex = 0, int season = 1}) {
    final id = _tmdbId(movie);
    if (id == null) return '';
    if (movie.type == 'TV Show' || movie.type == 'Web Series') {
      final ep = episodeIndex + 1;
      return '$_baseUrl/embed/tv/$id/$season/$ep?apikey=$_apiKey';
    }
    return '$_baseUrl/embed/movie/$id?apikey=$_apiKey';
  }
}

// ---------------- NEXSTREAM PLAYER (NEW) ----------------
// Fullscreen WebView player. NexStream serves an HTML player page,
// so video_player cannot handle it - a WebView is required. The
// existing PlayerScreen is untouched and still handles any
// Admin-added video with a real videoUrl.
class NexStreamPlayerScreen extends StatefulWidget {
  final Movie movie;
  final int episodeIndex;
  const NexStreamPlayerScreen(
      {super.key, required this.movie, this.episodeIndex = 0});

  @override
  State<NexStreamPlayerScreen> createState() => _NexStreamPlayerScreenState();
}

class _NexStreamPlayerScreenState extends State<NexStreamPlayerScreen> {
  WebViewController? _controller;
  bool _loading = true;
  String? _error;
  late int _episodeIndex;

  bool get _isSeries =>
      widget.movie.type == 'TV Show' || widget.movie.type == 'Web Series';

  int get _episodeCount =>
      widget.movie.episodes.isNotEmpty ? widget.movie.episodes.length : 3;

  @override
  void initState() {
    super.initState();
    _episodeIndex = widget.episodeIndex.clamp(0, _episodeCount - 1);
    SystemChrome.setPreferredOrientations(
        [DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _loadCurrent();
  }

  void _loadCurrent() {
    final url = NexStreamHelper.buildEmbedUrl(widget.movie,
        episodeIndex: _episodeIndex);
    if (url.isEmpty) {
      setState(() {
        _loading = false;
        _error = 'NexStream link not available for this title.';
      });
      return;
    }
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.black)
      ..setNavigationDelegate(NavigationDelegate(
        onPageStarted: (_) {
          if (mounted) setState(() { _loading = true; _error = null; });
        },
        onPageFinished: (_) {
          if (mounted) setState(() => _loading = false);
        },
        onWebResourceError: (e) {
          if (mounted) {
            setState(() {
              _loading = false;
              _error = e.description;
            });
          }
        },
      ))
      ..loadRequest(Uri.parse(url));
  }

  void _loadEpisode(int index) {
    if (index < 0 || index >= _episodeCount) return;
    setState(() {
      _episodeIndex = index;
      _loading = true;
      _error = null;
    });
    _loadCurrent();
  }

  @override
  void dispose() {
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  // CHANGE YAHAN HAI: WillPopScope hata kar PopScope laga diya gaya hai
  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop) return;
        final c = _controller;
        if (c != null) {
          final canGoBack = await c.canGoBack();
          if (canGoBack) {
            await c.goBack();
          } else {
            if (context.mounted) Navigator.pop(context);
          }
        } else {
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Stack(children: [
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  const Icon(Icons.error_outline,
                      color: Colors.white70, size: 48),
                  const SizedBox(height: 12),
                  Text(_error!,
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70)),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                        backgroundColor: kRed, foregroundColor: Colors.white),
                    onPressed: () {
                      setState(() { _error = null; _loading = true; });
                      _loadCurrent();
                    },
                    child: const Text('Retry'),
                  ),
                ]),
              ),
            )
          else if (_controller != null)
            WebViewWidget(controller: _controller!),
          if (_loading && _error == null)
            const Center(child: CircularProgressIndicator(color: kRed)),
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                decoration: const BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [Colors.black87, Colors.transparent],
                  ),
                ),
                child: Row(children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => Navigator.pop(context),
                  ),
                  Expanded(
                    child: Text(
                      _isSeries
                          ? '${widget.movie.title} • ${Lang.t('episode')} ${_episodeIndex + 1}'
                          : widget.movie.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: Colors.white, fontWeight: FontWeight.bold),
                    ),
                  ),
                ]),
              ),
            ),
          ),
          if (_isSeries && _error == null && !_loading)
            Positioned(
              bottom: 12, left: 12, right: 12,
              child: SafeArea(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(30),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        TextButton.icon(
                          onPressed: _episodeIndex > 0
                              ? () => _loadEpisode(_episodeIndex - 1)
                              : null,
                          icon: const Icon(Icons.skip_previous,
                              color: Colors.white, size: 20),
                          label: const Text('Prev',
                              style: TextStyle(color: Colors.white)),
                        ),
                        const SizedBox(width: 8),
                        Text('${_episodeIndex + 1} / $_episodeCount',
                            style: const TextStyle(color: Colors.white)),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: _episodeIndex + 1 < _episodeCount
                              ? () => _loadEpisode(_episodeIndex + 1)
                              : null,
                          icon: const Icon(Icons.skip_next,
                              color: Colors.white, size: 20),
                          label: const Text('Next',
                              style: TextStyle(color: Colors.white)),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
    );
  }
}

// ---------------- APP LANGUAGE ----------------
class Lang {
  static const _key = 'app_language';
  static final ValueNotifier<String> current = ValueNotifier('en');
  static String get code => current.value;
  static bool get isHindi => code == 'hi';

  static Future<void> load() async {
    try {
      final p = await SharedPreferences.getInstance();
      final saved = p.getString(_key);
      if (saved == 'hi' || saved == 'en') current.value = saved!;
    } catch (_) {}
  }

  static Future<void> set(String code) async {
    if (code != 'en' && code != 'hi') return;
    try {
      final p = await SharedPreferences.getInstance();
      await p.setString(_key, code);
    } catch (_) {}
    current.value = code;
  }

  static String t(String key) {
    if (isHindi) {
      final hi = _hi[key];
      if (hi != null) return hi;
    }
    return _en[key] ?? key;
  }

  static String tr(String key, String placeholder, String value) =>
      t(key).replaceAll(placeholder, value);

  static const _en = <String, String>{
    'navHome': 'Home', 'navCategories': 'Categories', 'navMe': 'Me',
    'searchHint': 'Search movies, TV shows...', 'search': 'Search',
    'refresh': 'Refresh', 'trending': 'Trending Movies',
    'popular': 'Popular Movies', 'loadMore': 'Aur Movies Dikhao',
    'loading': 'Loading...', 'noMovies': 'No movies yet.',
    'noMoviesHint': 'Refresh, or add one from the Admin panel.',
    'catTitle': 'Categories', 'all': 'All', 'typeMovies': 'Movies',
    'typeTv': 'TV Shows', 'typeWeb': 'Web Series',
    'noCategory': 'No movies in this category yet.\nAdd one from the Admin panel.',
    'sortPopularity': 'Popularity', 'sortLatest': 'Latest',
    'sortTop': 'Top today', 'searchFieldHint': 'Title / Actor / Director',
    'cancel': 'Cancel', 'searchHistory': 'Search History',
    'nothingSearched': 'Nothing searched yet',
    'popularSearches': 'Popular Searches',
    'noExactMatch': 'No exact match for "{q}"',
    'relatedMovies': 'Related movies you may like:',
    'watchNow': 'Watch Now', 'download': 'Download', 'share': 'Share',
    'favorite': 'Favorite', 'saved': 'Saved', 'description': 'Description',
    'episodes': 'Episodes', 'episodesIn': '{n} episodes in this {t}',
    'episode': 'Episode', 'nextEpisode': 'Next Episode',
    'lastEpisode': 'This is the last episode',
    'playingEpisode': 'Playing Episode', 'adminPin': 'Admin PIN',
    'enterPin': 'Enter admin PIN', 'unlock': 'Unlock',
    'wrongPin': 'Wrong PIN', 'meMovie': 'Movie',
    'vipJoin': 'Join VIP and enjoy ad-free viewing of all videos',
    'vipDiscount': '40%+ discount currently!', 'subscribe': 'Subscribe',
    'tileShare': 'Share', 'tileLanguage': 'Language Switching',
    'tileHistory': 'History', 'tileDownloads': 'My download',
    'tileFavorites': 'My Favorites', 'tileOrders': 'Order list',
    'tileFeedback': 'Feedback',
    'tileSupport': 'Official customer service',
    'chooseLanguage': 'Choose language', 'languageSet': 'Language set to',
    'history': 'History',
    'noHistory': 'No watch history yet.\nPlay a movie and it will appear here.',
    'remaining': 'Remaining', 'myDownloads': 'My download',
    'downloading': 'Downloading', 'downloaded': 'Downloaded',
    'noContent': 'No Content yet',
    'noDownloads': 'No downloaded movies yet.\nTap Download on a movie details page.',
    'downloadedTap': 'Downloaded • Tap to play offline',
    'myFavorites': 'My Favorites', 'noFavorites': 'No favorites yet.',
    'orderList': 'Order list',
    'notPurchased': 'Not purchased VIP plan yet',
    'notPurchasedSub': 'You have not purchased a VIP plan yet.',
    'purchasedPlan': 'Purchased plan:', 'statusPurchased': 'Status: Purchased',
    'payment': 'Payment', 'vipBenefits': 'VIP benefits',
    'benefit1': '✓  Exempt video ads on the home page, play, download and pause.',
    'benefit2': '✓  Unlimited download opportunities',
    'benefit3': '✓  More than 5 million HD movie resources',
    'next': 'Next', 'promotion': 'Promotion',
    'promotionRecord': 'Promotion record',
    'promoted': 'Promoted {n} person',
    'daysAdFree': 'You have {n} days ad-free',
    'myCode': 'My invitation code:', 'shareNow': 'Share now',
    'feedback': 'Feedback', 'feedbackHint': 'Tell us what to improve...',
    'send': 'Send', 'customerService': 'Customer Service',
    'customerServiceBody': 'Email us from the address you used for Flix. Support replies within 1-2 working days.',
    'newVersion': 'New version available',
    'newVersionBody': 'A new version of Flix is available with the latest changes.\n\nTap Download to get the new APK. The file will always be called app-release.apk - that is the new version, even if the name looks the same as the old file.',
    'later': 'Later', 'downloadBtn': 'Download',
    'noVideo': 'No video file for this TMDB listing. TMDB gives details and posters only, not a full movie file.',
    'downloadedMsg': 'Downloaded. Find it in Me > My download.',
    'tmdbOnly': 'This is a TMDB listing: details and poster only. No full-movie video file is available for it in Flix.',
    'paySecureTitle': '100% Safe & Secure',
    'paySecureBody': 'Payment happens in your UPI app (Google Pay / PhonePe / Paytm). Flix never sees your bank details or UPI PIN.',
    'scanQr': 'Scan with any UPI app', 'payInUpi': 'Pay in UPI App',
    'copyUpi': 'Copy UPI ID', 'copied': 'UPI ID copied',
    'iHavePaid': 'I Have Paid', 'confirmTitle': 'Confirm Payment',
    'utrHint': 'UTR / Transaction ID from your UPI app (optional)',
    'utrHelp': 'You will find it in your UPI app payment receipt. VIP turns on after you confirm.',
    'activate': 'Activate VIP',
    'vipActivated': 'VIP activated! Ads are now off.',
    'noUpiApp': 'No UPI app found. Scan the QR with any UPI app.',
    'vipActive': 'VIP is active - enjoy ad-free viewing',
    'payExact': 'Pay the exact amount shown', 'orderAmount': 'Amount',
    'orderUtr': 'UTR / Transaction ID', 'orderDate': 'Date',
    'orderExpiry': 'Valid until',
  };

  static const _hi = <String, String>{
    'navHome': 'होम', 'navCategories': 'कैटेगरी', 'navMe': 'मैं',
    'searchHint': 'मूवी, टीवी शो खोजें...', 'search': 'खोजें',
    'refresh': 'रीफ़्रेश करें', 'trending': 'ट्रेंडिंग मूवीज़',
    'popular': 'लोकप्रिय मूवीज़', 'loadMore': 'और मूवीज़ दिखाओ',
    'loading': 'लोड हो रहा है...', 'noMovies': 'अभी कोई मूवी नहीं है।',
    'noMoviesHint': 'रीफ़्रेश करें, या एडमिन पैनल से जोड़ें।',
    'catTitle': 'कैटेगरी', 'all': 'सभी', 'typeMovies': 'मूवीज़',
    'typeTv': 'टीवी शो', 'typeWeb': 'वेब सीरीज़',
    'noCategory': 'इस कैटेगरी में अभी कोई मूवी नहीं है।\nएडमिन पैनल से जोड़ें।',
    'sortPopularity': 'लोकप्रियता', 'sortLatest': 'नवीनतम',
    'sortTop': 'आज के टॉप', 'searchFieldHint': 'नाम / अभिनेता / निर्देशक',
    'cancel': 'रद्द करें', 'searchHistory': 'खोज इतिहास',
    'nothingSearched': 'अभी कुछ खोजा नहीं गया',
    'popularSearches': 'लोकप्रिय खोजें',
    'noExactMatch': '"{q}" के लिए कोई सटीक नतीजा नहीं',
    'relatedMovies': 'आपको ये संबंधित मूवीज़ पसंद आ सकती हैं:',
    'watchNow': 'अभी देखें', 'download': 'डाउनलोड',
    'share': 'शेयर करें', 'favorite': 'पसंदीदा', 'saved': 'सहेजा गया',
    'description': 'विवरण', 'episodes': 'एपिसोड',
    'episodesIn': 'इस {t} में {n} एपिसोड', 'episode': 'एपिसोड',
    'nextEpisode': 'अगला एपिसोड', 'lastEpisode': 'यह आखिरी एपिसोड है',
    'playingEpisode': 'एपिसोड चल रहा है', 'adminPin': 'एडमिन PIN',
    'enterPin': 'एडमिन PIN डालें', 'unlock': 'अनलॉक करें',
    'wrongPin': 'गलत PIN', 'meMovie': 'मूवी',
    'vipJoin': 'VIP जॉइन करें और सभी वीडियो बिना विज्ञापन देखें',
    'vipDiscount': 'अभी 40%+ छूट!', 'subscribe': 'सब्सक्राइब करें',
    'tileShare': 'शेयर करें', 'tileLanguage': 'भाषा बदलें',
    'tileHistory': 'इतिहास', 'tileDownloads': 'मेरे डाउनलोड',
    'tileFavorites': 'मेरे पसंदीदा', 'tileOrders': 'ऑर्डर सूची',
    'tileFeedback': 'प्रतिक्रिया',
    'tileSupport': 'आधिकारिक ग्राहक सेवा',
    'chooseLanguage': 'भाषा चुनें', 'languageSet': 'भाषा सेट हो गई:',
    'history': 'इतिहास',
    'noHistory': 'अभी कोई देखने का इतिहास नहीं है।\nकोई मूवी चलाएँ, वह यहाँ दिखेगी।',
    'remaining': 'बचा हुआ', 'myDownloads': 'मेरे डाउनलोड',
    'downloading': 'डाउनलोड हो रहा है', 'downloaded': 'डाउनलोड हो गया',
    'noContent': 'अभी कोई सामग्री नहीं',
    'noDownloads': 'अभी कोई मूवी डाउनलोड नहीं हुई है।\nमूवी के विवरण पेज पर डाउनलोड दबाएँ।',
    'downloadedTap': 'डाउनलोड हो गया • ऑफ़लाइन चलाने के लिए टैप करें',
    'myFavorites': 'मेरे पसंदीदा', 'noFavorites': 'अभी कोई पसंदीदा नहीं है।',
    'orderList': 'ऑर्डर सूची',
    'notPurchased': 'अभी VIP प्लान नहीं खरीदा गया है',
    'notPurchasedSub': 'आपने अभी तक VIP प्लान नहीं खरीदा है।',
    'purchasedPlan': 'खरीदा गया प्लान:',
    'statusPurchased': 'स्थिति: खरीदा गया', 'payment': 'भुगतान',
    'vipBenefits': 'VIP लाभ',
    'benefit1': '✓  होम पेज, प्ले, डाउनलोड और पॉज़ पर वीडियो विज्ञापनों से छूट।',
    'benefit2': '✓  असीमित डाउनलोड अवसर',
    'benefit3': '✓  50 लाख से ज़्यादा HD मूवी संसाधन',
    'next': 'आगे बढ़ें', 'promotion': 'प्रमोशन',
    'promotionRecord': 'प्रमोशन रिकॉर्ड',
    'promoted': '{n} व्यक्ति को प्रचारित किया',
    'daysAdFree': 'आपके पास {n} दिन विज्ञापन-मुक्त हैं',
    'myCode': 'मेरा आमंत्रण कोड:', 'shareNow': 'अभी शेयर करें',
    'feedback': 'प्रतिक्रिया', 'feedbackHint': 'बताएँ कि क्या बेहतर किया जाए...',
    'send': 'भेजें', 'customerService': 'ग्राहक सेवा',
    'customerServiceBody': 'उसी ईमेल पते से ईमेल करें जिसका उपयोग आपने Flix के लिए किया था। सहायता 1-2 कार्य दिवसों में जवाब देती है।',
    'newVersion': 'नया वर्शन उपलब्ध है',
    'newVersionBody': 'Flix का नया वर्शन नवीनतम बदलावों के साथ उपलब्ध है।\n\nनया APK पाने के लिए डाउनलोड दबाएँ। फ़ाइल का नाम हमेशा app-release.apk ही रहेगा - नाम एक जैसा दिखे, तब भी वह नया वर्शन है।',
    'later': 'बाद में', 'downloadBtn': 'डाउनलोड',
    'noVideo': 'इस TMDB सूची के लिए कोई वीडियो फ़ाइल नहीं है। TMDB केवल विवरण और पोस्टर देता है, पूरी मूवी फ़ाइल नहीं।',
    'downloadedMsg': 'डाउनलोड हो गया। Me > My download में देखें।',
    'tmdbOnly': 'यह TMDB सूची है: केवल विवरण और पोस्टर। Flix में इसके लिए कोई पूरी मूवी वीडियो फ़ाइल उपलब्ध नहीं है।',
    'paySecureTitle': '100% सुरक्षित',
    'paySecureBody': 'भुगतान आपके UPI ऐप (Google Pay / PhonePe / Paytm) में होता है। Flix आपके बैंक विवरण या UPI PIN कभी नहीं देखता।',
    'scanQr': 'किसी भी UPI ऐप से स्कैन करें',
    'payInUpi': 'UPI ऐप में भुगतान करें',
    'copyUpi': 'UPI ID कॉपी करें', 'copied': 'UPI ID कॉपी हो गया',
    'iHavePaid': 'मैंने भुगतान कर दिया है',
    'confirmTitle': 'भुगतान की पुष्टि करें',
    'utrHint': 'अपने UPI ऐप से UTR / ट्रांज़ैक्शन ID (वैकल्पिक)',
    'utrHelp': 'यह आपको अपने UPI ऐप की भुगतान रसीद में मिलेगा। पुष्टि करने के बाद VIP चालू हो जाएगा।',
    'activate': 'VIP चालू करें',
    'vipActivated': 'VIP चालू हो गया! अब विज्ञापन बंद हैं।',
    'noUpiApp': 'कोई UPI ऐप नहीं मिला। QR को किसी भी UPI ऐप से स्कैन करें।',
    'vipActive': 'VIP चालू है - बिना विज्ञापन देखें',
    'payExact': 'दिखाई गई सटीक राशि का भुगतान करें',
    'orderAmount': 'राशि', 'orderUtr': 'UTR / ट्रांज़ैक्शन ID',
    'orderDate': 'तारीख', 'orderExpiry': 'इस तारीख तक मान्य',
  };
}

class FlixApp extends StatelessWidget {
  const FlixApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<String>(
      valueListenable: Lang.current,
      builder: (context, _, __) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Flix',
        theme: ThemeData.dark().copyWith(
          scaffoldBackgroundColor: kBg,
          colorScheme: const ColorScheme.dark(primary: kRed, surface: kBg),
          appBarTheme: const AppBarTheme(backgroundColor: kBg, elevation: 0),
        ),
        home: const SplashScreen(),
      ),
    );
  }
}

// ---------------- MODEL ----------------
class Movie {
  final String id, title, description, category, language, posterUrl, videoUrl, type;
  final String backdropUrl;
  final int year;
  final double rating;
  final bool isTrending;
  final Map<String, String> qualities;
  final List<String> episodes;
  final List<String> categories;
  Movie({
    required this.id, required this.title, required this.description,
    required this.category, required this.language, required this.posterUrl,
    required this.videoUrl, required this.type, required this.year,
    required this.rating, this.isTrending = false, this.qualities = const {},
    this.episodes = const [], this.categories = const [], this.backdropUrl = '',
  });
  String get rectangleImageUrl => backdropUrl.isNotEmpty ? backdropUrl : posterUrl;
  List<String> get allCategories => categories.isNotEmpty ? categories : [category];
  String get categoriesText => allCategories.join(' • ');
  factory Movie.fromMap(String id, Map<String, dynamic> m) => Movie(
    id: id,
    title: m['title'] ?? 'Untitled',
    description: m['description'] ?? '',
    category: m['category'] ?? 'Action',
    language: m['language'] ?? 'Hindi',
    posterUrl: m['posterUrl'] ?? '',
    videoUrl: m['videoUrl'] ?? '',
    type: m['type'] ?? 'Movie',
    year: (m['year'] ?? 2025) as int,
    rating: ((m['rating'] ?? 7.0) as num).toDouble(),
    isTrending: m['isTrending'] ?? false,
    qualities: Map<String, String>.from(m['qualities'] ?? {}),
    episodes: List<String>.from(m['episodes'] ?? []),
    categories: List<String>.from(m['categories'] ?? (m['category'] != null ? [m['category']] : [])),
    backdropUrl: m['backdropUrl'] ?? '',
  );
  Map<String, dynamic> toMap() => {
    'title': title, 'description': description, 'category': category,
    'language': language, 'posterUrl': posterUrl, 'videoUrl': videoUrl,
    'type': type, 'year': year, 'rating': rating, 'isTrending': isTrending,
    'qualities': qualities, 'episodes': episodes, 'categories': allCategories,
    'backdropUrl': backdropUrl,
  };
}

List<Movie> sampleMovies() => [];

// ---------------- REPOSITORY ----------------
class MovieRepo {
  static bool _isSampleId(String id) => RegExp(r'^s[0-9]$').hasMatch(id);

  static Future<List<Movie>> getCached() async {
    final local = await _localMovies();
    List<Movie> base = local;
    try {
      if (Firebase.apps.isNotEmpty) {
        final snap = await FirebaseFirestore.instance
            .collection('movies')
            .get(const GetOptions(source: Source.cache))
            .timeout(const Duration(seconds: 3));
        if (snap.docs.isNotEmpty) {
          final fire = snap.docs.map((d) => Movie.fromMap(d.id, d.data())).toList();
          final ids = fire.map((m) => m.id).toSet();
          base = [...fire, ...local.where((m) => !ids.contains(m.id))];
        }
      }
    } catch (_) {}
    base = base
        .where((m) => !_isSampleId(m.id) && !(m.id.startsWith('tmdb_') && m.language.toUpperCase() != 'HI'))
        .toList();
    final cached = await _loadTmdbCache();
    if (cached.isNotEmpty) {
      final ids = cached.map((m) => m.id).toSet();
      return [...cached, ...base.where((m) => !ids.contains(m.id))];
    }
    return base;
  }

  static Future<List<Movie>> getAll({int hindiPages = 6}) async {
    final local = await _localMovies();
    List<Movie> base;
    try {
      if (Firebase.apps.isNotEmpty) {
        QuerySnapshot<Map<String, dynamic>>? snap;
        try {
          snap = await FirebaseFirestore.instance.collection('movies').get().timeout(const Duration(seconds: 15));
        } catch (_) {
          try {
            snap = await FirebaseFirestore.instance.collection('movies').get(const GetOptions(source: Source.cache)).timeout(const Duration(seconds: 3));
          } catch (_) {}
        }
        if (snap != null && snap.docs.isNotEmpty) {
          final fire = snap.docs.map((d) => Movie.fromMap(d.id, d.data())).toList();
          final ids = fire.map((m) => m.id).toSet();
          base = [...fire, ...local.where((m) => !ids.contains(m.id))];
        } else {
          base = local;
        }
      } else {
        base = local;
      }
    } catch (_) {
      base = local;
    }
    base = base
        .where((m) => !_isSampleId(m.id) && !(m.id.startsWith('tmdb_') && m.language.toUpperCase() != 'HI'))
        .toList();
    final seeded = base.any((m) => m.id.startsWith('tmdb_') && m.language.toUpperCase() == 'HI');
    try {
      final tmdb = await Tmdb.fetchTrendingAndPopular(hindiPages: hindiPages).timeout(Duration(seconds: seeded ? 6 : 15));
      if (tmdb.isNotEmpty) {
        await _saveTmdbCache(tmdb);
        try {
          await _syncTmdbToFirestore(tmdb).timeout(const Duration(seconds: 6));
        } catch (_) {}
        final ids = tmdb.map((m) => m.id).toSet();
        return [...tmdb, ...base.where((m) => !ids.contains(m.id))];
      }
    } catch (_) {}
    final cached = await _loadTmdbCache();
    if (cached.isNotEmpty) {
      final ids = cached.map((m) => m.id).toSet();
      return [...cached, ...base.where((m) => !ids.contains(m.id))];
    }
    return base;
  }

  static Future<void> _saveTmdbCache(List<Movie> movies) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final list = movies.map((m) => {...m.toMap(), 'id': m.id}).toList();
      await prefs.setString('tmdb_cache_v1', jsonEncode(list));
    } catch (_) {}
  }

  static Future<void> _syncTmdbToFirestore(List<Movie> movies) async {
    if (Firebase.apps.isEmpty) return;
    final db = FirebaseFirestore.instance;
    final batch = db.batch();
    for (final m in movies) {
      batch.set(db.collection('movies').doc(m.id), m.toMap());
    }
    await batch.commit();
  }

  static Future<List<Movie>> _loadTmdbCache() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString('tmdb_cache_v1');
      if (raw == null) return [];
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map((m) => Movie.fromMap(m['id'] ?? '', m)).toList();
    } catch (_) {
      return [];
    }
  }

  static Future<List<Movie>> _localMovies() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('admin_movies');
    if (raw == null) return [];
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list
          .map((m) => Movie.fromMap(m['id'] ?? '', m))
          .where((m) => !_isSampleId(m.id))
          .toList();
    } catch (_) { return []; }
  }

  static Future<void> saveLocal(List<Movie> movies) async {
    final prefs = await SharedPreferences.getInstance();
    final list = movies.map((m) => {...m.toMap(), 'id': m.id}).toList();
    await prefs.setString('admin_movies', jsonEncode(list));
  }

  static Future<void> addMovie(Movie m) async {
    try {
      if (Firebase.apps.isNotEmpty) {
        await FirebaseFirestore.instance.collection('movies').add(m.toMap());
      }
    } catch (_) {}
    final all = await _localMovies();
    final base = all.where((x) => !x.id.startsWith('s')).toList();
    await saveLocal([...base, m]);
  }

  static Future<void> deleteMovie(String id) async {
    try {
      if (Firebase.apps.isNotEmpty) {
        await FirebaseFirestore.instance.collection('movies').doc(id).delete();
      }
    } catch (_) {}
    final all = await _localMovies();
    await saveLocal(all.where((m) => m.id != id).toList());
  }

  static Future<void> setTrending(List<String> trendingIds) async {
    final all = await getAll();
    final updated = all.map((m) => Movie(
      id: m.id, title: m.title, description: m.description, category: m.category,
      language: m.language, posterUrl: m.posterUrl, videoUrl: m.videoUrl,
      type: m.type, year: m.year, rating: m.rating,
      isTrending: trendingIds.contains(m.id), qualities: m.qualities,
      episodes: m.episodes, categories: m.categories,
    )).toList();
    await saveLocal(updated);
    try {
      if (Firebase.apps.isNotEmpty) {
        for (final m in updated) {
          await FirebaseFirestore.instance.collection('movies').doc(m.id).set(m.toMap(), SetOptions(merge: true));
        }
      }
    } catch (_) {}
  }
}

class Prefs {
  static Future<List<String>> searchHistory() async {
    final p = await SharedPreferences.getInstance();
    return p.getStringList('search_history') ?? [];
  }
  static Future<void> addSearch(String q) async {
    if (q.trim().isEmpty) return;
    final p = await SharedPreferences.getInstance();
    final h = await searchHistory();
    h.remove(q); h.insert(0, q);
    await p.setStringList('search_history', h.take(20).toList());
  }
  static Future<void> removeSearch(String q) async {
    final p = await SharedPreferences.getInstance();
    final h = await searchHistory(); h.remove(q);
    await p.setStringList('search_history', h);
  }
  static Future<void> clearSearch() async {
    final p = await SharedPreferences.getInstance();
    await p.remove('search_history');
  }
  static Future<String> username() async {
    final p = await SharedPreferences.getInstance();
    var u = p.getString('username');
    if (u == null) {
      u = 'flix_user_${1000 + DateTime.now().millisecond % 9000}';
      await p.setString('username', u);
    }
    return u;
  }
  static Future<String> adminPin() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('admin_pin') ?? '1234';
  }
  static Future<void> setAdminPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('admin_pin', pin);
  }
  static Future<String> downloadLink() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('download_link') ?? '';
  }
  static Future<void> setDownloadLink(String link) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('download_link', link);
  }
  static Future<String?> vipPlan() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('vip_plan');
  }
  static Future<void> saveVipOrder({required String plan, required int amount, required int months, String utr = ''}) async {
    final p = await SharedPreferences.getInstance();
    final expiry = DateTime.now().add(Duration(days: months * 30));
    await p.setString('vip_plan', plan);
    await p.setInt('vip_amount', amount);
    await p.setInt('vip_expiry', expiry.millisecondsSinceEpoch);
    await p.setString('vip_utr', utr);
    await p.setString('vip_date', DateTime.now().toIso8601String());
  }
  static Future<bool> isVipActive() async {
    final p = await SharedPreferences.getInstance();
    final expiry = p.getInt('vip_expiry');
    if (expiry != null) return DateTime.now().millisecondsSinceEpoch < expiry;
    final plan = p.getString('vip_plan');
    return plan != null && plan.isNotEmpty;
  }
  static Future<Map<String, String>> vipOrder() async {
    final p = await SharedPreferences.getInstance();
    return {
      'plan': p.getString('vip_plan') ?? '',
      'amount': '${p.getInt('vip_amount') ?? 0}',
      'utr': p.getString('vip_utr') ?? '',
      'date': p.getString('vip_date') ?? '',
      'expiry': '${p.getInt('vip_expiry') ?? 0}',
    };
  }
  static Future<int> invitedCount() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('invited_count') ?? 0;
  }
  static Future<void> addInvite() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('invited_count', await invitedCount() + 1);
  }
  static int adFreeDays(int invited) {
    var d = 0;
    if (invited >= 1) d += 3;
    if (invited >= 3) d += 5;
    if (invited >= 5) d += 10;
    if (invited >= 7) d += 15;
    if (invited >= 10) d += 3650;
    return d;
  }
}

class WatchEntry {
  final String movieId; final int position, duration;
  WatchEntry(this.movieId, this.position, this.duration);
  Map<String, dynamic> toMap() => {'movieId': movieId, 'position': position, 'duration': duration};
  factory WatchEntry.fromMap(Map<String, dynamic> m) =>
      WatchEntry(m['movieId'], m['position'] ?? 0, m['duration'] ?? 0);
}
Future<List<WatchEntry>> getWatchHistory() async {
  final p = await SharedPreferences.getInstance();
  final raw = p.getString('watch_history');
  if (raw == null) return [];
  try { return (jsonDecode(raw) as List).map((e) => WatchEntry.fromMap(Map<String, dynamic>.from(e))).toList(); } catch (_) { return []; }
}
Future<void> saveWatchPosition(String movieId, int pos, int dur) async {
  if (dur <= 0 || pos <= 0) return;
  final p = await SharedPreferences.getInstance();
  final list = await getWatchHistory();
  list.removeWhere((e) => e.movieId == movieId);
  list.insert(0, WatchEntry(movieId, pos, dur));
  await p.setString('watch_history', jsonEncode(list.map((e) => e.toMap()).toList()));
}
Future<void> removeWatch(String movieId) async {
  final p = await SharedPreferences.getInstance();
  final list = await getWatchHistory();
  list.removeWhere((e) => e.movieId == movieId);
  await p.setString('watch_history', jsonEncode(list.map((e) => e.toMap()).toList()));
}
String fmtTime(int seconds) {
  final h = seconds ~/ 3600, m = (seconds % 3600) ~/ 60, s = seconds % 60;
  if (h > 0) return '${h.toString().padLeft(2, '0')}:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
}

class FitRectangleImage extends StatelessWidget {
  final String url;
  const FitRectangleImage({super.key, required this.url});
    @override
  Widget build(BuildContext context) {
    if (url.isEmpty) return Container(color: kCard2);
    return Container(
      color: Colors.black,
      child: Stack(children: [
        Positioned.fill(child: Image.network(url, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(color: Colors.black))),
        Positioned.fill(child: Image.network(url, fit: BoxFit.contain, errorBuilder: (_, __, ___) => Container(color: Colors.black))),
      ]),
    );
  }
}

class MovieCard extends StatelessWidget {
  final Movie movie; final double width;
  const MovieCard({super.key, required this.movie, this.width = 110});
  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth.isFinite ? constraints.maxWidth : (width.isFinite ? width : 110.0);
      return GestureDetector(
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: movie))),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Stack(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(8),
                  child: Image.network(movie.posterUrl, width: w, height: w * 1.45, fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Container(width: w, height: w * 1.45, color: kCard2, child: const Icon(Icons.movie, color: kGrey))),
                ),
                Positioned(top: 0, left: 0, child: Container(color: kBlue, padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2), child: Text(movie.language, style: const TextStyle(fontSize: 10, color: Colors.white)))),
                Positioned(bottom: 4, right: 4, child: Text(movie.rating.toStringAsFixed(1), style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 13))),
              ],
            ),
            const SizedBox(height: 4),
            SizedBox(width: w, child: Text(movie.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
          ],
        ),
      );
    });
  }
}

class SplashScreen extends StatefulWidget {
  const SplashScreen({super.key});
  @override
  State<SplashScreen> createState() => _SplashScreenState();
}
class _SplashScreenState extends State<SplashScreen> {
  @override
  void initState() {
    super.initState();
    Future.delayed(const Duration(seconds: 2), () {
      if (mounted) Navigator.pushReplacement(context, MaterialPageRoute(builder: (_) => const MainShell()));
    });
  }
  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      backgroundColor: Color(0xFF0A0F1E),
      body: Center(
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          CircleAvatar(radius: 32, backgroundColor: kRed, child: Icon(Icons.play_arrow, color: Colors.black, size: 38)),
          SizedBox(width: 12),
          Text('FLIX', style: TextStyle(color: kRed, fontSize: 52, fontWeight: FontWeight.w900, letterSpacing: 2)),
        ]),
      ),
    );
  }
}

class MainShell extends StatefulWidget {
  const MainShell({super.key});
  @override
  State<MainShell> createState() => _MainShellState();
}
class _MainShellState extends State<MainShell> {
  int _index = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [const HomeScreen(), const CategoriesScreen(), const MeScreen()];
    return Scaffold(
      body: pages[_index],
      bottomNavigationBar: BottomNavigationBar(
        backgroundColor: const Color(0xFF111827),
        selectedItemColor: Colors.white, unselectedItemColor: kGrey,
        currentIndex: _index,
        onTap: (i) => setState(() => _index = i),
        items: [
          BottomNavigationBarItem(icon: const Icon(Icons.home), label: Lang.t('navHome')),
          BottomNavigationBarItem(icon: const Icon(Icons.folder), label: Lang.t('navCategories')),
          BottomNavigationBarItem(icon: const Icon(Icons.person), label: Lang.t('navMe')),
        ],
      ),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}
class _HomeScreenState extends State<HomeScreen> {
  late Future<List<Movie>> _future;
  final _page = PageController();
  int _pageIndex = 0;
  int _hindiPages = 6;
  bool _loadingMore = false;
  Timer? _timer;
  int _loadGen = 0;

  void _refreshInBackground() {
    final gen = ++_loadGen;
    MovieRepo.getAll(hindiPages: _hindiPages).then((movies) {
      if (!mounted || gen != _loadGen) return;
      setState(() => _future = Future.value(movies));
    }).catchError((_) {});
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _hindiPages >= 10) return;
    ++_loadGen;
    setState(() {
      _loadingMore = true;
      _hindiPages += 4;
      _future = MovieRepo.getAll(hindiPages: _hindiPages);
    });
    try { await _future; } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
  }

  @override
  void initState() {
    super.initState();
    _future = MovieRepo.getCached();
    _refreshInBackground();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) UpdateChecker.checkAndPrompt(context);
      });
    });
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_page.hasClients) return;
      _future.then((movies) {
        final tmdb = movies.where((m) => m.id.startsWith('tmdb_')).toList();
        final t = movies.where((m) => m.isTrending).toList();
        final list = tmdb.isNotEmpty ? tmdb.take(5).toList() : (t.isEmpty ? movies : t);
        if (list.isEmpty) return;
        final next = (_pageIndex + 1) % list.length;
        _page.animateToPage(next, duration: const Duration(milliseconds: 500), curve: Curves.easeInOut);
      });
    });
  }
  @override
  void dispose() { _timer?.cancel(); _page.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: FutureBuilder<List<Movie>>(
        future: _future,
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: kRed));
          final movies = snap.data!;
          if (movies.isEmpty) {
            return Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                const Icon(Icons.movie_outlined, size: 64, color: kGrey),
                const SizedBox(height: 12),
                Text(Lang.t('noMovies'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                Text(Lang.t('noMoviesHint'), style: const TextStyle(color: kGrey), textAlign: TextAlign.center),
                const SizedBox(height: 16),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white),
                  onPressed: _refreshInBackground,
                  child: Text(Lang.t('refresh'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
                TextButton(
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
                  child: Text(Lang.t('search')),
                ),
              ]),
            );
          }
          final trending = movies.where((m) => m.isTrending).toList();
          final tmdbMovies = movies.where((m) => m.id.startsWith('tmdb_')).toList();
          final slider = tmdbMovies.isNotEmpty
              ? tmdbMovies.take(5).toList()
              : (trending.isEmpty ? movies.take(5).toList() : trending.take(5).toList());
          return SingleChildScrollView(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Padding(
                padding: const EdgeInsets.all(12),
                child: Row(children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen())),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                        decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(10)),
                        child: Row(children: [const Icon(Icons.search, color: kGrey), const SizedBox(width: 8), Text(Lang.t('searchHint'), style: const TextStyle(color: kGrey))]),
                      ),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.refresh), onPressed: _refreshInBackground),
                  IconButton(icon: const Icon(Icons.history), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()))),
                  IconButton(icon: const Icon(Icons.download), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()))),
                ]),
              ),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(Lang.t('trending'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              const SizedBox(height: 10),
              SizedBox(
                height: 220,
                child: PageView.builder(
                  controller: _page,
                  onPageChanged: (i) => setState(() => _pageIndex = i),
                  itemCount: slider.length,
                  itemBuilder: (context, i) {
                    final m = slider[i];
                    return GestureDetector(
                      onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: m))),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: Stack(children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(10),
                            child: SizedBox(width: double.infinity, height: 220, child: FitRectangleImage(url: m.rectangleImageUrl)),
                          ),
                          Positioned(left: 12, bottom: 12, child: Text(m.title, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold, shadows: [Shadow(blurRadius: 8, color: Colors.black)]))),
                        ]),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 8),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: List.generate(slider.length, (i) => Container(margin: const EdgeInsets.symmetric(horizontal: 3), width: _pageIndex == i ? 18.0 : 7.0, height: 7, decoration: BoxDecoration(color: _pageIndex == i ? kRed : Colors.white54, borderRadius: BorderRadius.circular(4))))),
              const SizedBox(height: 20),
              Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text(Lang.t('popular'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: GridView.builder(
                  shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 12),
                  itemCount: movies.length,
                  itemBuilder: (context, i) => MovieCard(movie: movies[i], width: double.infinity),
                ),
              ),
              if (_hindiPages < 10)
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 16, 12, 0),
                  child: SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white),
                      onPressed: _loadingMore ? null : _loadMore,
                      child: Text(_loadingMore ? Lang.t('loading') : Lang.t('loadMore'), style: const TextStyle(fontWeight: FontWeight.bold)),
                    ),
                  ),
                ),
              const SizedBox(height: 16),
            ]),
          );
        },
      ),
    );
  }
}

class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});
    @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}
class _CategoriesScreenState extends State<CategoriesScreen> {
  String _type = 'Movies';
  final Set<String> _genresSelected = {};
  String _year = 'All';
  String _sort = 'Popularity';
  final _genres = ['Adventure', 'Romance', 'Horror', 'Family', 'Action', 'Thriller', 'Comedy', 'Drama'];
  final _years = ['All', '2026', '2025', '2024', '2023', '2022'];
  final _sorts = ['Popularity', 'Latest', 'Top today'];

  String _chipLabel(String e) {
    if (e == 'All') return Lang.t('all');
    if (e == 'Popularity') return Lang.t('sortPopularity');
    if (e == 'Latest') return Lang.t('sortLatest');
    if (e == 'Top today') return Lang.t('sortTop');
    return e;
  }

  Widget _chips(List<String> items, String selected, ValueChanged<String> onPick) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items.map((e) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: ChoiceChip(
          label: Text(_chipLabel(e)), selected: selected == e,
          selectedColor: kCard2, backgroundColor: Colors.transparent,
          labelStyle: TextStyle(color: selected == e ? Colors.white : kGrey, fontWeight: selected == e ? FontWeight.bold : FontWeight.normal),
          onSelected: (_) => setState(() => onPick(e)),
        ),
      )).toList()),
    );
  }

  Widget _genreChips() {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: [
        Padding(
          padding: const EdgeInsets.only(right: 10),
          child: FilterChip(
            label: Text(Lang.t('all')), selected: _genresSelected.isEmpty,
            selectedColor: kCard2, backgroundColor: Colors.transparent,
            labelStyle: TextStyle(color: _genresSelected.isEmpty ? Colors.white : kGrey, fontWeight: _genresSelected.isEmpty ? FontWeight.bold : FontWeight.normal),
            onSelected: (_) => setState(() => _genresSelected.clear()),
          ),
        ),
        ..._genres.map((e) => Padding(
          padding: const EdgeInsets.only(right: 10),
          child: FilterChip(
            label: Text(e), selected: _genresSelected.contains(e),
            selectedColor: kCard2, backgroundColor: Colors.transparent,
            labelStyle: TextStyle(color: _genresSelected.contains(e) ? Colors.white : kGrey, fontWeight: _genresSelected.contains(e) ? FontWeight.bold : FontWeight.normal),
            onSelected: (_) => setState(() {
              if (_genresSelected.contains(e)) { _genresSelected.remove(e); } else { _genresSelected.add(e); }
            }),
          ),
        )),
      ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.all(12),
          child: Row(children: [
            Expanded(child: Center(child: Text(Lang.t('catTitle'), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
            IconButton(icon: const Icon(Icons.search), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(children: [
            Row(children: [
              ChoiceChip(label: Text(Lang.t('typeMovies')), selected: _type == 'Movies', selectedColor: kCard2, onSelected: (_) => setState(() => _type = 'Movies')),
              const SizedBox(width: 10),
              ChoiceChip(label: Text(Lang.t('typeTv')), selected: _type == 'TV Shows', selectedColor: kCard2, onSelected: (_) => setState(() => _type = 'TV Shows')),
              const SizedBox(width: 10),
              ChoiceChip(label: Text(Lang.t('typeWeb')), selected: _type == 'Web Series', selectedColor: kCard2, onSelected: (_) => setState(() => _type = 'Web Series')),
            ]),
            const SizedBox(height: 10),
            _genreChips(),
            const SizedBox(height: 10),
            _chips(_years, _year, (v) => _year = v),
            const SizedBox(height: 10),
            _chips(_sorts, _sort, (v) => _sort = v),
          ]),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: FutureBuilder<List<Movie>>(
            future: MovieRepo.getAll(),
            builder: (context, snap) {
              if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: kRed));
              final wantedType = _type == 'Movies' ? 'Movie' : _type == 'TV Shows' ? 'TV Show' : 'Web Series';
              var list = snap.data!.where((m) => m.type == wantedType).toList();
              if (_genresSelected.isNotEmpty) list = list.where((m) => m.allCategories.any((c) => _genresSelected.contains(c))).toList();
              if (_year != 'All') list = list.where((m) => m.year.toString() == _year).toList();
              if (_sort == 'Latest') list.sort((a, b) => b.year.compareTo(a.year));
              else list.sort((a, b) => b.rating.compareTo(a.rating));
              if (list.isEmpty) return Center(child: Text(Lang.t('noCategory'), textAlign: TextAlign.center, style: const TextStyle(color: kGrey)));
              return GridView.builder(
                padding: const EdgeInsets.all(12),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 4, childAspectRatio: 0.58, crossAxisSpacing: 8, mainAxisSpacing: 12),
                itemCount: list.length,
                itemBuilder: (context, i) => MovieCard(movie: list[i], width: double.infinity),
              );
            },
          ),
        ),
      ]),
    );
  }
}

class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override
  State<SearchScreen> createState() => _SearchScreenState();
}
class _SearchScreenState extends State<SearchScreen> {
  String _q = '';
  final _ctrl = TextEditingController();
  List<String> _history = [];
  List<Movie> _all = [];
  List<Movie> _tmdbResults = [];
  int _searchSeq = 0;
  @override
  void initState() {
    super.initState();
    _load();
  }
  Future<void> _load() async {
    _history = await Prefs.searchHistory();
    _all = await MovieRepo.getAll();
    if (mounted) setState(() {});
  }
  Future<void> _searchTmdb(String q) async {
    final seq = ++_searchSeq;
    if (q.trim().isEmpty) {
      if (mounted) setState(() => _tmdbResults = []);
      return;
    }
    final found = await Tmdb.searchMovies(q);
    if (!mounted || seq != _searchSeq) return;
    setState(() => _tmdbResults = found);
  }
  List<Movie> get _results {
    if (_q.isEmpty) return [];
    final local = _all.where((m) => m.title.toLowerCase().contains(_q.toLowerCase()) || m.categoriesText.toLowerCase().contains(_q.toLowerCase())).toList();
    final ids = local.map((m) => m.id).toSet();
    return [...local, ..._tmdbResults.where((m) => !ids.contains(m.id))];
  }
  Future<void> _open(Movie m) async {
    await Prefs.addSearch(_q.isEmpty ? m.title : _q);
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: m)));
  }
  @override
  Widget build(BuildContext context) {
    final results = _results;
    final popular = [..._all]..sort((a, b) => b.rating.compareTo(a.rating));
    return Scaffold(
      appBar: AppBar(
        title: TextField(
          controller: _ctrl,
          autofocus: true,
          decoration: InputDecoration(hintText: Lang.t('searchFieldHint'), border: InputBorder.none, hintStyle: const TextStyle(color: kGrey)),
          onChanged: (v) { setState(() => _q = v); _searchTmdb(v); },
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Lang.t('cancel'), style: const TextStyle(color: Colors.white)))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_q.isEmpty) ...[
            Row(children: [
              Expanded(child: Text(Lang.t('searchHistory'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.delete_outline, color: kGrey), onPressed: () async { await Prefs.clearSearch(); _load(); }),
            ]),
            const SizedBox(height: 8),
            if (_history.isEmpty)
              Text(Lang.t('nothingSearched'), style: const TextStyle(color: kGrey))
            else
              Wrap(spacing: 8, runSpacing: 8, children: _history.map((h) => InputChip(
                label: Text(h), backgroundColor: kCard2,
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () async { await Prefs.removeSearch(h); _load(); },
                onPressed: () { _ctrl.text = h; setState(() => _q = h); _searchTmdb(h); },
              )).toList()),
            const SizedBox(height: 24),
            Text(Lang.t('popularSearches'), style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 12),
            ...popular.take(7).map((m) => ListTile(
              contentPadding: EdgeInsets.zero,
              leading: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(m.posterUrl, width: 50, height: 70, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(width: 50, height: 70, color: kCard2))),
              title: Row(children: [Expanded(child: Text(m.title)), Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2), decoration: BoxDecoration(color: m.rating >= 8.5 ? Colors.red : Colors.orange.shade200, borderRadius: BorderRadius.circular(4)), child: Text(m.rating >= 8.5 ? 'HOT' : 'TOP', style: const TextStyle(fontSize: 11, color: Colors.black, fontWeight: FontWeight.bold)))]),
              subtitle: Text(m.category),
              trailing: IconButton(icon: const Icon(Icons.play_arrow, color: Colors.white), onPressed: () => _open(m)),
              onTap: () => _open(m),
            )),
          ] else ...[
            if (results.isEmpty) ...[
              Text(Lang.tr('noExactMatch', '{q}', _q), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Text(Lang.t('relatedMovies'), style: const TextStyle(color: kGrey)),
              const SizedBox(height: 12),
              GridView.builder(
                shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 12),
                itemCount: popular.length,
                itemBuilder: (context, i) => MovieCard(movie: popular[i], width: double.infinity),
              ),
            ] else
              GridView.builder(
                shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 12),
                itemCount: results.length,
                itemBuilder: (context, i) => MovieCard(movie: results[i], width: double.infinity),
              ),
          ],
        ]),
      ),
    );
  }
}

// ---------------- DETAILS ----------------
// CHANGED: Watch Now + episode tap now route TMDB items to
// NexStreamPlayerScreen (WebView), while Admin-added movies with a
// real videoUrl still use the original PlayerScreen unchanged.
class DetailsScreen extends StatefulWidget {
  final Movie movie;
  const DetailsScreen({super.key, required this.movie});
  @override
  State<DetailsScreen> createState() => _DetailsScreenState();
}
class _DetailsScreenState extends State<DetailsScreen> {
  bool _fav = false;
  @override
  void initState() {
    super.initState();
    _loadFav();
  }
  Future<void> _loadFav() async {
    final p = await SharedPreferences.getInstance();
    setState(() => _fav = (p.getStringList('favorites') ?? []).contains(widget.movie.id));
  }
  Future<void> _toggleFav() async {
    final p = await SharedPreferences.getInstance();
    final list = p.getStringList('favorites') ?? [];
    if (list.contains(widget.movie.id)) { list.remove(widget.movie.id); } else { list.add(widget.movie.id); }
    await p.setStringList('favorites', list);
    setState(() => _fav = !_fav);
  }
  Future<void> _download() async {
    if (widget.movie.videoUrl.isEmpty && widget.movie.episodes.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('noVideo'))));
      return;
    }
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File('${dir.path}/flix_${widget.movie.id}.mp4');
      await Dio().download(widget.movie.videoUrl, file.path);
      final p = await SharedPreferences.getInstance();
      final list = p.getStringList('downloaded') ?? [];
      if (!list.contains(widget.movie.id)) list.add(widget.movie.id);
      await p.setStringList('downloaded', list);
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('downloadedMsg'))));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }

  void _playNow({int episodeIndex = 0}) async {
    final m = widget.movie;
    // TMDB items -> NexStream embed player (WebView).
    if (NexStreamHelper.canPlay(m)) {
      Navigator.push(context, MaterialPageRoute(
          builder: (_) => NexStreamPlayerScreen(movie: m, episodeIndex: episodeIndex)));
      return;
    }
    // Legacy path: admin-added movie with a real videoUrl.
    if (m.videoUrl.isEmpty && m.episodes.isEmpty) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('tmdbOnly'))));
      return;
    }
    final hist = await getWatchHistory();
    final entry = hist.where((e) => e.movieId == m.id).toList();
    final start = entry.isEmpty ? 0 : entry.first.position;
    if (!mounted) return;
    Navigator.push(context, MaterialPageRoute(
        builder: (_) => PlayerScreen(movie: m, startAt: start, episodeIndex: episodeIndex)));
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.movie;
    return Scaffold(
      appBar: AppBar(title: Text(m.title)),
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          AspectRatio(
            aspectRatio: 16 / 9,
            child: FitRectangleImage(url: m.rectangleImageUrl),
          ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(m.title, style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              Row(children: [const Icon(Icons.star, color: Colors.amber, size: 18), Text(' ${m.rating}   '), Expanded(child: Text('${m.year}  •  ${m.categoriesText}  •  ${m.language}  •  ${m.type}'))]),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () => _playNow(),
                  icon: const Icon(Icons.play_arrow, color: Colors.white),
                  label: Text(Lang.t('watchNow'), style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: _toggleFav, icon: Icon(_fav ? Icons.favorite : Icons.favorite_border, color: kRed), label: Text(_fav ? Lang.t('saved') : Lang.t('favorite')))),
                const SizedBox(width: 10),
                Expanded(child: OutlinedButton.icon(onPressed: _download, icon: const Icon(Icons.download), label: Text(Lang.t('download')))),
              ]),
              const SizedBox(height: 20),
              Text(Lang.t('description'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(m.description, style: const TextStyle(color: Colors.white70, height: 1.5)),
              if (m.type == 'TV Show' || m.type == 'Web Series') ...[
                const SizedBox(height: 20),
                Text('${Lang.t('episodes')} (${m.episodes.isNotEmpty ? m.episodes.length : 3})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(Lang.tr('episodesIn', '{n}', '${m.episodes.isNotEmpty ? m.episodes.length : 3}').replaceAll('{t}', m.type.toLowerCase()), style: const TextStyle(color: kGrey)),
                ...List.generate(m.episodes.isNotEmpty ? m.episodes.length : 3, (i) => ListTile(
                  leading: const Icon(Icons.play_circle_fill, color: kRed),
                  title: Text('${Lang.t('episode')} ${i + 1}'),
                  subtitle: Text(m.type),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _playNow(episodeIndex: i),
                )),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------- PLAYER (unchanged) ----------------
class PlayerScreen extends StatefulWidget {
  final Movie movie; final int startAt; final int episodeIndex;
  const PlayerScreen({super.key, required this.movie, this.startAt = 0, this.episodeIndex = 0});
  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}
class _PlayerScreenState extends State<PlayerScreen> {
  VideoPlayerController? _c;
  bool _showControls = true;
  String _quality = 'Auto';
  late int _episodeIndex;
  String? _flash;
  Timer? _flashTimer;
  bool _advancing = false;
  List<String> get _episodeUrls => widget.movie.episodes.isNotEmpty ? widget.movie.episodes : [widget.movie.videoUrl];
  bool get _isSeries => widget.movie.type == 'TV Show' || widget.movie.type == 'Web Series';
  @override
  void initState() {
    super.initState();
    _episodeIndex = widget.episodeIndex.clamp(0, _episodeUrls.length - 1);
    SystemChrome.setPreferredOrientations([DeviceOrientation.landscapeLeft, DeviceOrientation.landscapeRight]);
    _init(_episodeUrls[_episodeIndex]);
  }
  Future<void> _init(String url) async {
    final old = _c; await old?.dispose();
    final c = VideoPlayerController.networkUrl(Uri.parse(url));
    await c.initialize();
    if (widget.startAt > 0 && _episodeIndex == widget.episodeIndex) await c.seekTo(Duration(seconds: widget.startAt));
    c.play();
    c.addListener(() {
      if (!mounted) return;
      if (c.value.isInitialized && c.value.duration.inSeconds > 0 &&
          c.value.position.inSeconds >= c.value.duration.inSeconds &&
          !c.value.isPlaying && !_advancing) {
        _playNext(auto: true);
      }
      if (mounted) setState(() {});
    });
    setState(() => _c = c);
  }
  Future<void> _playEpisode(int index) async {
    if (index < 0 || index >= _episodeUrls.length) return;
    _advancing = true;
    setState(() => _episodeIndex = index);
    await _init(_episodeUrls[index]);
    _advancing = false;
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${Lang.t('playingEpisode')} ${index + 1}'), duration: const Duration(seconds: 2)));
  }
  void _playNext({bool auto = false}) {
    if (_episodeIndex + 1 < _episodeUrls.length) {
      _playEpisode(_episodeIndex + 1);
    } else if (!auto && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('lastEpisode'))));
    }
  }
  @override
  void dispose() {
    _flashTimer?.cancel();
    final c = _c;
    if (c != null && c.value.isInitialized) {
      saveWatchPosition(widget.movie.id, c.value.position.inSeconds, c.value.duration.inSeconds);
    }
    SystemChrome.setPreferredOrientations(DeviceOrientation.values);
    c?.dispose();
    super.dispose();
  }
  void _seek(int seconds) {
    final c = _c; if (c == null) return;
    final target = c.value.position + Duration(seconds: seconds);
    c.seekTo(target < Duration.zero ? Duration.zero : target);
    _flashTimer?.cancel();
    setState(() => _flash = seconds < 0 ? '-10s' : '+10s');
    _flashTimer = Timer(const Duration(milliseconds: 800), () { if (mounted) setState(() => _flash = null); });
  }
  @override
  Widget build(BuildContext context) {
    final c = _c;
    return Scaffold(
      backgroundColor: Colors.black,
      body: GestureDetector(
        onTap: () => setState(() => _showControls = !_showControls),
        onDoubleTapDown: (details) {
          final width = MediaQuery.of(context).size.width;
          _seek(details.globalPosition.dx < width / 2 ? -10 : 10);
          setState(() => _showControls = true);
        },
        child: Stack(children: [
          Center(child: c == null || !c.value.isInitialized ? const CircularProgressIndicator(color: kRed) : AspectRatio(aspectRatio: c.value.aspectRatio, child: VideoPlayer(c))),
          if (_flash != null)
            Center(child: Container(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8), decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(20)), child: Text(_flash!, style: const TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold)))),
          if (_showControls && c != null && c.value.isInitialized) ...[
            Positioned(top: 16, left: 12, child: Row(children: [
              IconButton(icon: const Icon(Icons.arrow_back, color: Colors.white), onPressed: () => Navigator.pop(context)),
              Expanded(child: Text(_isSeries ? '${widget.movie.title} • ${Lang.t('episode')} ${_episodeIndex + 1}' : widget.movie.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
              PopupMenuButton<String>(
                icon: const Icon(Icons.settings, color: Colors.white),
                onSelected: (q) {
                  setState(() => _quality = q);
                  if (q != 'Auto' && widget.movie.qualities.containsKey(q)) {
                    final pos = c.value.position.inSeconds;
                    _init(widget.movie.qualities[q]!).then((_) => _c?.seekTo(Duration(seconds: pos)));
                  }
                },
                itemBuilder: (_) => ['Auto', ...widget.movie.qualities.keys].map((q) => PopupMenuItem(value: q, child: Text(q))).toList(),
              ),
            ])),
            Center(
              child: IconButton(iconSize: 72, icon: Icon(c.value.isPlaying ? Icons.pause_circle_filled : Icons.play_circle_filled, color: Colors.white), onPressed: () => c.value.isPlaying ? c.pause() : c.play()),
            ),
            Positioned(bottom: 12, left: 16, right: 16, child: Column(children: [
              Row(children: [
                Text(fmtTime(c.value.position.inSeconds), style: const TextStyle(color: Colors.white)),
                Expanded(child: Slider(
                  value: c.value.position.inSeconds.toDouble().clamp(0.0, c.value.duration.inSeconds.toDouble()).toDouble(),
                  max: c.value.duration.inSeconds.toDouble() == 0 ? 1.0 : c.value.duration.inSeconds.toDouble(),
                  activeColor: kRed,
                  onChanged: (v) => c.seekTo(Duration(seconds: v.toInt())),
                )),
                Text(fmtTime(c.value.duration.inSeconds), style: const TextStyle(color: Colors.white)),
                const SizedBox(width: 8),
                Text(_quality, style: const TextStyle(color: Colors.white70, fontSize: 12)),
              ]),
              if (_isSeries)
                Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Text('${Lang.t('episode')} ${_episodeIndex + 1} of ${_episodeUrls.length}', style: const TextStyle(color: Colors.white70)),
                  if (_episodeIndex + 1 < _episodeUrls.length) ...[
                    const SizedBox(width: 12),
                    TextButton.icon(onPressed: () => _playNext(), icon: const Icon(Icons.skip_next, color: Colors.white, size: 18), label: Text(Lang.t('nextEpisode'), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                  ],
                ]),
            ])),
          ],
        ]),
      ),
    );
  }
}

class MeScreen extends StatefulWidget {
  const MeScreen({super.key});
  @override
  State<MeScreen> createState() => _MeScreenState();
}
class _MeScreenState extends State<MeScreen> {
  String _username = '...';
  int _taps = 0;
  bool _vipActive = false;
  @override
  void initState() {
    super.initState();
    Prefs.username().then((u) { if (mounted) setState(() => _username = u); });
    Prefs.isVipActive().then((v) { if (mounted) setState(() => _vipActive = v); });
  }
  void _onAvatarTap() async {
    _taps++;
    if (_taps >= 5) {
      _taps = 0;
      final pinCtrl = TextEditingController();
      final entered = await showDialog<String>(context: context, builder: (_) => AlertDialog(
        title: Text(Lang.t('adminPin')),
        content: TextField(controller: pinCtrl, obscureText: true, keyboardType: TextInputType.number, decoration: InputDecoration(hintText: Lang.t('enterPin'))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(Lang.t('cancel'))),
          TextButton(onPressed: () => Navigator.pop(context, pinCtrl.text), child: Text(Lang.t('unlock'))),
        ],
      ));
      if (entered == null) return;
      final correct = await Prefs.adminPin();
      if (!mounted) return;
      if (entered == correct) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminScreen()));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('wrongPin'))));
      }
    }
  }
  Widget _tile(IconData icon, String title, VoidCallback onTap) => ListTile(
    leading: Icon(icon, color: kGrey), title: Text(title),
    trailing: const Icon(Icons.chevron_right, color: kGrey), onTap: onTap,
  );
  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: SingleChildScrollView(
        child: Column(children: [
          const SizedBox(height: 16),
          GestureDetector(
            onTap: _onAvatarTap,
            child: const CircleAvatar(radius: 40, backgroundColor: kCard2, child: Icon(Icons.person, size: 44, color: kGrey)),
          ),
          const SizedBox(height: 8),
          Text(_username, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          Text(Lang.t('meMovie'), style: const TextStyle(color: kGrey)),
          const SizedBox(height: 16),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFE8C88A), Color(0xFFD9A86A)]), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(_vipActive ? Lang.t('vipActive') : Lang.t('vipJoin'), style: const TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  if (!_vipActive) Text(Lang.t('vipDiscount'), style: const TextStyle(color: Colors.black54)),
                ])),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: Colors.white),
                  onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => _vipActive ? const OrderListScreen() : const VipScreen())),
                  child: Text(_vipActive ? Lang.t('orderList') : Lang.t('subscribe'), style: const TextStyle(color: Colors.black)),
                ),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          _tile(Icons.share, Lang.t('tileShare'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareScreen()))),
          _tile(Icons.language, Lang.t('tileLanguage'), () async {
            final code = await showDialog<String>(context: context, builder: (_) => SimpleDialog(
              title: Text(Lang.t('chooseLanguage')),
              children: [
                SimpleDialogOption(child: const Text('English'), onPressed: () => Navigator.pop(context, 'en')),
                SimpleDialogOption(child: const Text('हिन्दी (Hindi)'), onPressed: () => Navigator.pop(context, 'hi')),
              ],
            ));
            if (code != null) {
              await Lang.set(code);
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${Lang.t('languageSet')} ${code == 'hi' ? 'Hindi' : 'English'}')));
            }
          }),
          _tile(Icons.history, Lang.t('tileHistory'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()))),
          _tile(Icons.download, Lang.t('tileDownloads'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()))),
          _tile(Icons.favorite_border, Lang.t('tileFavorites'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FavoritesScreen()))),
          _tile(Icons.receipt_long, Lang.t('tileOrders'), () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrderListScreen()))),
          _tile(Icons.feedback_outlined, Lang.t('tileFeedback'), () {
            showDialog(context: context, builder: (_) => AlertDialog(title: Text(Lang.t('feedback')), content: TextField(decoration: InputDecoration(hintText: Lang.t('feedbackHint'))), actions: [TextButton(onPressed: () => Navigator.pop(context), child: Text(Lang.t('send')))]));
          }),
          _tile(Icons.support_agent, Lang.t('tileSupport'), () {
            showDialog(context: context, builder: (_) => AlertDialog(title: Text(Lang.t('customerService')), content: Text(Lang.t('customerServiceBody'))));
          }),
        ]),
      ),
    );
  }
}

class HistoryScreen extends StatefulWidget {
  const HistoryScreen({super.key});
  @override
  State<HistoryScreen> createState() => _HistoryScreenState();
}
class _HistoryScreenState extends State<HistoryScreen> {
  List<Movie> _movies = [];
  List<WatchEntry> _entries = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    _movies = await MovieRepo.getAll();
    _entries = await getWatchHistory();
    if (mounted) setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Lang.t('history')), actions: [IconButton(icon: const Icon(Icons.edit), onPressed: () async { final p = await SharedPreferences.getInstance(); await p.remove('watch_history'); _load(); })]),
      body: _entries.isEmpty
          ? Center(child: Text(Lang.t('noHistory'), textAlign: TextAlign.center, style: const TextStyle(color: kGrey)))
          : ListView.builder(
              itemCount: _entries.length,
              itemBuilder: (context, i) {
                final e = _entries[i];
                final m = _movies.where((x) => x.id == e.movieId).toList();
                if (m.isEmpty) return const SizedBox.shrink();
                final movie = m.first;
                final remaining = (e.duration - e.position).clamp(0, e.duration).toInt();
                return ListTile(
                  leading: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(movie.posterUrl, width: 60, height: 85, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(width: 60, height: 85, color: kCard2))),
                  title: Text(movie.title),
                  subtitle: Text('${Lang.t('remaining')} ${fmtTime(remaining)}', style: const TextStyle(color: Colors.red)),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline, color: kGrey), onPressed: () async { await removeWatch(e.movieId); _load(); }),
                  onTap: () {
                    // Route through DetailsScreen so NexStream/TMDB
                    // items get the correct player automatically.
                    Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: movie)));
                  },
                );
              },
            ),
    );
  }
}

class DownloadsScreen extends StatefulWidget {
  const DownloadsScreen({super.key});
  @override
  State<DownloadsScreen> createState() => _DownloadsScreenState();
}
class _DownloadsScreenState extends State<DownloadsScreen> {
  List<Movie> _movies = [];
  List<String> _downloaded = [];
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    _movies = await MovieRepo.getAll();
    final p = await SharedPreferences.getInstance();
    _downloaded = p.getStringList('downloaded') ?? [];
    if (mounted) setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    final downloadedMovies = _movies.where((m) => _downloaded.contains(m.id)).toList();
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(title: Text(Lang.t('myDownloads')), actions: [TextButton(onPressed: () {}, child: const Text('Edit', style: TextStyle(color: Colors.white)) )], bottom: TabBar(tabs: [Tab(text: Lang.t('downloading')), Tab(text: Lang.t('downloaded'))])),
        body: TabBarView(children: [
          Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.movie, size: 64, color: kGrey), const SizedBox(height: 12), Text(Lang.t('noContent'), style: const TextStyle(color: kGrey))])),
          downloadedMovies.isEmpty
              ? Center(child: Text(Lang.t('noDownloads'), textAlign: TextAlign.center, style: const TextStyle(color: kGrey)))
              : ListView.builder(itemCount: downloadedMovies.length, itemBuilder: (context, i) {
                  final m = downloadedMovies[i];
                  return ListTile(
                    leading: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(m.posterUrl, width: 60, height: 85, fit: BoxFit.cover)),
                    title: Text(m.title), subtitle: Text(Lang.t('downloadedTap')),
                    onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DetailsScreen(movie: m))),
                  );
                }),
        ]),
      ),
    );
  }
}

class FavoritesScreen extends StatelessWidget {
  const FavoritesScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Lang.t('myFavorites'))),
      body: FutureBuilder<List<Movie>>(
        future: MovieRepo.getAll(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: kRed));
          return FutureBuilder<List<String>>(
            future: SharedPreferences.getInstance().then((p) => p.getStringList('favorites') ?? []),
            builder: (context, favSnap) {
              final favs = snap.data!.where((m) => (favSnap.data ?? []).contains(m.id)).toList();
              if (favs.isEmpty) return Center(child: Text(Lang.t('noFavorites'), style: const TextStyle(color: kGrey)));
              return GridView.builder(padding: const EdgeInsets.all(12), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 12), itemCount: favs.length, itemBuilder: (context, i) => MovieCard(movie: favs[i], width: double.infinity));
            },
          );
        },
      ),
    );
  }
}

class OrderListScreen extends StatelessWidget {
  const OrderListScreen({super.key});

  String _dateOnly(String iso) => iso.isEmpty ? '-' : iso.split('T').first;
  String _expiryDate(String ms) {
    final v = int.tryParse(ms) ?? 0;
    if (v <= 0) return '-';
    return DateTime.fromMillisecondsSinceEpoch(v).toString().split(' ').first;
  }

  Widget _row(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(children: [
          Expanded(child: Text(label, style: const TextStyle(color: kGrey))),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ]),
      );

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(Lang.t('orderList'))),
      body: FutureBuilder<Map<String, String>>(
        future: Prefs.vipOrder(),
        builder: (context, snap) {
          if (snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: kRed));
          }
          final order = snap.data ?? {};
          final plan = order['plan'] ?? '';
          if (plan.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  const Icon(Icons.receipt_long, size: 64, color: kGrey),
                  const SizedBox(height: 16),
                  Text(Lang.t('notPurchased'), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  const SizedBox(height: 8),
                  Text(Lang.t('notPurchasedSub'), style: const TextStyle(color: kGrey), textAlign: TextAlign.center),
                ]),
              ),
            );
          }
          final amount = order['amount'] ?? '0';
          final utr = order['utr'] ?? '';
          final date = _dateOnly(order['date'] ?? '');
          final expiry = _expiryDate(order['expiry'] ?? '0');
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.workspace_premium, color: Colors.amber, size: 40),
                  const SizedBox(width: 16),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('${Lang.t('purchasedPlan')} $plan', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    Text(Lang.t('statusPurchased'), style: const TextStyle(color: Colors.green)),
                  ])),
                ]),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  _row(Lang.t('orderAmount'), '\u20B9$amount.00'),
                  const Divider(color: kGrey),
                  _row(Lang.t('orderDate'), date),
                  const Divider(color: kGrey),
                  _row(Lang.t('orderExpiry'), expiry),
                  if (utr.isNotEmpty) ...[
                    const Divider(color: kGrey),
                    _row(Lang.t('orderUtr'), utr),
                  ],
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}

class VipScreen extends StatefulWidget {
  const VipScreen({super.key});
  @override
  State<VipScreen> createState() => _VipScreenState();
}
class _VipScreenState extends State<VipScreen> {
  int _selected = 2;
  final _plans = [
    ('1 Month', 50, 100, 1), ('3 Months', 150, 300, 3),
    ('6 Months', 300, 600, 6), ('12 Months', 600, 1200, 12),
  ];

  String _upiUri() {
    final plan = _plans[_selected];
    return 'upi://pay?pa=${Uri.encodeComponent(kUpiId)}'
        '&pn=${Uri.encodeComponent(kUpiPayee)}'
        '&am=${plan.$2}.00&cu=INR'
        '&tn=${Uri.encodeComponent('Flix VIP ${plan.$1}')}';
  }

  Future<void> _payViaUpi() async {
    final uri = Uri.parse(_upiUri());
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } else if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('noUpiApp'))));
    }
  }

  Future<void> _confirmPayment() async {
    final plan = _plans[_selected];
    final utrCtrl = TextEditingController();
    final utr = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(Lang.t('confirmTitle')),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${Lang.t('payExact')}: \u20B9${plan.$2}.00'),
            const SizedBox(height: 12),
            TextField(
              controller: utrCtrl,
              decoration: InputDecoration(hintText: Lang.t('utrHint'), border: const OutlineInputBorder()),
            ),
            const SizedBox(height: 8),
            Text(Lang.t('utrHelp'), style: const TextStyle(color: kGrey, fontSize: 12)),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(Lang.t('cancel'))),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white),
            onPressed: () => Navigator.pop(context, utrCtrl.text.trim()),
            child: Text(Lang.t('activate')),
          ),
        ],
      ),
    );
    if (utr == null) return;
    await Prefs.saveVipOrder(plan: plan.$1, amount: plan.$2, months: plan.$4, utr: utr);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('vipActivated'))));
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final plan = _plans[_selected];
    return Scaffold(
      appBar: AppBar(title: Text(Lang.t('payment'))),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: const LinearGradient(colors: [Color(0xFFE8C88A), Color(0xFFD9A86A)]),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Text(Lang.t('vipBenefits'), style: const TextStyle(color: Colors.brown, fontSize: 20, fontWeight: FontWeight.bold))),
              const SizedBox(height: 16),
              Text(Lang.t('benefit1'), style: const TextStyle(color: Colors.brown)),
              const SizedBox(height: 8),
              Text(Lang.t('benefit2'), style: const TextStyle(color: Colors.brown)),
              const SizedBox(height: 8),
              Text(Lang.t('benefit3'), style: const TextStyle(color: Colors.brown)),
            ]),
          ),
          const SizedBox(height: 16),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, childAspectRatio: 1.4, crossAxisSpacing: 12, mainAxisSpacing: 12),
            itemCount: _plans.length,
            itemBuilder: (context, i) {
              final p = _plans[i];
              final sel = i == _selected;
              return GestureDetector(
                onTap: () => setState(() => _selected = i),
                child: Container(
                  decoration: BoxDecoration(color: sel ? Colors.white : const Color(0xFF1E2A4A), borderRadius: BorderRadius.circular(12)),
                  child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                    Text(p.$1, style: TextStyle(color: sel ? Colors.brown : Colors.white)),
                    Text('\u20B9 ${p.$2}.00', style: TextStyle(color: Colors.orange.shade700, fontSize: 20, fontWeight: FontWeight.bold)),
                    Text('\u20B9${p.$3}.00', style: TextStyle(color: sel ? Colors.grey : Colors.white54, decoration: TextDecoration.lineThrough)),
                  ]),
                ),
              );
            },
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Text('\u20B9 ${plan.$2}.00   ${plan.$1}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 20)),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: QrImageView(
                  data: _upiUri(),
                  version: QrVersions.auto,
                  size: 200,
                  backgroundColor: Colors.white,
                ),
              ),
              const SizedBox(height: 8),
              Text(Lang.t('scanQr'), style: const TextStyle(color: kGrey)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
                    decoration: BoxDecoration(color: kBg, borderRadius: BorderRadius.circular(10)),
                    child: Text(kUpiId, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton(
                  icon: const Icon(Icons.copy, color: Colors.white),
                  tooltip: Lang.t('copyUpi'),
                  onPressed: () async {
                    await Clipboard.setData(ClipboardData(text: kUpiId));
                    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(Lang.t('copied'))));
                  },
                ),
              ]),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: Colors.green.withOpacity(0.12), borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  const Icon(Icons.verified_user, color: Colors.green),
                  const SizedBox(width: 10),
                  Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(Lang.t('paySecureTitle'), style: const TextStyle(color: Colors.green, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 2),
                    Text(Lang.t('paySecureBody'), style: const TextStyle(color: kGrey, fontSize: 12)),
                  ])),
                ]),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: _payViaUpi,
                  child: Text(Lang.t('payInUpi'), style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton(
                  onPressed: _confirmPayment,
                  child: Text(Lang.t('iHavePaid'), style: const TextStyle(fontWeight: FontWeight.bold)),
                ),
              ),
              const SizedBox(height: 8),
              Text('${Lang.t('payExact')}: \u20B9${plan.$2}.00', style: const TextStyle(color: kGrey, fontSize: 12), textAlign: TextAlign.center),
            ]),
          ),
        ]),
      ),
    );
  }
}

class ShareScreen extends StatefulWidget {
  const ShareScreen({super.key});
  @override
  State<ShareScreen> createState() => _ShareScreenState();
}
class _ShareScreenState extends State<ShareScreen> {
  String _username = '';
  String _downloadLink = '';
  int _invited = 0;
  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    _username = await Prefs.username();
    _invited = await Prefs.invitedCount();
    _downloadLink = await Prefs.downloadLink();
    if (mounted) setState(() {});
  }
  @override
  Widget build(BuildContext context) {
    final days = Prefs.adFreeDays(_invited);
    return Scaffold(
      appBar: AppBar(title: Text(Lang.t('promotion')), actions: [TextButton(onPressed: () {}, child: Text(Lang.t('promotionRecord'), style: const TextStyle(color: Colors.white)))]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Text(Lang.tr('promoted', '{n}', '$_invited'), style: const TextStyle(fontSize: 18)),
              Text(Lang.tr('daysAdFree', '{n}', '$days'), style: const TextStyle(color: kGrey)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  QrImageView(
                    data: _username.isEmpty ? 'FLIX' : _username.toUpperCase(),
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                  ),
                  const SizedBox(height: 8),
                  Text('${Lang.t('myCode')} ${_username.toUpperCase()}', style: const TextStyle(color: Colors.grey)),
                ]),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () async {
                    final code = _username.toUpperCase();
                    final latest = await UpdateChecker.fetchLatest();
                    final apkLink = latest?.apkUrl ?? (_downloadLink.isNotEmpty ? _downloadLink : '');
                    final linkLine = apkLink.isNotEmpty
                        ? 'Download Flix APK here: $apkLink'
                        : 'Download link: no release APK yet. Download the latest flix-apk artifact from GitHub Actions, or set a link in Admin > App download link.';
                    final message = 'Hey! Download Flix and watch movies, TV shows and web series.\n\n'
                        'Use my invitation code: $code\n'
                        'When you download with my code, I get ad-free days, and you get Flix too.\n\n'
                        '$linkLine\n\n'
                        'Join Flix now and start watching!';
                    await SharePlus.instance.share(ShareParams(text: message));
                  },
                  child: Text(Lang.t('shareNow'), style: const TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text('The share message uses the direct APK download link from the latest GitHub release. If no release exists yet, set a link in Admin panel > App download link as a backup.', textAlign: TextAlign.center, style: TextStyle(color: kGrey, fontSize: 12)),
              ),
              TextButton(onPressed: () async { await Prefs.addInvite(); _load(); }, child: const Text('Demo: mark 1 friend as joined', style: TextStyle(color: kGrey))),
            ]),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(16)),
            child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Center(child: Text('Promotion Description', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              SizedBox(height: 12),
              Text('1. For every successful promotion of 1 person, 3 days of free advertising will be given, which can be stacked infinitely~'),
              SizedBox(height: 10),
              Text('2. A total of 3 people have been promoted, and an extra 5 days of free advertising~'),
              SizedBox(height: 10),
              Text('3. A total of 5 people have been promoted, and an extra 10 days of free advertising~'),
              SizedBox(height: 10),
              Text('4. A total of 7 people have been promoted, and an extra 15 days of free advertising~'),
              SizedBox(height: 10),
              Text('5. A total of 10 people have been promoted, and an extra 3650 days of free advertising~'),
            ]),
          ),
        ]),
      ),
    );
  }
}

class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});
  @override
  State<AdminScreen> createState() => _AdminScreenState();
}
class _AdminScreenState extends State<AdminScreen> {
  final _title = TextEditingController();
  final _desc = TextEditingController();
  final _year = TextEditingController(text: '2025');
  final _lang = TextEditingController(text: 'Hindi');
  final _rating = TextEditingController(text: '8.0');
  final _poster = TextEditingController();
  final _video = TextEditingController();
  final _q720 = TextEditingController();
  final _q1080 = TextEditingController();
  final _episodes = TextEditingController();
  final _pin = TextEditingController();
  final _downloadLink = TextEditingController();
  final Set<String> _selectedCategories = {'Action'};
  String _type = 'Movie';
  bool _trending = false;
  List<Movie> _movies = [];
  final _categories = ['Action', 'Romance', 'Thriller', 'Adventure', 'Horror', 'Family', 'Comedy', 'Drama'];

  @override
  void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    _movies = await MovieRepo.getAll();
    _downloadLink.text = await Prefs.downloadLink();
    if (mounted) setState(() {});
  }

  Widget _field(TextEditingController c, String label) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: TextField(controller: c, decoration: InputDecoration(labelText: label, border: const OutlineInputBorder())),
  );

  Future<void> _addMovie() async {
    if (_title.text.isEmpty || _video.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Title and Video link are required')));
      return;
    }
    final qualities = <String, String>{};
    if (_q720.text.isNotEmpty) qualities['720p'] = _q720.text;
    if (_q1080.text.isNotEmpty) qualities['1080p'] = _q1080.text;
    final episodeLinks = _episodes.text.split('\n').map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    if (_selectedCategories.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Select at least one category')));
      return;
    }
    final cats = _selectedCategories.toList();
    final m = Movie(
      id: DateTime.now().millisecondsSinceEpoch.toString(),
      title: _title.text, description: _desc.text, category: cats.first,
      language: _lang.text, posterUrl: _poster.text, videoUrl: _video.text,
      type: _type, year: int.tryParse(_year.text) ?? 2025,
      rating: double.tryParse(_rating.text) ?? 8.0, isTrending: _trending, qualities: qualities,
      episodes: episodeLinks, categories: cats,
    );
    await MovieRepo.addMovie(m);
    _title.clear(); _desc.clear(); _poster.clear(); _video.clear(); _q720.clear(); _q1080.clear(); _episodes.clear();
    setState(() => _trending = false);
    _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Movie added. It will now appear on Home / Categories.')));
  }

  @override
  Widget build(BuildContext context) {
    final trendingCount = _movies.where((m) => m.isTrending).length;
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Panel')),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Add Movie / Web Series', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
          const Text('Video link = YOUR hosted video link (Firebase Storage / your server). Only add videos you own or have a licence for.', style: TextStyle(color: kGrey, fontSize: 12)),
          const SizedBox(height: 12),
          _field(_title, 'Title'),
          _field(_desc, 'Description'),
          DropdownButtonFormField<String>(value: _type, decoration: const InputDecoration(labelText: 'Type', border: OutlineInputBorder()), items: const [DropdownMenuItem(value: 'Movie', child: Text('Movie')), DropdownMenuItem(value: 'TV Show', child: Text('TV Show')), DropdownMenuItem(value: 'Web Series', child: Text('Web Series'))], onChanged: (v) => setState(() => _type = v!)),
          const SizedBox(height: 12),
          const Text('Categories (tap to select more than one, e.g. Romance + Thriller)', style: TextStyle(fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Wrap(spacing: 8, runSpacing: 8, children: _categories.map((c) => FilterChip(
            label: Text(c), selected: _selectedCategories.contains(c),
            selectedColor: kCard2,
            labelStyle: TextStyle(color: _selectedCategories.contains(c) ? Colors.white : kGrey, fontWeight: _selectedCategories.contains(c) ? FontWeight.bold : FontWeight.normal),
            onSelected: (_) => setState(() {
              if (_selectedCategories.contains(c)) { _selectedCategories.remove(c); } else { _selectedCategories.add(c); }
            }),
          )).toList()),
          const SizedBox(height: 10),
          Row(children: [Expanded(child: _field(_year, 'Year')), const SizedBox(width: 10), Expanded(child: _field(_lang, 'Language')), const SizedBox(width: 10), Expanded(child: _field(_rating, 'Rating'))]),
          _field(_poster, 'Poster image link'),
          _field(_video, 'Video link (movie website / hosted video link)'),
          _field(_q720, 'Quality 720p link (optional)'),
          _field(_q1080, 'Quality 1080p link (optional)'),
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: TextField(controller: _episodes, maxLines: 4, decoration: const InputDecoration(labelText: 'Episode links for TV Show / Web Series (one link per line)', border: OutlineInputBorder())),
          ),
          SwitchListTile(title: const Text('Add to Trending (max 5)'), value: _trending, activeColor: kRed, onChanged: (v) => setState(() => _trending = v)),
          SizedBox(width: double.infinity, child: ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)), onPressed: _addMovie, child: const Text('Add Movie', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)))),
          const SizedBox(height: 16),
          const Text('App download link (used in the Share message)', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _downloadLink, decoration: const InputDecoration(labelText: 'Download page / file link', border: OutlineInputBorder()))),
            const SizedBox(width: 10),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white), onPressed: () async {
              await Prefs.setDownloadLink(_downloadLink.text.trim());
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Download link saved')));
            }, child: const Text('Save link', style: TextStyle(color: Colors.white))),
          ]),
          const SizedBox(height: 16),
          const Text('Change Admin PIN', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(child: TextField(controller: _pin, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'New PIN (at least 4 digits)', border: OutlineInputBorder()))),
            const SizedBox(width: 10),
            ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white), onPressed: () async {
              if (_pin.text.length < 4) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('PIN must be at least 4 digits'))); return; }
              await Prefs.setAdminPin(_pin.text);
              _pin.clear();
              if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Admin PIN changed')));
            }, child: const Text('Save PIN', style: TextStyle(color: Colors.white))),
          ]),
          const SizedBox(height: 24),
          Text('Trending Movies ($trendingCount / 5) - tap star to add / remove', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          ..._movies.map((m) => ListTile(
            leading: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(m.posterUrl, width: 40, height: 60, fit: BoxFit.cover, errorBuilder: (_, __, ___) => Container(width: 40, height: 60, color: kCard2))),
            title: Text(m.title), subtitle: Text('${m.categoriesText} • ${m.year}'),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              IconButton(icon: Icon(m.isTrending ? Icons.star : Icons.star_border, color: m.isTrending ? Colors.amber : kGrey), onPressed: () async {
                var ids = _movies.where((x) => x.isTrending).map((x) => x.id).toList();
                if (m.isTrending) { ids.remove(m.id); } else {
                  if (ids.length >= 5) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Trending is full - remove one first (max 5)'))); return; }
                  ids.add(m.id);
                }
                await MovieRepo.setTrending(ids); _load();
              }),
              IconButton(icon: const Icon(Icons.delete_outline, color: Colors.red), onPressed: () async { await MovieRepo.deleteMovie(m.id); _load(); }),
            ]),
          )),
        ]),
      ),
    );
  }
}
