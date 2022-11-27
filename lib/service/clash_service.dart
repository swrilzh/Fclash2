import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:fclash/bean/clash_config_entity.dart';
import 'package:fclash/generated_bindings.dart';
import 'package:fclash/main.dart';
import 'package:fclash/service/notification_service.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:kommon/kommon.dart' hide ProxyTypes;
import 'package:path/path.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:proxy_manager/proxy_manager.dart';
import 'package:tray_manager/tray_manager.dart';

late NativeLibrary clashFFI;

class ClashService extends GetxService with TrayListener {
  // 需要一起改端口
  static const clashBaseUrl = "http://127.0.0.1:$clashExtPort";
  static const clashExtPort = 22345;

  // 运行时
  late Directory _clashDirectory;
  RandomAccessFile? _clashLock;

  // 流量
  final uploadRate = 0.0.obs;
  final downRate = 0.0.obs;
  final yamlConfigs = RxSet<FileSystemEntity>();
  final currentYaml = 'config.yaml'.obs;
  final proxyStatus = RxMap<String, int>();

  // action
  static const ACTION_SET_SYSTEM_PROXY = "assr";
  static const ACTION_UNSET_SYSTEM_PROXY = "ausr";
  static const MAX_ENTRIES = 5;

  // default port
  static var initializedHttpPort = 0;
  static var initializedSockPort = 0;
  static var initializedMixedPort = 0;

  // config
  Rx<ClashConfigEntity?> configEntity = Rx(null);

  // log
  Stream<dynamic>? logStream;
  RxMap<String, dynamic> proxies = RxMap();
  RxBool isSystemProxyObs = RxBool(false);

  ClashService() {
    // load lib
    var fullPath = "";
    if (Platform.isWindows) {
      fullPath = "libclash.dll";
    } else if (Platform.isMacOS) {
      fullPath = "libclash.dylib";
    } else {
      fullPath = "libclash.so";
    }
    final lib = ffi.DynamicLibrary.open(fullPath);
    clashFFI = NativeLibrary(lib);
    clashFFI.init_native_api_bridge(ffi.NativeApi.initializeApiDLData);
  }

  Future<ClashService> init() async {
    _clashDirectory = await getApplicationSupportDirectory();
    // init config yaml
    final _ = SpUtil.getData('yaml', defValue: currentYaml.value);
    initializedHttpPort = SpUtil.getData('http-port', defValue: 12346);
    initializedSockPort = SpUtil.getData('socks-port', defValue: 12347);
    initializedMixedPort = SpUtil.getData('mixed-port', defValue: 12348);
    currentYaml.value = _;
    Request.setBaseUrl(clashBaseUrl);
    // init clash
    // kill all other clash clients
    final clashConfigPath = p.join(_clashDirectory.path, "clash");
    _clashDirectory = Directory(clashConfigPath);
    print("fclash work directory: ${_clashDirectory.path}");
    final clashConf = p.join(_clashDirectory.path, currentYaml.value);
    final countryMMdb = p.join(_clashDirectory.path, 'Country.mmdb');
    if (!await _clashDirectory.exists()) {
      await _clashDirectory.create(recursive: true);
    }
    // copy executable to directory
    final mmdb = await rootBundle.load('assets/tp/clash/Country.mmdb');
    // write to clash dir
    final mmdbF = File(countryMMdb);
    if (!mmdbF.existsSync()) {
      await mmdbF.writeAsBytes(mmdb.buffer.asInt8List());
    }
    final config = await rootBundle.load('assets/tp/clash/config.yaml');
    // write to clash dir
    final configF = File(clashConf);
    if (!configF.existsSync()) {
      await configF.writeAsBytes(config.buffer.asInt8List());
    }
    // create or detect lock file
    await _acquireLock(_clashDirectory);
    // ffi
    clashFFI.set_home_dir(_clashDirectory.path.toNativeUtf8().cast());
    clashFFI.clash_init(_clashDirectory.path.toNativeUtf8().cast());
    clashFFI.set_config(clashConf.toNativeUtf8().cast());
    clashFFI.set_ext_controller(clashExtPort);
    if (clashFFI.parse_options() == 0) {
      Get.printInfo(info: "parse ok");
    }
    Future.delayed(Duration.zero, () {
      initDaemon();
    });
    // tray show issue
    trayManager.addListener(this);
    // wait getx initialize
    Future.delayed(const Duration(seconds: 3), () {
      Get.find<NotificationService>()
          .showNotification("Fclash", "Is running".tr);
    });
    return this;
  }

  void getConfigs() {
    yamlConfigs.clear();
    final entities = _clashDirectory.listSync();
    for (final entity in entities) {
      if (entity.path.toLowerCase().endsWith('.yaml') &&
          !yamlConfigs.contains(entity)) {
        yamlConfigs.add(entity);
        Get.printInfo(info: 'detected: ${entity.path}');
      }
    }
  }

  Map<String, dynamic> getConnections() {
    String connections =
        clashFFI.get_all_connections().cast<Utf8>().toDartString();
    return json.decode(connections);
  }

  void closeAllConnections() {
    clashFFI.close_all_connections();
  }

  bool closeConnection(String connectionId) {
    final id = connectionId.toNativeUtf8().cast<ffi.Char>();
    return clashFFI.close_connection(id) == 1;
  }

  Future<void> getCurrentClashConfig() async {
    configEntity.value =
        ClashConfigEntity.fromJson(await Request.get('/configs'));
  }

  Future<void> reload() async {
    // get configs
    getConfigs();
    await getCurrentClashConfig();
    // proxies
    await getProxies();
    updateTray();
  }

  Future<bool> isRunning() async {
    try {
      final resp = await Request.get(clashBaseUrl,
          options: Options(sendTimeout: 1000, receiveTimeout: 1000));
      if ('clash' == resp['hello']) {
        return true;
      }
      return false;
    } catch (e) {
      return false;
    }
  }

  void initDaemon() async {
    printInfo(info: 'init clash service');
    // wait for online
    while (!await isRunning()) {
      printInfo(info: 'waiting online status');
      await Future.delayed(const Duration(milliseconds: 500));
    }
    // get traffic
    Timer.periodic(const Duration(seconds: 1), (t) {
      final traffic = clashFFI.get_traffic().cast<Utf8>().toDartString();
      if (kDebugMode) {
        debugPrint("$traffic");
      }
      try {
        final trafficJson = jsonDecode(traffic);
        uploadRate.value = trafficJson['Up'].toDouble() / 1024; // KB
        downRate.value = trafficJson['Down'].toDouble() / 1024; // KB
        // fix: 只有KDE不会导致Tray自动消失
        // final desktop = Platform.environment['XDG_CURRENT_DESKTOP'];
        // updateTray();
      } catch (e) {
        Get.printError(info: '$e');
      }
    });
    await startLogging();
    // system proxy
    // listen port
    await reload();
    await checkPort();
    if (isSystemProxy()) {
      setSystemProxy();
    }
  }

  @override
  void onClose() {
    closeClashDaemon();
    super.onClose();
  }

  Future<void> closeClashDaemon() async {
    Get.printInfo(info: 'fclash: closing daemon');
    // double check
    // stopClashSubP();
    if (isSystemProxy()) {
      // just clear system proxy
      await clearSystemProxy(permanent: false);
    }
    await _clashLock?.unlock();
  }

  Future<void> getProxies() async {
    final proxies = await Request.get('/proxies');
    this.proxies.value = proxies;
  }

  /// @Deprecated
  // Future<Stream<Uint8List>?> getTraffic() async {
  //   Response<ResponseBody> resp = await Request.dioClient
  //       .get('/traffic', options: Options(responseType: ResponseType.stream));
  //   return resp.data?.stream;
  // }

  // @Deprecated
  // Future<Stream<Uint8List>?> _getLog({String type = "info"}) async {
  //   Response<ResponseBody> resp = await Request.dioClient.get('/logs',
  //       options: Options(responseType: ResponseType.stream),
  //       queryParameters: {"level": type});
  //   return resp.data?.stream;
  // }

  Future<void> startLogging() async {
    final receiver = ReceivePort();
    logStream = receiver.asBroadcastStream();
    if (kDebugMode) {
      logStream?.listen((event) {
        print("LOG: ${event}");
      });
    }
    final nativePort = receiver.sendPort.nativePort;
    clashFFI.start_log(nativePort);
  }

  Future<bool> _changeConfig(FileSystemEntity config) async {
    // judge valid
    if (clashFFI.is_config_valid(config.path.toNativeUtf8().cast()) == 0) {
      final resp = await Request.dioClient.put('/configs',
          queryParameters: {"force": false}, data: {"path": config.path});
      Get.printInfo(info: 'config changed ret: ${resp.statusCode}');
      currentYaml.value = basename(config.path);
      SpUtil.setData('yaml', currentYaml.value);
      return resp.statusCode == 204;
    } else {
      Future.delayed(Duration.zero, () {
        Get.defaultDialog(
            middleText: 'not a valid config file'.tr,
            onConfirm: () {
              Get.back();
            });
      });
      config.delete();
      return false;
    }
  }

  Future<bool> changeYaml(FileSystemEntity config) async {
    try {
      if (await config.exists()) {
        return await _changeConfig(config);
      } else {
        return false;
      }
    } finally {
      reload();
    }
  }

  Future<bool> changeProxy(selectName, String proxyName) async {
    final resp = await Request.dioClient
        .put('/proxies/$selectName', data: {"name": proxyName});
    if (resp.statusCode == 204) {
      reload();
    }
    return resp.statusCode == 204;
  }

  Future<bool> changeConfigField(String field, dynamic value) async {
    try {
      final resp =
          await Request.dioClient.patch('/configs', data: {field: value});
      SpUtil.setData(field, value);
      return resp.statusCode == 204;
    } finally {
      await getCurrentClashConfig();
      if (field.endsWith("port") && isSystemProxy()) {
        setSystemProxy();
      }
      updateTray();
    }
  }

  bool isSystemProxy() {
    return SpUtil.getData('system_proxy', defValue: false);
  }

  Future<bool> setIsSystemProxy(bool proxy) {
    isSystemProxyObs.value = proxy;
    return SpUtil.setData('system_proxy', proxy);
  }

  Future<void> setSystemProxy() async {
    if (configEntity.value != null) {
      final entity = configEntity.value!;
      if (entity.port != 0) {
        await proxyManager.setAsSystemProxy(
            ProxyTypes.http, '127.0.0.1', entity.port!);
        print("set http");
        await proxyManager.setAsSystemProxy(
            ProxyTypes.https, '127.0.0.1', entity.port!);
      }
      if (entity.socksPort != 0 && !Platform.isWindows) {
        print("set socks");
        await proxyManager.setAsSystemProxy(
            ProxyTypes.socks, '127.0.0.1', entity.socksPort!);
      }
      await setIsSystemProxy(true);
    }
  }

  Future<void> clearSystemProxy({bool permanent = true}) async {
    await proxyManager.cleanSystemProxy();
    if (permanent) {
      await setIsSystemProxy(false);
    }
  }

  void updateTray() {
    final stringList = List<MenuItem>.empty(growable: true);
    // yaml
    stringList
        .add(MenuItem(label: "profile: ${currentYaml.value}", disabled: true));
    if (proxies['proxies'] != null) {
      Map<String, dynamic> m = proxies['proxies'];
      m.removeWhere((key, value) => value['type'] != "Selector");
      var cnt = 0;
      for (final k in m.keys) {
        if (cnt >= ClashService.MAX_ENTRIES) {
          stringList.add(MenuItem(label: "...", disabled: true));
          break;
        }
        stringList.add(
            MenuItem(label: "${m[k]['name']}: ${m[k]['now']}", disabled: true));
        cnt += 1;
      }
    }
    // port
    if (configEntity.value != null) {
      stringList.add(
          MenuItem(label: 'http: ${configEntity.value?.port}', disabled: true));
      stringList.add(MenuItem(
          label: 'socks: ${configEntity.value?.socksPort}', disabled: true));
    }
    // system proxy
    stringList.add(MenuItem.separator());
    if (!isSystemProxy()) {
      stringList
          .add(MenuItem(label: "Not system proxy yet.".tr, disabled: true));
      stringList.add(MenuItem(
          label: "Set as system proxy".tr,
          toolTip: "click to set fclash as system proxy".tr,
          key: ACTION_SET_SYSTEM_PROXY));
    } else {
      stringList.add(MenuItem(label: "System proxy now.".tr, disabled: true));
      stringList.add(MenuItem(
          label: "Unset system proxy".tr,
          toolTip: "click to reset system proxy",
          key: ACTION_UNSET_SYSTEM_PROXY));
      stringList.add(MenuItem.separator());
    }
    initAppTray(details: stringList, isUpdate: true);
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case ACTION_SET_SYSTEM_PROXY:
        setSystemProxy().then((value) {
          reload();
        });
        break;
      case ACTION_UNSET_SYSTEM_PROXY:
        clearSystemProxy().then((_) {
          reload();
        });
        break;
    }
  }

  Future<bool> addProfile(String name, String url) async {
    final configName = '$name.yaml';
    final newProfilePath = join(_clashDirectory.path, configName);
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) {
        return false;
      }
      final resp = await Dio(BaseOptions(
              headers: {'User-Agent': 'Fclash'},
              sendTimeout: 15000,
              receiveTimeout: 15000))
          .downloadUri(uri, newProfilePath, onReceiveProgress: (i, t) {
        Get.printInfo(info: "$i/$t");
      });
      return resp.statusCode == 200;
    } catch (e) {
      BrnToast.show("Error: ${e}", Get.context!);
    } finally {
      final f = File(newProfilePath);
      if (f.existsSync() && await changeYaml(f)) {
        // set subscription
        await SpUtil.setData('profile_$name', url);
        return true;
      }
      return false;
    }
  }

  Future<bool> deleteProfile(FileSystemEntity config) async {
    if (config.existsSync()) {
      config.deleteSync();
      await SpUtil.remove('profile_${basename(config.path)}');
      reload();
      return true;
    } else {
      return false;
    }
  }

  Future<void> checkPort() async {
    if (configEntity.value != null) {
      if (configEntity.value!.port == 0) {
        await changeConfigField('port', initializedHttpPort);
      }
      if (configEntity.value!.mixedPort == 0) {
        await changeConfigField('mixed-port', initializedMixedPort);
      }
      if (configEntity.value!.socksPort == 0) {
        await changeConfigField('socks-port', initializedSockPort);
      }
    }
  }

  Future<int> delay(String proxyName,
      {int timeout = 5000, String url = "https://www.google.com"}) async {
    try {
      final resp = await Request.dioClient.get('/proxies/$proxyName/delay',
          queryParameters: {"timeout": timeout, "url": url});
      final data = jsonDecode(resp.data);
      print(data.toString());
      if (data['message'] != null) {
        print(data['message'].toString());
        return -1;
      }
      return data['delay'] ?? -1;
    } catch (e) {
      return -1;
    }
  }

  /// yaml: test
  String getSubscriptionLinkByYaml(String yaml) {
    final url = SpUtil.getData('profile_$yaml', defValue: "");
    Get.printInfo(info: 'subs link for $yaml: $url');
    return url;
  }

  /// stop clash by ps -A
  /// ps -A | grep '[^f]clash' | awk '{print $1}' | xargs
  ///
  /// notice: is a double check in client mode
  // void stopClashSubP() {
  //   final res = Process.runSync("ps", [
  //     "-A",
  //     "|",
  //     "grep",
  //     "'[^f]clash'",
  //     "|",
  //     "awk",
  //     "'print \$1'",
  //     "|",
  //     "xrgs",
  //   ]);
  //   final clashPids = res.stdout.toString().split(" ");
  //   for (final pid in clashPids) {
  //     final pidInt = int.tryParse(pid);
  //     if (pidInt != null) {
  //       Process.killPid(int.parse(pid));
  //     }
  //   }
  // }

  Future<bool> updateSubscription(String name) async {
    final configName = '$name.yaml';
    final newProfilePath = join(_clashDirectory.path, configName);
    final url = SpUtil.getData('profile_$name');
    try {
      final uri = Uri.tryParse(url);
      if (uri == null) {
        return false;
      }
      // delete exists
      final f = File(newProfilePath);
      final tmpF = File('$newProfilePath.tmp');

      final resp = await Dio(BaseOptions(
              headers: {'User-Agent': 'Fclash'},
              sendTimeout: 15000,
              receiveTimeout: 15000))
          .downloadUri(uri, tmpF.path, onReceiveProgress: (i, t) {
        Get.printInfo(info: "$i/$t");
      }).catchError((e) {
        if (tmpF.existsSync()) {
          tmpF.deleteSync();
        }
      });
      if (resp.statusCode == 200) {
        if (f.existsSync()) {
          f.deleteSync();
        }
        tmpF.renameSync(f.path);
      }
      // set subscription
      await SpUtil.setData('profile_$name', url);
      return resp.statusCode == 200;
    } finally {
      final f = File(newProfilePath);
      if (f.existsSync()) {
        await changeYaml(f);
      }
    }
  }

  bool isHideWindowWhenStart() {
    return SpUtil.getData('boot_window_hide', defValue: false);
  }

  Future<bool> setHideWindowWhenStart(bool hide) {
    return SpUtil.setData('boot_window_hide', hide);
  }

  void handleSignal() {
    StreamSubscription? subTerm;
    subTerm = ProcessSignal.sigterm.watch().listen((event) {
      subTerm?.cancel();
      // _clashProcess?.kill();
    });
  }

  Future<void> testAllProxies(List<dynamic> allItem) async {
    await Future.wait(allItem.map((proxyName) async {
      final delayInMs = await delay(proxyName);
      proxyStatus[proxyName] = delayInMs;
    }));
  }

  Future<void> _acquireLock(Directory clashDirectory) async {
    final path = p.join(clashDirectory.path, "fclash.lock");
    final lockFile = File(path);
    if (!lockFile.existsSync()) {
      lockFile.createSync(recursive: true);
    }
    try {
      _clashLock = await lockFile.open(mode: FileMode.write);
      await _clashLock?.lock();
    } catch (e) {
      await Get.find<NotificationService>()
          .showNotification("Fclash", "Already running, Now exit.".tr);
      exit(0);
    }
  }
}
