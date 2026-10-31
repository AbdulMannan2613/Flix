// FLIX - Stream Unlimited Movies & TV Shows
// Flutter + Firebase (Firestore) + local fallback
// If Firebase is NOT connected yet, the app still runs with sample movies
// and admin-added movies saved locally. Connect Firebase later (see README).
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

const Color kBg = Color(0xFF0B1220);
const Color kCard = Color(0xFF1A2436);
const Color kCard2 = Color(0xFF232F45);
const Color kRed = Color(0xFFE11D2E);
const Color kBlue = Color(0xFF4A90E2);
const Color kGrey = Color(0xFF8A94A6);

// Build tag for in-app updates. The GitHub workflow replaces 'dev' with
// the real build tag (for example 'build-12') before building the APK,
// so the app knows exactly which build it is. Do not change this by hand
// in the repo - the workflow fills it in.
const String kBuildTag = 'dev';
const String kRepo = 'AbdulMannan2613/Flix';

/// Latest Flix release from GitHub. Returns tag + direct APK download URL.
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
      return null; // Offline or no release yet - stay silent, do not block the app.
    }
  }

  /// Call once on Home. If a newer release exists, show a dialog that
  /// takes the user straight to the new APK download link.
  static Future<void> checkAndPrompt(BuildContext context) async {
    if (kBuildTag == 'dev') return; // Build tag was not injected - cannot tell old from new.
    final latest = await fetchLatest();
    if (latest == null || latest.tag == kBuildTag) return;
    final p = await SharedPreferences.getInstance();
    if (p.getString('dismissed_update_tag') == latest.tag) return;
    if (!context.mounted) return;
    final go = await showDialog<bool>(context: context, builder: (_) => AlertDialog(
      title: const Text('New version available'),
      content: const Text('A new version of Flix is available with the latest changes.\n\nTap Download to get the new APK. The file will always be called app-release.apk - that is the new version, even if the name looks the same as the old file.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Later')),
        ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white), onPressed: () => Navigator.pop(context, true), child: const Text('Download', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
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

// ---------------- TMDB (automatic list, NO Nexstream) ----------------
// TMDB gives movie/TV metadata only: title, poster, rating, overview,
// trending and popular lists. It does NOT give full-movie video files,
// and no Nexstream / third-party streaming API is used here, so TMDB
// movies have no videoUrl. Their Watch Now button shows a clear message
// instead of opening the player. To turn TMDB on, replace the placeholder
// below with your free API key from themoviedb.org > Settings > API
// (API Key v3), or send the key in chat and it will be put here for you.
// Until a real key is put here, the app keeps working exactly as before
// with Firestore / local / sample movies.
const String kTmdbApiKey = '8c6fe697df81d39205f246a5b41ed3e4';
bool get kUseTmdb => kTmdbApiKey.isNotEmpty && kTmdbApiKey != 'YOUR_TMDB_API_KEY';

class Tmdb {
  static const _genres = {
    28: 'Action', 12: 'Adventure', 16: 'Animation', 35: 'Comedy',
    80: 'Crime', 99: 'Documentary', 18: 'Drama', 10751: 'Family',
    14: 'Fantasy', 36: 'History', 27: 'Horror', 10402: 'Music',
    9648: 'Mystery', 10749: 'Romance', 878: 'Science Fiction',
    10770: 'TV Movie', 53: 'Thriller', 10752: 'War', 37: 'Western',
  };

  // hindiDubbed=true forces the badge to HI. TMDB's list endpoints
  // do not say whether a movie has Hindi DUB AUDIO, only whether a
  // Hindi translation (title/overview) exists - that is the only
  // signal available here, so a movie with a Hindi translation in
  // TMDB is treated as Hindi-dubbed for the badge. If there is no
  // Hindi translation, the original language is kept.
  static Movie _fromJson(Map<String, dynamic> j, bool trending, {bool hindiDubbed = false}) {
    final poster = (j['poster_path'] ?? '').toString();
    final backdrop = (j['backdrop_path'] ?? '').toString();
    final ids = (j['genre_ids'] as List?) ?? [];
    final cat = ids.isNotEmpty ? (_genres[ids.first] ?? 'Movie') : 'Movie';
    final rel = (j['release_date'] ?? '').toString();
    final year = int.tryParse(rel.length >= 4 ? rel.substring(0, 4) : '') ?? 2025;
    final lang = (j['original_language'] ?? '').toString().toUpperCase();
    return Movie(
      id: 'tmdb_${j['id']}',
      title: (j['title'] ?? j['name'] ?? 'Untitled').toString(),
      description: (j['overview'] ?? '').toString(),
      category: cat,
      language: hindiDubbed ? 'HI' : (lang.isEmpty ? 'EN' : lang),
      posterUrl: poster.isEmpty ? '' : 'https://image.tmdb.org/t/p/w500$poster',
      // Wide rectangle backdrop (w1280) for the Home slider and Details page.
      backdropUrl: backdrop.isEmpty ? '' : 'https://image.tmdb.org/t/p/w1280$backdrop',
      videoUrl: '', // TMDB has no full-movie file. No streaming API is used.
      type: 'Movie',
      year: year,
      rating: ((j['vote_average'] ?? 7.0) as num).toDouble(),
      isTrending: trending,
      categories: [cat],
    );
  }

  // FIX for "app does not run without VPN": the old code awaited
  // TMDB one request after another with NO timeout. If TMDB / the
  // network is slow or blocked on a connection, Home stayed on the
  // loading spinner and the app looked dead until a VPN changed the
  // route. Now every request has an 8s timeout, all lists are fetched
  // in parallel, and the whole fetch gives up after 10s - then the
  // caller falls back at once to Firestore / local / sample movies,
  // so the app always OPENS, with or without VPN. If TMDB itself is
  // blocked on that network, its list will simply be empty until the
  // network allows it - the app will not hang.
  static Dio _dio() => Dio(BaseOptions(
        connectTimeout: const Duration(seconds: 8),
        receiveTimeout: const Duration(seconds: 8),
      ));

  // A movie counts as Hindi-dubbed for the badge/grid when its
  // hi-IN version in TMDB has a DIFFERENT overview from the en-US
  // version (i.e. a Hindi translation actually exists in TMDB).
  // Without a Hindi translation TMDB falls back to the English
  // overview, so identical overviews mean no Hindi version is
  // known - the movie is then left out of the Hindi-only grid.
  static bool _hasHindiVersion(Map<String, dynamic> hi, Map<String, dynamic>? en) {
    final hiOv = (hi['overview'] ?? '').toString().trim();
    final hiTitle = (hi['title'] ?? '').toString().trim();
    final enTitle = (en?['title'] ?? '').toString().trim();
    // A Hindi title in TMDB (e.g. Devanagari transliteration) is itself
    // a Hindi translation, even when the hi-IN overview is empty -
    // many popular titles have an empty hi-IN overview but a Hindi title.
    if (en == null) return hiOv.isNotEmpty;
    if (hiTitle.isNotEmpty && enTitle.isNotEmpty && hiTitle != enTitle) return true;
    if (hiOv.isEmpty) return false;
    return hiOv != (en['overview'] ?? '').toString().trim();
  }

  // One TMDB list request, isolated: a single slow/failed request
  // returns [] instead of killing the whole Home fetch. (31 Oct fix:
  // the old Future.wait threw if ANY of the 5 requests failed, so
  // one slow Hindi-discover request wiped out the entire Hindi list
  // and Home fell back to the old saved global list.)
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

  /// Hindi-only Home grid (31 Oct: Dino - EN/KO movies must stop
  /// appearing, grid must be Hindi movies). Home shows this list in
  /// order, so the grid is: (1) Hindi originals, pages 1-6 (default)
  /// of discover/movie with_original_language=hi, badge HI; (2) global
  /// popular movies that have a Hindi version in TMDB, badge HI.
  /// Global EN/KO originals with NO Hindi version are NOT added at
  /// all, so no EN/KO badge appears in the grid. The slider uses the
  /// first 5 of this same Hindi list (Home falls back to take(5)
  /// when nothing is marked trending). Search is separate - it
  /// still finds non-Hindi movies, with their original badge.
  /// NOTE: TMDB has lakhs of titles, so ALL of them can never be
  /// loaded at once - the app loads page by page (20 per page).
  /// "Aur Movies Dikhao" on Home loads more Hindi pages (up to 10
  /// pages = ~200 Hindi titles + dubbed popular), and Search finds
  /// any TMDB title in the world, not only the grid titles.
  static Future<List<Movie>> fetchTrendingAndPopular({int hindiPages = 6}) async {
    if (!kUseTmdb) return [];
    try {
      final dio = _dio();
      // Each list is fetched separately, so one slow/failed request
      // only loses its own page, never the whole Hindi list.
      final lists = await Future.wait([
        for (var p = 1; p <= hindiPages; p++)
          _list(dio, 'https://api.themoviedb.org/3/discover/movie',
              {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'with_original_language': 'hi', 'sort_by': 'popularity.desc', 'page': p}),
        _list(dio, 'https://api.themoviedb.org/3/movie/popular',
            {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'page': 1}),
        _list(dio, 'https://api.themoviedb.org/3/movie/popular',
            {'api_key': kTmdbApiKey, 'language': 'en-US', 'page': 1}),
      ]).timeout(const Duration(seconds: 15));
      final popularHi = lists[hindiPages];
      final enById = <String, Map<String, dynamic>>{
        for (final m in lists[hindiPages + 1]) '${m['id']}': m,
      };
      final out = <Movie>[];
      final seen = <String>{};
      void addRaw(Map<String, dynamic> j, bool hindiDubbed) {
        final m = _fromJson(j, false, hindiDubbed: hindiDubbed);
        if (seen.add(m.id)) out.add(m);
      }
      // (1) Hindi originals - always HI.
      for (var i = 0; i < hindiPages; i++) {
        for (final j in lists[i]) {
          addRaw(j, false);
        }
      }
      // Fallback: if every hi-IN Hindi-discover page came back empty
      // (hi-IN translation layer slow/blocked), retry page 1 in en-US -
      // Hindi originals are still Hindi originals, badge HI.
      if (out.isEmpty) {
        final retry = await _list(dio, 'https://api.themoviedb.org/3/discover/movie',
            {'api_key': kTmdbApiKey, 'language': 'en-US', 'with_original_language': 'hi', 'sort_by': 'popularity.desc', 'page': 1});
        for (final j in retry) {
          addRaw(j, false);
        }
      }
      // (2) Global popular, only if a Hindi version exists - badge HI.
      for (final j in popularHi) {
        if ((j['original_language'] ?? '').toString() == 'hi') {
          addRaw(j, false);
        } else if (_hasHindiVersion(j, enById['${j['id']}'])) {
          addRaw(j, true);
        }
        // No Hindi version -> skipped entirely (no EN/KO in grid).
      }
      return out;
    } catch (_) {
      return []; // Offline / blocked / bad key - caller falls back.
    }
  }

  /// Live TMDB search: any movie in TMDB can be found, not only the
  /// titles pre-loaded on Home. Searched in Hindi and in
  /// English and merged, so a non-Hindi / English title the user
  /// types also appears in Search results.
  static Future<List<Movie>> searchMovies(String query) async {
    if (!kUseTmdb || query.trim().isEmpty) return [];
    try {
      final dio = _dio();
      final results = await Future.wait([
        dio.get('https://api.themoviedb.org/3/search/movie',
            queryParameters: {'api_key': kTmdbApiKey, 'language': 'hi-IN', 'query': query, 'page': 1, 'include_adult': false}),
        dio.get('https://api.themoviedb.org/3/search/movie',
            queryParameters: {'api_key': kTmdbApiKey, 'language': 'en-US', 'query': query, 'page': 1, 'include_adult': false}),
      ]).timeout(const Duration(seconds: 10));
      // Badge rule in Search too: Hindi version exists -> HI,
      // otherwise the movie's original language (EN/KO/...).
      final enById = <String, Map<String, dynamic>>{};
      for (final raw in ((results[1].data?['results'] as List?) ?? [])) {
        final m = Map<String, dynamic>.from(raw as Map);
        enById['${m['id']}'] = m;
      }
      final out = <Movie>[];
      final seen = <String>{};
      for (final raw in ((results[0].data?['results'] as List?) ?? [])) {
        final j = Map<String, dynamic>.from(raw as Map);
        final dubbed = (j['original_language'] ?? '').toString() != 'hi' &&
            _hasHindiVersion(j, enById['${j['id']}']);
        final m = _fromJson(j, false, hindiDubbed: dubbed);
        if (seen.add(m.id)) out.add(m);
      }
      for (final raw in ((results[1].data?['results'] as List?) ?? [])) {
        final j = Map<String, dynamic>.from(raw as Map);
        final m = _fromJson(j, false);
        if (seen.add(m.id)) out.add(m);
      }
      return out;
    } catch (_) {
      return [];
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    // Firebase config from Dino's google-services.json (project flix-9a157,
    // Android package com.dino.flix). Embedded here because the GitHub
    // workflow builds a fresh project and only copies main.dart/pubspec.yaml,
    // so a google-services.json file alone would not connect it.
    await Firebase.initializeApp(
      options: const FirebaseOptions(
        apiKey: 'AIzaSyC12Na1MoINhZrpJjDVZqfmfyYkz96y65c',
        appId: '1:468956683510:android:501395842c28668757e0d7',
        messagingSenderId: '468956683510',
        projectId: 'flix-9a157',
        storageBucket: 'flix-9a157.firebasestorage.app',
      ),
    );
  } catch (_) {
    // Firebase not connected yet - app runs on local sample data.
  }
  runApp(const FlixApp());
}

class FlixApp extends StatelessWidget {
  const FlixApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Flix',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: kBg,
        colorScheme: const ColorScheme.dark(primary: kRed, surface: kBg),
        appBarTheme: const AppBarTheme(backgroundColor: kBg, elevation: 0),
      ),
      home: const SplashScreen(),
    );
  }
}

// ---------------- MODEL ----------------
class Movie {
  final String id, title, description, category, language, posterUrl, videoUrl, type;
  // Wide rectangle (16:9) backdrop image, from TMDB backdrop_path.
  // Empty for local/sample movies - UI then falls back to posterUrl.
  final String backdropUrl;
  final int year;
  final double rating;
  final bool isTrending;
  final Map<String, String> qualities;
  // Episode video links for TV Show / Web Series. Empty = single video (Movie).
  final List<String> episodes;
  // All categories for this movie. A movie can be Romantic AND Thriller
  // at the same time. 'category' is kept as the first one for old data.
  final List<String> categories;
  Movie({
    required this.id, required this.title, required this.description,
    required this.category, required this.language, required this.posterUrl,
    required this.videoUrl, required this.type, required this.year,
    required this.rating, this.isTrending = false, this.qualities = const {},
    this.episodes = const [], this.categories = const [], this.backdropUrl = '',
  });
  // Rectangle image for slider / details: backdrop if there is one, else poster.
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

List<Movie> sampleMovies() {
  const v = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4';
  const v2 = 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerBlazes.mp4';
  String p(String s) => 'https://picsum.photos/seed/$s/400/600';
  return [
    Movie(id: 's1', title: 'The Last Horizon', description: 'A hero returns to save his city from a forgotten enemy. Epic action, big battles and a fight for the future.', category: 'Action', language: 'Hindi', posterUrl: p('flix1'), videoUrl: v, type: 'Movie', year: 2025, rating: 8.3, isTrending: true),
    Movie(id: 's2', title: 'City of Shadows', description: 'A detective follows a trail through the dark streets of the city.', category: 'Thriller', language: 'Tamil', posterUrl: p('flix2'), videoUrl: v2, type: 'Movie', year: 2026, rating: 8.8, isTrending: true),
    Movie(id: 's3', title: 'Love in Paris', description: 'Two strangers meet in Paris and change each other\'s lives forever.', category: 'Romance', language: 'English', posterUrl: p('flix3'), videoUrl: v, type: 'Movie', year: 2024, rating: 7.9, isTrending: true),
    Movie(id: 's4', title: 'Jungle Quest', description: 'An adventure deep into a jungle no one has returned from.', category: 'Adventure', language: 'Telugu', posterUrl: p('flix4'), videoUrl: v2, type: 'Movie', year: 2025, rating: 8.1, isTrending: true),
    Movie(id: 's5', title: 'Night Haunting', description: 'A family moves into an old house and discovers its secret.', category: 'Horror', language: 'Malayalam', posterUrl: p('flix5'), videoUrl: v, type: 'Movie', year: 2023, rating: 7.4, isTrending: true),
    Movie(id: 's6', title: 'Family Reunion', description: 'A warm family drama about coming home after many years.', category: 'Family', language: 'Hindi', posterUrl: p('flix6'), videoUrl: v2, type: 'Movie', year: 2024, rating: 8.0),
    Movie(id: 's7', title: 'Space Voyage', description: 'A crew travels beyond the stars to find a new home.', category: 'Action', language: 'English', posterUrl: p('flix7'), videoUrl: v, type: 'TV Show', year: 2026, rating: 9.1),
    Movie(id: 's8', title: 'Comedy Nights', description: 'Non-stop comedy from a group of friends who always get into trouble.', category: 'Comedy', language: 'Hindi', posterUrl: p('flix8'), videoUrl: v2, type: 'TV Show', year: 2025, rating: 7.7),
    Movie(id: 's9', title: 'River Valley', description: 'A web series about a small town, a big secret, and the people caught in between.', category: 'Drama', language: 'Hindi', posterUrl: p('flix9'), videoUrl: v, type: 'Web Series', year: 2026, rating: 8.4, isTrending: true, episodes: [v, v2, 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerEscapes.mp4', 'https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/ForBiggerJoyrides.mp4']),
  ];
}

// ---------------- REPOSITORY + LOCAL STORAGE ----------------
class MovieRepo {
  static Future<List<Movie>> getAll({int hindiPages = 6}) async {
    final local = await _localMovies();
    List<Movie> base;
    // Try Firestore first - if it has movies, use them + local admin movies
    try {
      if (Firebase.apps.isNotEmpty) {
        // 8s timeout: Firestore must not hang Home on a slow/blocked network either.
        final snap = await FirebaseFirestore.instance.collection('movies').get().timeout(const Duration(seconds: 8));
        if (snap.docs.isNotEmpty) {
          final fire = snap.docs.map((d) => Movie.fromMap(d.id, d.data())).toList();
          final ids = fire.map((m) => m.id).toSet();
          base = [...fire, ...local.where((m) => !ids.contains(m.id))];
        } else {
          base = local.isEmpty ? sampleMovies() : local;
        }
      } else {
        base = local.isEmpty ? sampleMovies() : local;
      }
    } catch (_) {
      base = local.isEmpty ? sampleMovies() : local;
    }
    // Drop the STALE saved TMDB snapshot: Admin's Trending manager
    // saves the whole getAll() list into local storage, so the old
    // global EN/KO TMDB list (Street Fighter, Avengers, Hope...) was
    // saved on the phone and kept coming back in the grid/silder
    // even after the Hindi-only fetch, whenever TMDB was slow.
    // Only saved TMDB movies already badged HI are kept; Admin /
    // Firestore movies (non-tmdb ids) are always kept.
    base = base
        .where((m) => !(m.id.startsWith('tmdb_') && m.language.toUpperCase() != 'HI'))
        .toList();
    // TMDB automatic list on top (no Nexstream, no manual upload needed
    // for these titles). Admin / Firestore movies are kept after them.
    // 12s overall cap: if TMDB is slow/blocked without VPN, Home still
    // opens at once with the base list instead of hanging.
    try {
      final tmdb = await Tmdb.fetchTrendingAndPopular(hindiPages: hindiPages).timeout(const Duration(seconds: 15));
      if (tmdb.isNotEmpty) {
        final ids = tmdb.map((m) => m.id).toSet();
        return [...tmdb, ...base.where((m) => !ids.contains(m.id))];
      }
    } catch (_) {}
    // If the stale-snapshot filter emptied the base list and TMDB
    // gave nothing, show the sample list - never an empty Home.
    return base.isEmpty ? sampleMovies() : base;
  }

  static Future<List<Movie>> _localMovies() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString('admin_movies');
    if (raw == null) return sampleMovies();
    try {
      final list = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
      return list.map((m) => Movie.fromMap(m['id'] ?? '', m)).toList();
    } catch (_) { return sampleMovies(); }
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
    // Avoid duplicating sample movies on first admin save
    final base = all.where((x) => !x.id.startsWith('s')).toList();
    await saveLocal([...sampleMovies(), ...base, m]);
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
  // Admin PIN: default 1234. The admin can change it inside the Admin panel.
  static Future<String> adminPin() async {
    final p = await SharedPreferences.getInstance();
    return p.getString('admin_pin') ?? '1234';
  }
  static Future<void> setAdminPin(String pin) async {
    final p = await SharedPreferences.getInstance();
    await p.setString('admin_pin', pin);
  }
  // App download link shown in the share message. Flix is not on the Play
  // Store, so the admin sets the real download page / file link here
  // (for example a website download page). No fake link is invented.
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
  static Future<int> invitedCount() async {
    final p = await SharedPreferences.getInstance();
    return p.getInt('invited_count') ?? 0;
  }
  static Future<void> addInvite() async {
    final p = await SharedPreferences.getInstance();
    await p.setInt('invited_count', await invitedCount() + 1);
  }
  // Ad-free days: 1 invite=3, 3 invites=+5, 5=+10, 7=+15, 10=+3650
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

// ---------------- SHARED WIDGETS ----------------
// ONE rectangle fit image, used in BOTH the Home slider and the
// Details page, so tapping a movie shows the SAME image in Details
// as in the slider. It always fills the rectangle: the same image
// is drawn behind with BoxFit.cover (fills every corner, no black
// bars), and on top of it the WHOLE image is drawn with
// BoxFit.contain (nothing cut off). For a wide backdrop the two
// layers match exactly; for a tall poster with no backdrop, the
// whole poster shows in the middle and the cover layer fills the
// sides, instead of black side bars (Avengers: Doomsday, 31 Oct).
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
    // FIX: Home passed width: double.infinity, so the old code did
    // height = infinity * 1.45, which broke the Popular grid - posters
    // and titles were pushed out / not shown, only the EN/ES badge
    // (positioned at the top of the stack) was visible. Now the real
    // grid cell width is used, so height is always finite.
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

// ---------------- SPLASH (RED, like 1st image) ----------------
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

// ---------------- MAIN SHELL: ONLY 3 PAGES ----------------
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
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.home), label: 'Home'),
          BottomNavigationBarItem(icon: Icon(Icons.folder), label: 'Categories'),
          BottomNavigationBarItem(icon: Icon(Icons.person), label: 'Me'),
        ],
      ),
    );
  }
}

// ---------------- HOME ----------------
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

  // "Aur Movies Dikhao": load 4 more Hindi pages (up to 10 pages).
  Future<void> _loadMore() async {
    if (_loadingMore || _hindiPages >= 10) return;
    setState(() {
      _loadingMore = true;
      _hindiPages += 4;
      _future = MovieRepo.getAll(hindiPages: _hindiPages);
    });
    try {
      await _future;
    } catch (_) {}
    if (mounted) setState(() => _loadingMore = false);
  }

  @override
  void initState() {
    super.initState();
    _future = MovieRepo.getAll(hindiPages: _hindiPages);
    // Check for a new version once, shortly after Home opens.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      Future.delayed(const Duration(seconds: 2), () {
        if (mounted) UpdateChecker.checkAndPrompt(context);
      });
    });
    _timer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (!_page.hasClients) return;
      // Auto-slide trending, loop back at the end. User can also swipe manually.
      _future.then((movies) {
        final t = movies.where((m) => m.isTrending).toList();
        final list = t.isEmpty ? movies : t;
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
          final trending = movies.where((m) => m.isTrending).toList();
          final slider = trending.isEmpty ? movies.take(5).toList() : trending.take(5).toList();
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
                        child: const Row(children: [Icon(Icons.search, color: kGrey), SizedBox(width: 8), Text('Search movies, TV shows...', style: TextStyle(color: kGrey))]),
                      ),
                    ),
                  ),
                  IconButton(icon: const Icon(Icons.history), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()))),
                  IconButton(icon: const Icon(Icons.download), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()))),
                ]),
              ),
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Trending Movies', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
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
                          // Slider: SAME rectangle fit image as Details
                          // (FitRectangleImage, backdrop if any, else
                          // poster) - whole image, no cutting.
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
              const Padding(padding: EdgeInsets.symmetric(horizontal: 16), child: Text('Popular Movies', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
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
                      child: Text(_loadingMore ? 'Loading...' : 'Aur Movies Dikhao', style: const TextStyle(fontWeight: FontWeight.bold)),
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

// ---------------- CATEGORIES (exact filters from screenshot) ----------------
class CategoriesScreen extends StatefulWidget {
  const CategoriesScreen({super.key});
  @override
  State<CategoriesScreen> createState() => _CategoriesScreenState();
}
class _CategoriesScreenState extends State<CategoriesScreen> {
  String _type = 'Movies';
  // Multi-select genres: user can pick more than one (e.g. Action + Romance).
  // Empty set = All genres.
  final Set<String> _genresSelected = {};
  String _year = 'All';
  String _sort = 'Popularity';
  final _genres = ['Adventure', 'Romance', 'Horror', 'Family', 'Action', 'Thriller', 'Comedy', 'Drama'];
  final _years = ['All', '2026', '2025', '2024', '2023', '2022'];
  final _sorts = ['Popularity', 'Latest', 'Top today'];

  Widget _chips(List<String> items, String selected, ValueChanged<String> onPick) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(children: items.map((e) => Padding(
        padding: const EdgeInsets.only(right: 10),
        child: ChoiceChip(
          label: Text(e), selected: selected == e,
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
            label: const Text('All'), selected: _genresSelected.isEmpty,
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
            const Expanded(child: Center(child: Text('Categories', style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold)))),
            IconButton(icon: const Icon(Icons.search), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const SearchScreen()))),
          ]),
        ),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Column(children: [
            Row(children: [
              ChoiceChip(label: const Text('Movies'), selected: _type == 'Movies', selectedColor: kCard2, onSelected: (_) => setState(() => _type = 'Movies')),
              const SizedBox(width: 10),
              ChoiceChip(label: const Text('TV Shows'), selected: _type == 'TV Shows', selectedColor: kCard2, onSelected: (_) => setState(() => _type = 'TV Shows')),
              const SizedBox(width: 10),
              ChoiceChip(label: const Text('Web Series'), selected: _type == 'Web Series', selectedColor: kCard2, onSelected: (_) => setState(() => _type = 'Web Series')),
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
              else list.sort((a, b) => b.rating.compareTo(a.rating)); // Popularity + Top today
              if (list.isEmpty) return const Center(child: Text('No movies in this category yet.\nAdd one from the Admin panel.', textAlign: TextAlign.center, style: TextStyle(color: kGrey)));
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

// ---------------- SEARCH ----------------
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
  // Live TMDB search on every query change (debounced by sequence:
  // only the latest query's results are kept). Local results are
  // shown at once; TMDB results are merged in when they arrive, so
  // a movie that is not in Hindi / not pre-loaded on Home still
  // appears in Search.
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
          decoration: const InputDecoration(hintText: 'Title / Actor / Director', border: InputBorder.none, hintStyle: TextStyle(color: kGrey)),
          onChanged: (v) { setState(() => _q = v); _searchTmdb(v); },
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel', style: TextStyle(color: Colors.white)))],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (_q.isEmpty) ...[
            Row(children: [
              const Expanded(child: Text('Search History', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold))),
              IconButton(icon: const Icon(Icons.delete_outline, color: kGrey), onPressed: () async { await Prefs.clearSearch(); _load(); }),
            ]),
            const SizedBox(height: 8),
            if (_history.isEmpty)
              const Text('Nothing searched yet', style: TextStyle(color: kGrey))
            else
              Wrap(spacing: 8, runSpacing: 8, children: _history.map((h) => InputChip(
                label: Text(h), backgroundColor: kCard2,
                deleteIcon: const Icon(Icons.close, size: 16),
                onDeleted: () async { await Prefs.removeSearch(h); _load(); },
                onPressed: () { _ctrl.text = h; setState(() => _q = h); _searchTmdb(h); },
              )).toList()),
            const SizedBox(height: 24),
            const Text('Popular Searches', style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
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
              Text('No exact match for "$_q"', style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
              const SizedBox(height: 6),
              const Text('Related movies you may like:', style: TextStyle(color: kGrey)),
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('No video file for this TMDB listing. TMDB gives details and posters only, not a full movie file.')));
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
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Downloaded. Find it in Me > My download.')));
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Download failed: $e')));
    }
  }
  @override
  Widget build(BuildContext context) {
    final m = widget.movie;
    return Scaffold(
      appBar: AppBar(title: Text(m.title)),
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          // Details page ONLY: new rectangle FIT image. BoxFit.contain
          // shows the WHOLE image with no cutting (no cropped head /
          // top, as in the 31 Oct screenshot) - black bars fill any
          // leftover space in the 16:9 rectangle. Backdrop is used
          // when available, otherwise the poster, both fitted whole.
          // Details: SAME rectangle fit image as the slider
          // (FitRectangleImage) - whether the tap came from the
          // slider or from the Popular grid, the same image shows.
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
                  onPressed: () async {
                    if (m.videoUrl.isEmpty && m.episodes.isEmpty) {
                      if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This is a TMDB listing: details and poster only. No full-movie video file is available for it in Flix.')));
                      return;
                    }
                    final hist = await getWatchHistory();
                    final entry = hist.where((e) => e.movieId == m.id).toList();
                    final start = entry.isEmpty ? 0 : entry.first.position;
                    if (!context.mounted) return;
                    Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(movie: m, startAt: start)));
                  },
                  icon: const Icon(Icons.play_arrow, color: Colors.white), label: const Text('Watch Now', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.white)),
                ),
              ),
              const SizedBox(height: 10),
              Row(children: [
                Expanded(child: OutlinedButton.icon(onPressed: _toggleFav, icon: Icon(_fav ? Icons.favorite : Icons.favorite_border, color: kRed), label: Text(_fav ? 'Saved' : 'Favorite'))),
        const SizedBox(width: 10),
                Expanded(child: OutlinedButton.icon(onPressed: _download, icon: const Icon(Icons.download), label: const Text('Download'))),
              ]),
              const SizedBox(height: 20),
              const Text('Description', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
              const SizedBox(height: 8),
              Text(m.description, style: const TextStyle(color: Colors.white70, height: 1.5)),
              if (m.type == 'TV Show' || m.type == 'Web Series') ...[
                const SizedBox(height: 20),
                Text('Episodes (${m.episodes.isNotEmpty ? m.episodes.length : 3})', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text('${m.episodes.isNotEmpty ? m.episodes.length : 3} episodes in this ${m.type.toLowerCase()}', style: const TextStyle(color: kGrey)),
                ...List.generate(m.episodes.isNotEmpty ? m.episodes.length : 3, (i) => ListTile(
                  leading: const Icon(Icons.play_circle_fill, color: kRed),
                  title: Text('Episode ${i + 1}'),
                  subtitle: Text(m.type),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(movie: m, startAt: 0, episodeIndex: i))),
                )),
              ],
            ]),
          ),
        ]),
      ),
    );
  }
}

// ---------------- PLAYER: FULLSCREEN, CENTRE PLAY/PAUSE, DOUBLE-TAP +-10s, QUALITY ----------------
// No -10 / +10 buttons on screen. Double-tap left side = back 10s,
// double-tap right side = forward 10s. Centre button = play / pause only.
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
      // When an episode ends, auto-play the next episode if there is one.
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
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Playing Episode ${index + 1}'), duration: const Duration(seconds: 2)));
  }
  void _playNext({bool auto = false}) {
    if (_episodeIndex + 1 < _episodeUrls.length) {
      _playEpisode(_episodeIndex + 1);
    } else if (!auto && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This is the last episode')));
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
          // Double-tap left half = back 10s, right half = forward 10s.
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
              Expanded(child: Text(_isSeries ? '${widget.movie.title} • Episode ${_episodeIndex + 1}' : widget.movie.title, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold), overflow: TextOverflow.ellipsis)),
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
                  Text('Episode ${_episodeIndex + 1} of ${_episodeUrls.length}', style: const TextStyle(color: Colors.white70)),
                  if (_episodeIndex + 1 < _episodeUrls.length) ...[
                    const SizedBox(width: 12),
                    TextButton.icon(onPressed: () => _playNext(), icon: const Icon(Icons.skip_next, color: Colors.white, size: 18), label: const Text('Next Episode', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
                  ],
                ]),
            ])),
          ],
        ]),
      ),
    );
  }
}

// ---------------- ME (avatar = admin unlock, NO adult / game / network test) ----------------
class MeScreen extends StatefulWidget {
  const MeScreen({super.key});
  @override
  State<MeScreen> createState() => _MeScreenState();
}
class _MeScreenState extends State<MeScreen> {
  String _username = '...';
  int _taps = 0;
  @override
  void initState() { super.initState(); Prefs.username().then((u) { if (mounted) setState(() => _username = u); }); }
  void _onAvatarTap() async {
    _taps++;
    if (_taps >= 5) {
      _taps = 0;
      // Admin panel is PIN-protected. Default PIN is 1234 (change it in Admin).
      final pinCtrl = TextEditingController();
      final entered = await showDialog<String>(context: context, builder: (_) => AlertDialog(
        title: const Text('Admin PIN'),
        content: TextField(controller: pinCtrl, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(hintText: 'Enter admin PIN')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(context, pinCtrl.text), child: const Text('Unlock')),
        ],
      ));
      if (entered == null) return;
      final correct = await Prefs.adminPin();
      if (!mounted) return;
      if (entered == correct) {
        Navigator.push(context, MaterialPageRoute(builder: (_) => const AdminScreen()));
      } else {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Wrong PIN')));
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
          // Default avatar - cannot be changed. Tap it 5 times to open Admin.
          GestureDetector(
            onTap: _onAvatarTap,
            child: const CircleAvatar(radius: 40, backgroundColor: kCard2, child: Icon(Icons.person, size: 44, color: kGrey)),
          ),
          const SizedBox(height: 8),
          Text(_username, style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const Text('Movie', style: TextStyle(color: kGrey)),
          const SizedBox(height: 16),
          // VIP banner
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFE8C88A), Color(0xFFD9A86A)]), borderRadius: BorderRadius.circular(12)),
              child: Row(children: [
                const Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('Join VIP and enjoy ad-free viewing of all videos', style: TextStyle(color: Colors.black, fontWeight: FontWeight.bold)),
                  Text('40%+ discount currently!', style: TextStyle(color: Colors.black54)),
                ])),
                ElevatedButton(style: ElevatedButton.styleFrom(backgroundColor: Colors.white), onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const VipScreen())), child: const Text('Subscribe', style: TextStyle(color: Colors.black))),
              ]),
            ),
          ),
          const SizedBox(height: 16),
          _tile(Icons.share, 'Share', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const ShareScreen()))),
          _tile(Icons.language, 'Language Switching', () async {
            final lang = await showDialog<String>(context: context, builder: (_) => SimpleDialog(title: const Text('Choose language'), children: ['English', 'Hindi', 'Tamil', 'Telugu', 'Malayalam'].map((l) => SimpleDialogOption(child: Text(l), onPressed: () => Navigator.pop(context, l))).toList()));
            if (lang != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Language set to $lang')));
          }),
          _tile(Icons.history, 'History', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const HistoryScreen()))),
          _tile(Icons.download, 'My download', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const DownloadsScreen()))),
          _tile(Icons.favorite_border, 'My Favorites', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const FavoritesScreen()))),
          _tile(Icons.receipt_long, 'Order list', () => Navigator.push(context, MaterialPageRoute(builder: (_) => const OrderListScreen()))),
          _tile(Icons.feedback_outlined, 'Feedback', () {
            showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Feedback'), content: const TextField(decoration: InputDecoration(hintText: 'Tell us what to improve...')), actions: [TextButton(onPressed: () => Navigator.pop(context), child: const Text('Send'))]));
          }),
          _tile(Icons.support_agent, 'Official customer service', () {
            showDialog(context: context, builder: (_) => const AlertDialog(title: Text('Customer Service'), content: Text('Email us from the address you used for Flix. Support replies within 1-2 working days.')));
          }),
        ]),
      ),
    );
  }
}

// ---------------- HISTORY / CONTINUE WATCHING ----------------
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
      appBar: AppBar(title: const Text('History'), actions: [IconButton(icon: const Icon(Icons.edit), onPressed: () async { final p = await SharedPreferences.getInstance(); await p.remove('watch_history'); _load(); })]),
      body: _entries.isEmpty
          ? const Center(child: Text('No watch history yet.\nPlay a movie and it will appear here.', textAlign: TextAlign.center, style: TextStyle(color: kGrey)))
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
                  subtitle: Text('Remaining ${fmtTime(remaining)}', style: const TextStyle(color: Colors.red)),
                  trailing: IconButton(icon: const Icon(Icons.delete_outline, color: kGrey), onPressed: () async { await removeWatch(e.movieId); _load(); }),
                  onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => PlayerScreen(movie: movie, startAt: e.position))),
                );
              },
            ),
    );
  }
}

// ---------------- DOWNLOADS ----------------
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
        appBar: AppBar(title: const Text('My download'), actions: [TextButton(onPressed: () {}, child: const Text('Edit', style: TextStyle(color: Colors.white)) )], bottom: const TabBar(tabs: [Tab(text: 'Downloading'), Tab(text: 'Downloaded')])),
        body: TabBarView(children: [
          const Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Icon(Icons.movie, size: 64, color: kGrey), SizedBox(height: 12), Text('No Content yet', style: TextStyle(color: kGrey))])),
          downloadedMovies.isEmpty
              ? const Center(child: Text('No downloaded movies yet.\nTap Download on a movie details page.', textAlign: TextAlign.center, style: TextStyle(color: kGrey)))
              : ListView.builder(itemCount: downloadedMovies.length, itemBuilder: (context, i) {
                  final m = downloadedMovies[i];
                  return ListTile(
                    leading: ClipRRect(borderRadius: BorderRadius.circular(6), child: Image.network(m.posterUrl, width: 60, height: 85, fit: BoxFit.cover)),
                    title: Text(m.title), subtitle: const Text('Downloaded • Tap to play offline'),
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
      appBar: AppBar(title: const Text('My Favorites')),
      body: FutureBuilder<List<Movie>>(
        future: MovieRepo.getAll(),
        builder: (context, snap) {
          if (!snap.hasData) return const Center(child: CircularProgressIndicator(color: kRed));
          return FutureBuilder<List<String>>(
            future: SharedPreferences.getInstance().then((p) => p.getStringList('favorites') ?? []),
            builder: (context, favSnap) {
              final favs = snap.data!.where((m) => (favSnap.data ?? []).contains(m.id)).toList();
              if (favs.isEmpty) return const Center(child: Text('No favorites yet.', style: TextStyle(color: kGrey)));
              return GridView.builder(padding: const EdgeInsets.all(12), gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 3, childAspectRatio: 0.62, crossAxisSpacing: 8, mainAxisSpacing: 12), itemCount: favs.length, itemBuilder: (context, i) => MovieCard(movie: favs[i], width: double.infinity));
            },
          );
  },
      ),
    );
  }
}

// ---------------- ORDER LIST: purchased plan only, no buy screen ----------------
class OrderListScreen extends StatelessWidget {
  const OrderListScreen({super.key});
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Order list')),
      body: FutureBuilder<String?>(
        future: Prefs.vipPlan(),
        builder: (context, snap) {
          if (!snap.hasData && snap.connectionState == ConnectionState.waiting) {
            return const Center(child: CircularProgressIndicator(color: kRed));
          }
          final plan = snap.data;
          if (plan == null || plan.isEmpty) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(24),
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Icon(Icons.receipt_long, size: 64, color: kGrey),
                  SizedBox(height: 16),
                  Text('Not purchased VIP plan yet', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  SizedBox(height: 8),
                  Text('You have not purchased a VIP plan yet.', style: TextStyle(color: kGrey), textAlign: TextAlign.center),
                ]),
              ),
            );
          }
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
                    Text('Purchased plan: $plan', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                    const Text('Status: Purchased', style: TextStyle(color: Colors.green)),
                  ])),
                ]),
              ),
            ]),
          );
        },
      ),
    );
  }
}

// ---------------- VIP ----------------
class VipScreen extends StatefulWidget {
  const VipScreen({super.key});
  @override
  State<VipScreen> createState() => _VipScreenState();
}
class _VipScreenState extends State<VipScreen> {
  int _selected = 2; // 6 Months default, like screenshot
  final _plans = [
    ('1 Month', 110, 200), ('3 Months', 300, 600),
    ('6 Months', 520, 1200), ('12 Months', 920, 2400),
  ];
  @override
  Widget build(BuildContext context) {
    final plan = _plans[_selected];
    return Scaffold(
      appBar: AppBar(title: const Text('Payment')),
      body: Column(children: [
        Expanded(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(children: [
              Container(
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(gradient: const LinearGradient(colors: [Color(0xFFE8C88A), Color(0xFFD9A86A)]), borderRadius: BorderRadius.circular(16)),
                child: const Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Center(child: Text('VIP benefits', style: TextStyle(color: Colors.brown, fontSize: 20, fontWeight: FontWeight.bold))),
                  SizedBox(height: 16),
                  Text('✓  Exempt video ads on the home page, play, download and pause.', style: TextStyle(color: Colors.brown)),
                  SizedBox(height: 8),
                  Text('✓  Unlimited download opportunities', style: TextStyle(color: Colors.brown)),
                  SizedBox(height: 8),
                  Text('✓  More than 5 million HD movie resources', style: TextStyle(color: Colors.brown)),
                ]),
              ),
              const SizedBox(height: 16),
              GridView.builder(
                shrinkWrap: true, physics: const NeverScrollableScrollPhysics(),
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
                        Text('₹ ${p.$2}.00', style: TextStyle(color: Colors.orange.shade700, fontSize: 20, fontWeight: FontWeight.bold)),
                        Text('₹${p.$3}.00', style: TextStyle(color: sel ? Colors.grey : Colors.white54, decoration: TextDecoration.lineThrough)),
                      ]),
                    ),
                  );
                },
              ),
            ]),
          ),
        ),
        Container(
          color: Colors.white,
          child: Row(children: [
            Expanded(child: Padding(padding: const EdgeInsets.all(16), child: Text('₹ ${plan.$2}.00   ${plan.$1}', style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 18)))),
            GestureDetector(
              onTap: () async {
                final p = await SharedPreferences.getInstance();
                await p.setString('vip_plan', plan.$1);
                if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${plan.$1} VIP selected (demo - connect a real payment gateway for live payments)')));
              },
              child: Container(color: Colors.orange, padding: const EdgeInsets.symmetric(horizontal: 48, vertical: 20), child: const Text('Next', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            ),
          ]),
        ),
      ]),
    );
  }
}

// ---------------- SHARE / PROMOTION ----------------
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
      appBar: AppBar(title: const Text('Promotion'), actions: [TextButton(onPressed: () {}, child: const Text('Promotion record', style: TextStyle(color: Colors.white)))]),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(color: kCard2, borderRadius: BorderRadius.circular(16)),
            child: Column(children: [
              Text('Promoted $_invited person', style: const TextStyle(fontSize: 18)),
              Text('You have $days days ad-free', style: const TextStyle(color: kGrey)),
              const SizedBox(height: 16),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
                child: Column(children: [
                  // Real QR code encoding the invitation code (not a fake icon).
                  QrImageView(
                    data: _username.isEmpty ? 'FLIX' : _username.toUpperCase(),
                    version: QrVersions.auto,
                    size: 180,
                    backgroundColor: Colors.white,
                    eyeStyle: const QrEyeStyle(eyeShape: QrEyeShape.square, color: Colors.black),
                    dataModuleStyle: const QrDataModuleStyle(dataModuleShape: QrDataModuleShape.square, color: Colors.black),
                  ),
                  const SizedBox(height: 8),
                  Text('My invitation code: ${_username.toUpperCase()}', style: const TextStyle(color: Colors.grey)),
                ]),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(backgroundColor: kRed, foregroundColor: Colors.white, padding: const EdgeInsets.symmetric(vertical: 14)),
                  onPressed: () async {
                    // Opens the phone's system share sheet, so the user
                    // picks the app: WhatsApp, Messenger, Telegram, etc.
                    // The download link is the direct APK link from the
                    // latest GitHub release, not a generic page.
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
                  child: const Text('Share now', style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white)),
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

// ---------------- ADMIN PANEL (hidden + PIN: tap Me avatar 5 times, then enter PIN) ----------------
// Default PIN is 1234. Change it inside the Admin panel. There is no Admin
// button in the bottom bar, so normal users never see this screen.
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
  // Multi-select categories: a movie can be Romantic AND Thriller, and more.
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
