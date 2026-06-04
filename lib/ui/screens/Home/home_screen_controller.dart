import 'package:audio_service/audio_service.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';

import '/models/media_Item_builder.dart';
import '/ui/player/player_controller.dart';
import '../../../utils/update_check_flag_file.dart';
import '../../../utils/helper.dart';
import '/models/album.dart';
import '/models/playlist.dart';
import '/models/quick_picks.dart';
import '/services/music_service.dart';
import '../Settings/settings_screen_controller.dart';
import '/ui/widgets/new_version_dialog.dart';

class HomeScreenController extends GetxController {
  final MusicServices _musicServices = Get.find<MusicServices>();
  final isContentFetched = false.obs;
  final tabIndex = 0.obs;
  final networkError = false.obs;
  final quickPicks = QuickPicks([]).obs;
  final recentlyPlayedQuickPicks = Rxn<QuickPicks>();
  final middleContent = [].obs;
  final fixedContent = [].obs;
  final showVersionDialog = true.obs;
  //isHomeScreenOnTop var only useful if bottom nav enabled
  final isHomeSreenOnTop = true.obs;
  final List<ScrollController> contentScrollControllers = [];
  bool reverseAnimationtransiton = false;

  @override
  onInit() {
    super.onInit();
    loadContent();
    if (updateCheckFlag) _checkNewVersion();
    
    try {
      Hive.box("LIBRP").watch().listen((event) {
        _loadRecentlyPlayedForHome();
        _applyNoveltyToQuickPicks();
      });
    } catch (e) {
      printERROR("Failed to listen to recently played changes: $e");
    }
  }

  Future<void> loadContent() async {
    final box = Hive.box("AppPrefs");
    final isCachedHomeScreenDataEnabled =
        box.get("cacheHomeScreenData") ?? true;
    if (isCachedHomeScreenDataEnabled) {
      try {
        final loaded = await loadContentFromDb();

        if (loaded) {
          final currTimeSecsDiff = DateTime.now().millisecondsSinceEpoch -
              (box.get("homeScreenDataTime") ??
                  DateTime.now().millisecondsSinceEpoch);
          if (currTimeSecsDiff / 1000 > 3600 * 8) {
            loadContentFromNetwork(silent: true);
          }
        } else {
          loadContentFromNetwork();
        }
      } catch (e) {
        printERROR("Failed to load content from DB: $e. Fetching fresh from network...");
        try {
          final homeScreenData = await Hive.openBox("homeScreenData");
          await homeScreenData.clear();
        } catch (_) {}
        loadContentFromNetwork();
      }
    } else {
      loadContentFromNetwork();
    }
  }

  String get greeting {
    final hour = DateTime.now().hour;
    if (hour < 12) return "goodMorning".tr;
    if (hour < 17) return "goodAfternoon".tr;
    return "goodEvening".tr;
  }

  void _loadRecentlyPlayedForHome() {
    try {
      final box = Hive.box("LIBRP");
      if (box.isEmpty) {
        recentlyPlayedQuickPicks.value = null;
        return;
      }
      final items = box.values
          .map((e) => MediaItemBuilder.fromJson(e as Map))
          .whereType<MediaItem>()
          .toList()
          .reversed
          .take(6)
          .toList();
      if (items.isEmpty) {
        recentlyPlayedQuickPicks.value = null;
      } else {
        recentlyPlayedQuickPicks.value =
            QuickPicks(items, title: "recentlyPlayed".tr);
      }
    } catch (_) {
      recentlyPlayedQuickPicks.value = null;
    }
  }

  String _mapSectionTitle(String original) {
    final lower = original.toLowerCase();
    if (lower.contains('quick') || lower.contains('picks')) return "discoverNewSongsForYou".tr;
    if (lower.contains('trending') || lower.contains('charts')) return "newReleases".tr;
    if (lower.contains('like') || lower.contains('related') || lower.contains('because')) return "madeForYou".tr;
    if (lower.contains('new') && lower.contains('release')) return "newReleases".tr;
    if (lower.contains('mix') || lower.contains('radio')) return "madeForYou".tr;
    return original;
  }

  Future<bool> loadContentFromDb() async {
    final homeScreenData = await Hive.openBox("homeScreenData");
    _loadRecentlyPlayedForHome();
    if (homeScreenData.keys.isNotEmpty) {
      final String quickPicksType = homeScreenData.get("quickPicksType");
      final List quickPicksData = homeScreenData.get("quickPicks");
      final List middleContentData = homeScreenData.get("middleContent") ?? [];
      final List fixedContentData = homeScreenData.get("fixedContent") ?? [];
      quickPicks.value = QuickPicks(
          quickPicksData.map((e) => MediaItemBuilder.fromJson(e)).toList(),
          title: quickPicksType);
      middleContent.value = middleContentData
          .map((e) => e["type"] == "Album Content"
              ? AlbumContent.fromJson(e)
              : PlaylistContent.fromJson(e))
          .toList();
      fixedContent.value = fixedContentData
          .map((e) => e["type"] == "Album Content"
              ? AlbumContent.fromJson(e)
              : PlaylistContent.fromJson(e))
          .toList();
      isContentFetched.value = true;
      printINFO("Loaded from offline db");
      return true;
    } else {
      return false;
    }
  }

  Future<void> loadContentFromNetwork({bool silent = false}) async {
    final box = Hive.box("AppPrefs");
    String contentType = box.get("discoverContentType") ?? "QP";

    networkError.value = false;
    _loadRecentlyPlayedForHome();
    try {
      List middleContentTemp = [];
      final homeContentListMap = await _musicServices.getHome(
          limit:
              Get.find<SettingsScreenController>().noOfHomeScreenContent.value);
      if (contentType == "TR") {
        final index = homeContentListMap
            .indexWhere((element) => element['title'] == "Trending");
        if (index != -1 && index != 0) {
          quickPicks.value = QuickPicks(
              List<MediaItem>.from(homeContentListMap[index]["contents"]),
              title: "discoverNewSongsForYou".tr);
        } else if (index == -1) {
          List charts = await _musicServices.getCharts(contentType);
          final index = charts.indexWhere((element) =>
              element['title'] ==
              (contentType == "TMV" ? "Top Music Videos" : "Trending"));
          if (index != -1) {
            quickPicks.value = QuickPicks(
                List<MediaItem>.from(charts[index]["contents"]),
                title: "discoverNewSongsForYou".tr);
            middleContentTemp.addAll(charts);
          }
        }
      } else if (contentType == "TMV") {
        final index = homeContentListMap
            .indexWhere((element) => element['title'] == "Top music videos");
        if (index != -1 && index != 0) {
          final con = homeContentListMap.removeAt(index);
          quickPicks.value = QuickPicks(List<MediaItem>.from(con["contents"]),
              title: "discoverNewSongsForYou".tr);
        } else if (index == -1) {
          List charts = await _musicServices.getCharts(contentType);
          final index = charts.indexWhere((element) =>
              element['title'] ==
              (contentType == "TMV" ? "Top Music Videos" : "Trending"));
          if (index != -1) {
            quickPicks.value = QuickPicks(
                List<MediaItem>.from(charts[index]["contents"]),
                title: "discoverNewSongsForYou".tr);
            middleContentTemp.addAll(charts);
          }
        }
      } else if (contentType == "BOLI") {
        try {
          final songId = box.get("recentSongId");
          if (songId != null) {
            final rel = (await _musicServices.getContentRelatedToSong(
                songId, getContentHlCode()));
            final con = rel.removeAt(0);
            quickPicks.value =
                QuickPicks(List<MediaItem>.from(con["contents"]),
                    title: "discoverNewSongsForYou".tr);
            middleContentTemp.addAll(rel);
          }
        } catch (e) {
          printERROR(
              "Seems Based on last interaction content currently not available!");
        }
      }

      if (quickPicks.value.songList.isEmpty) {
        final index = homeContentListMap
            .indexWhere((element) => element['title'] == "Quick picks");
        if (index != -1 && homeContentListMap[index]["contents"].isNotEmpty && homeContentListMap[index]["contents"][0] is MediaItem) {
          final con = homeContentListMap.removeAt(index);
          quickPicks.value = QuickPicks(List<MediaItem>.from(con["contents"]),
              title: "discoverNewSongsForYou".tr);
        } else {
          final mediaItemSectionIndex = homeContentListMap.indexWhere((element) =>
              element["contents"].isNotEmpty && element["contents"][0] is MediaItem);
          if (mediaItemSectionIndex != -1) {
            final con = homeContentListMap.removeAt(mediaItemSectionIndex);
            quickPicks.value = QuickPicks(List<MediaItem>.from(con["contents"]),
                title: "discoverNewSongsForYou".tr);
          } else {
            try {
              final charts = await _musicServices.getCharts("TR");
              final trIndex = charts.indexWhere((element) => element['title'] == "Trending");
              if (trIndex != -1 && charts[trIndex]["contents"].isNotEmpty) {
                quickPicks.value = QuickPicks(List<MediaItem>.from(charts[trIndex]["contents"]),
                    title: "discoverNewSongsForYou".tr);
              }
            } catch (e) {
              printERROR("Failed to load trending songs fallback: $e");
            }
          }
        }
      }

      _applyNoveltyToQuickPicks();

      middleContent.value = _setContentList(middleContentTemp);
      fixedContent.value = _setContentList(homeContentListMap);

      isContentFetched.value = true;

      // set home content last update time
      cachedHomeScreenData(updateAll: true);
      await Hive.box("AppPrefs")
          .put("homeScreenDataTime", DateTime.now().millisecondsSinceEpoch);
      // ignore: unused_catch_stack
    } on NetworkError catch (r, e) {
      printERROR("Home Content not loaded due to ${r.message}");
      await Future.delayed(const Duration(seconds: 1));
      networkError.value = !silent;
    } catch (e, stack) {
      printERROR("Home Content not loaded due to unexpected parsing error: $e");
      printERROR(stack);
      await Future.delayed(const Duration(seconds: 1));
      networkError.value = !silent;
    }
  }

  List _setContentList(
    List<dynamic> contents,
  ) {
    List contentTemp = [];
    for (var content in contents) {
      if((content["contents"]).isEmpty) continue;
      if ((content["contents"][0]).runtimeType == Playlist) {
        final tmp = PlaylistContent(
            playlistList: (content["contents"]).whereType<Playlist>().toList(),
            title: _mapSectionTitle(content["title"] ?? ""));
        if (tmp.playlistList.length >= 2) {
          contentTemp.add(tmp);
        }
      } else if ((content["contents"][0]).runtimeType == Album) {
        final tmp = AlbumContent(
            albumList: (content["contents"]).whereType<Album>().toList(),
            title: _mapSectionTitle(content["title"] ?? ""));
        if (tmp.albumList.length >= 2) {
          contentTemp.add(tmp);
        }
      }
    }
    return contentTemp;
  }

  Future<void> changeDiscoverContent(dynamic val, {String? songId}) async {
    QuickPicks? quickPicks_;
    if (val == 'QP') {
      final homeContentListMap = await _musicServices.getHome(limit: 3);
      quickPicks_ = QuickPicks(
          List<MediaItem>.from(homeContentListMap[0]["contents"]),
          title: "discoverNewSongsForYou".tr);
    } else if (val == "TMV" || val == 'TR') {
      try {
        final charts = await _musicServices.getCharts(val);
        final index = charts.indexWhere((element) =>
            element['title'] ==
            (val == "TMV" ? "Top Music Videos" : "Trending"));
        quickPicks_ = QuickPicks(
            List<MediaItem>.from(charts[index]["contents"]),
            title: "discoverNewSongsForYou".tr);
      } catch (e) {
        printERROR(
            "Seems ${val == "TMV" ? "Top music videos" : "Trending songs"} currently not available!");
      }
    } else {
      songId ??= Hive.box("AppPrefs").get("recentSongId");
      if (songId != null) {
        try {
          final value = await _musicServices.getContentRelatedToSong(
              songId, getContentHlCode());
          middleContent.value = _setContentList(value);
          if (value.isNotEmpty && value[0]["contents"].isNotEmpty && value[0]["contents"][0] is MediaItem) {
            quickPicks_ =
                QuickPicks(List<MediaItem>.from(value[0]["contents"]),
                    title: "discoverNewSongsForYou".tr);
            Hive.box("AppPrefs").put("recentSongId", songId);
          }
          // ignore: empty_catches
        } catch (e) {}
      }
    }
    if (quickPicks_ == null) return;

    quickPicks.value = quickPicks_;
    _applyNoveltyToQuickPicks();

    // set home content last update time
    cachedHomeScreenData(updateQuickPicksNMiddleContent: true);
    await Hive.box("AppPrefs")
        .put("homeScreenDataTime", DateTime.now().millisecondsSinceEpoch);
  }

  void _applyNoveltyToQuickPicks() {
    if (quickPicks.value.songList.isEmpty) return;
    final recentIds = _getRecentPlayedIds();
    final list = quickPicks.value.songList.toList();
    list.sort((a, b) {
      final aPlayedRecently = recentIds.contains(a.id);
      final bPlayedRecently = recentIds.contains(b.id);
      if (aPlayedRecently == bPlayedRecently) {
        return 0;
      }
      // Songs not played recently should come first
      return aPlayedRecently ? 1 : -1;
    });
    quickPicks.value = QuickPicks(list,
        title: quickPicks.value.title.isEmpty
            ? "discoverNewSongsForYou".tr
            : quickPicks.value.title);
  }

  Set<String> _getRecentPlayedIds() {
    try {
      final box = Hive.box("LIBRP");
      return box.values
          .map((e) =>
              (e is Map && e.containsKey('videoId')) ? e['videoId'] as String : null)
          .whereType<String>()
          .toSet();
    } catch (_) {
      return {};
    }
  }

  String getContentHlCode() {
    const List<String> unsupportedLangIds = ["ia", "ga", "fj", "eo"];
    final userLangId =
        Get.find<SettingsScreenController>().currentAppLanguageCode.value;
    return unsupportedLangIds.contains(userLangId) ? "en" : userLangId;
  }

  void onSideBarTabSelected(int index) {
    reverseAnimationtransiton = index > tabIndex.value;
    tabIndex.value = index;
  }

  void onBottonBarTabSelected(int index) {
    reverseAnimationtransiton = index > tabIndex.value;
    tabIndex.value = index;
  }

  void _checkNewVersion() {
    showVersionDialog.value =
        Hive.box("AppPrefs").get("newVersionVisibility") ?? true;
    if (showVersionDialog.isTrue) {
      newVersionCheck(Get.find<SettingsScreenController>().currentVersion)
          .then((value) {
        if (value) {
          showDialog(
              context: Get.context!,
              builder: (context) => const NewVersionDialog());
        }
      });
    }
  }

  void onChangeVersionVisibility(bool val) {
    Hive.box("AppPrefs").put("newVersionVisibility", !val);
    showVersionDialog.value = !val;
  }

  ///This is used to minimized bottom navigation bar by setting [isHomeSreenOnTop.value] to `true` and set mini player height.
  ///
  ///and applicable/useful if bottom nav enabled
  void whenHomeScreenOnTop() {
    if (Get.find<SettingsScreenController>().isBottomNavBarEnabled.isTrue) {
      final currentRoute = getCurrentRouteName();
      final isHomeOnTop = currentRoute == '/homeScreen';
      final isResultScreenOnTop = currentRoute == '/searchResultScreen';
      final playerCon = Get.find<PlayerController>();

      isHomeSreenOnTop.value = isHomeOnTop;

      // Set miniplayer height accordingly
      if (!playerCon.initFlagForPlayer) {
        if (isHomeOnTop) {
          playerCon.playerPanelMinHeight.value = 75.0;
        } else {
          Future.delayed(
              isResultScreenOnTop
                  ? const Duration(milliseconds: 300)
                  : Duration.zero, () {
            playerCon.playerPanelMinHeight.value =
                75.0 + Get.mediaQuery.viewPadding.bottom;
          });
        }
      }
    }
  }

  Future<void> cachedHomeScreenData({
    bool updateAll = false,
    bool updateQuickPicksNMiddleContent = false,
  }) async {
    if (Get.find<SettingsScreenController>().cacheHomeScreenData.isFalse ||
        quickPicks.value.songList.isEmpty) {
      return;
    }

    final homeScreenData = Hive.box("homeScreenData");

    if (updateQuickPicksNMiddleContent) {
      await homeScreenData.putAll({
        "quickPicksType": quickPicks.value.title,
        "quickPicks": _getContentDataInJson(quickPicks.value.songList,
            isQuickPicks: true),
        "middleContent": _getContentDataInJson(middleContent.toList()),
      });
    } else if (updateAll) {
      await homeScreenData.putAll({
        "quickPicksType": quickPicks.value.title,
        "quickPicks": _getContentDataInJson(quickPicks.value.songList,
            isQuickPicks: true),
        "middleContent": _getContentDataInJson(middleContent.toList()),
        "fixedContent": _getContentDataInJson(fixedContent.toList())
      });
    }

    printINFO("Saved Homescreen data data");
  }

  List<Map<String, dynamic>> _getContentDataInJson(List content,
      {bool isQuickPicks = false}) {
    if (isQuickPicks) {
      return content.toList().map((e) => MediaItemBuilder.toJson(e)).toList();
    } else {
      return content.map((e) {
        if (e.runtimeType == AlbumContent) {
          return (e as AlbumContent).toJson();
        } else {
          return (e as PlaylistContent).toJson();
        }
      }).toList();
    }
  }

  void disposeDetachedScrollControllers({bool disposeAll = false}) {
    final scrollControllersCopy = contentScrollControllers.toList();
    for (final contoller in scrollControllersCopy) {
      if (!contoller.hasClients || disposeAll) {
        contentScrollControllers.remove(contoller);
        contoller.dispose();
      }
    }
  }

  @override
  void dispose() {
    disposeDetachedScrollControllers(disposeAll: true);
    super.dispose();
  }
}
