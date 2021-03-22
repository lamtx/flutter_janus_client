class PluginData {
  PluginData(this._pluginData);

  final Map _pluginData;

  Map? _data;
  String? _plugin;

  String get plugin {
    return _plugin ??= _pluginData["plugin"] as String;
  }

  Map get data {
    return _data ??= _pluginData["data"] as Map;
  }
}
