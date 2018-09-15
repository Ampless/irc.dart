part of irc.parser;

/**
 * IRC Message
 */
class Message {
  /**
   * Original Line
   */
  String line;

  /**
   * IRC Command
   */
  String command;

  /**
   * Message
   */
  String message;

  String _hostmask;

  /**
   * IRC v3 Tags
   */
  Map<String, String> tags;

  /**
   * Parameters
   */
  List<String> parameters;

  /**
   * Creates a new Message
   */
  Message({this.line, hostmask, this.command, this.message, this.parameters, this.tags})
      : _hostmask = hostmask;

  @override
  String toString() => line;


  Hostmask _parsedHostmask;
  /**
   * Gets the Parsed Hostmask
   */
  Hostmask get hostmask {
    if (_parsedHostmask != null || _hostmask == null) {
      return _parsedHostmask;
    }

    return _parsedHostmask = new Hostmask.parse(_hostmask);
  }

  /**
   * The Plain Hostmask
   */
  String get plainHostmask => _hostmask;

  bool get hasAccountTag => tags.containsKey("account");
  String get accountTag => tags["account"];

  bool get hasServerTime => tags.containsKey("time");
  DateTime get serverTime {
    if (_serverTime != null) {
      return _serverTime;
    } else {
      return _serverTime = DateTime.parse(tags["time"]);
    }
  }

  bool get isBatched => tags.containsKey("batch");
  String get batchId => tags["batch"];

  DateTime _serverTime;
}

/**
 * IRC Parser Helpers
 */
class IrcParserSupport {
  /**
   * Parses IRCv3 Tags from [input].
   * 
   * [input] should begin with the @ part of the tags
   * and not include the space at the end.
   */
  static Map<String, dynamic> parseTags(String input) {
    var out = <String, dynamic>{};
    var parts = input.substring(1).split(";");
    for (var part in parts) {
      if (part.contains("=")) {
        var keyValue = part.split("=");
        out[keyValue[0]] = keyValue.skip(1).join("=");
      } else {
        out[part] = true;
      }
    }
    return out;
  }
  
  /**
   * Parses the ISUPPORT PREFIX Property
   * 
   * [input] should begin with '(' and contain ')'
   */
  static Map<String, String> parseSupportedPrefixes(String input) {
    if (input == null) {
      return {};
    }

    var out = <String, String>{};
    var split = input.split(")");
    var modes = split[0].substring(1).split("");
    var prefixes = split[1].split("");
    
    var i = 0;
    for (var mode in modes) {
      out[mode] = prefixes[i];
      i++;
    }
    
    return out;
  }

  static ModeChange parseMode(String input) {
    ModeChange mode;
    if (input.startsWith("+")) {
      mode = new ModeChange(
        input.substring(1).split("").toSet(),
        new Set<String>()
      );
    } else if (input.startsWith("-")) {
      mode = new ModeChange(
        new Set<String>(),
        input.substring(1).split("").toSet()
      );
    } else {
      throw new Exception("Failed to parse mode: invalid prefix for ${input}");
    }
    return mode;
  }
}

class ModeChange {
  final Set<String> added;
  final Set<String> removed;

  Set<String> get modes => isAdded ? added : removed;
  bool get isAdded => added.isNotEmpty;
  bool get isRemoved => removed.isNotEmpty;

  ModeChange(this.added, this.removed);

  @override
  String toString() =>
    added.isEmpty ?
    "-${removed.join()}" :
    "+${added.join()}";
}

class Mode {
  final Set<String> modes;

  Mode(this.modes);
  Mode.empty() : modes = new Set<String>();

  bool has(String x) {
    return modes.contains(x);
  }
}
