part of irc.client;

/**
 * IRC Client is the most important class in irc.dart
 *
 *      var config = new BotConfig(
 *        nickname: "DartBot",
 *        host: "irc.esper.net",
 *        port: 6667
 *      );
 *      var client = new Client(config);
 *      // Use Client
 */
class Client extends ClientBase with EventDispatcher {
  @override
  Configuration config;

  @override
  List<Channel> channels = [];

  /**
   * WHOIS Implementation Builder Storage
   */
  Map<String, WhoisBuilder> _whoisBuilders;

  /**
   * Connection System
   */
  IrcConnection connection;

  /**
   * Flag for if the Client has sent a ReadyEvent
   */
  bool _ready = false;
  /**
   * Privately Stored Nickname
   */
  String _nickname;

  /**
   * Flag for if the Client has hit an error.
   */
  bool _errored = false;

  @override
  final IrcParser parser;
  
  final Duration sendInterval;

  @override
  bool connected = false;

  /**
   * Storage for any data.
   * This will persist when you connect and disconnect.
   */
  final Map<String, dynamic> metadata;

  /**
   * Stores the MOTD
   */
  String _motd = "";

  /**
   * Server Supports
   */
  Map<String, String> _supported = {};
  
  /**
   * Server Supports
   */
  Map<String, String> get supported => _supported;

  /**
   * Creates a new IRC Client using the specified configuration
   * If parser is specified, then the parser is used for the current client
   */
  Client(Configuration config, {IrcParser parser, IrcConnection connection, this.sendInterval: const Duration(milliseconds: 100)})
      : this.parser = parser == null ? new RegexIrcParser() : parser,
        this.connection = connection == null ? new SocketIrcConnection() : connection,
        this.metadata = {} {
    this.config = config;
    _registerHandlers();
    _nickname = config.nickname;
    _whoisBuilders = new Map<String, WhoisBuilder>();
  }

  @override
  String get motd => _motd;

  @override
  String get nickname => _nickname;

  @override
  Channel getChannel(String name) => channels.firstWhere((channel) => channel.name == name, orElse: () => null);

  @override
  void connect() {
    _ready = false;
    connection.connect(config).then((_) {
      _timer = new Timer.periodic(sendInterval, (t) {
        if (_queue.isEmpty) {
          return;
        }
        
        var line = _queue.removeAt(0);
        
        /* Sending the line has priority over the event */
        connection.send(line);
        post(new LineSentEvent(this, line));
      });
      
      connection.lines().listen((line) {
        post(new LineReceiveEvent(this, line));
      });
      
      post(new ConnectEvent(this));
    });
  }
  
  List<String> _queue = [];

  @override
  Future disconnect({String reason: "Client Disconnecting"}) {
    send("QUIT :${reason}");
    return connection.disconnect();
  }

  @override
  void post(Event event) {
    /* Handle Error Events */
    if (event is ErrorEvent) {
      _errored = true;
    }
    super.post(event);
  }

  @override
  void send(String line, {bool now: false}) {
    /* Max Line Length for IRC is 512. With the newlines (\r\n or \n) we can only send 510 character lines */
    if (line.length > 510) {
      throw new ArgumentError("The length of '${line}' is greater than 510 characters");
    }
    
    if (now) {
      /* Sending the line has priority over the event */
      connection.send(line);
      post(new LineSentEvent(this, line));
    } else {
      _queue.add(line); 
    }
  }

  /**
   * Fires the Ready Event if it hasn't been fired yet.
   */
  void _fireReady() {
    if (!_ready) {
      _ready = true;
      post(new ReadyEvent(this));
    }
  }

  /**
   * Registers all the default handlers.
   */
  void _registerHandlers() {
    register((ConnectEvent event) {
      if (config.password != null) {
        send("PASS ${config.password}", now: true);
      }
      
      send("NICK ${config.nickname}", now: true);
      send("USER ${config.username} ${config.username} ${config.host} :${config.realname}", now: true);
    });

    register((LineReceiveEvent event) {

      /* Parse the IRC Input */
      var input = parser.convert(event.line);

      switch (input.command) {
        case "376": // End of MOTD
          post(new MOTDEvent(this, _motd));
          _fireReady();
          break;

        case "422": // No MOTD Found
          post(new MOTDEvent(this, 'No MOTD file present of the server.'));
          _fireReady();
          break;

        case "PING":
          /* Server Ping */
          send("PONG :${input.message}");
          break;

        case "JOIN": // User Joined Channel
          var who = input.hostmask.nickname;
          var chanName = input.parameters.length != 0 ? input.parameters[0] : input.message;
          if (who == _nickname) {
            // We Joined a New Channel
            if (getChannel(chanName) == null) {
              channels.add(new Channel(this, chanName));
            }
            post(new BotJoinEvent(this, getChannel(chanName)));
            getChannel(chanName).reloadBans();
          } else {
            post(new JoinEvent(this, who, getChannel(chanName)));
          }
          break;

        case "PRIVMSG": // Message
          _fireReady();
          var from = input.hostmask.nickname;
          var target = input.parameters[0];
          var message = input.message;

          if (message.startsWith("\u0001")) {
            post(new CTCPEvent(this, from, target, message.substring(1, message.length - 1)));
          } else {
            post(new MessageEvent(this, from, target, message));
          }
          break;

        case "NOTICE":
          var from = input.plainHostmask;
          if (input.parameters[0] != "*") from = input.hostmask.nickname;

          var target = input.parameters[0];
          var message = input.message;
          post(new NoticeEvent(this, from, target, message));
          break;

        case "PART": // User Left Channel
          var who = input.hostmask.nickname;

          var chan_name = input.parameters.length != 0 ? input.parameters[0] : input.message;

          if (who == _nickname) {
            post(new BotPartEvent(this, getChannel(chan_name)));
          } else {
            post(new PartEvent(this, who, getChannel(chan_name)));
          }
          break;

        case "QUIT": // User Quit
          var who = input.hostmask.nickname;

          if (who == _nickname) {
            disconnect();
          } else {
            post(new QuitEvent(this, who));
          }
          break;

        case "332": // Topic
          var topic = input.message;
          var chan = getChannel(input.parameters[1]);
          chan._topic = topic;
          post(new TopicEvent(this, chan, topic));
          break;

        case "ERROR": // Server Error
          var message = input.message;
          post(new ErrorEvent(this, message: message, type: "server"));
          break;

        case "353": // Channel User List
          var users = input.message.split(" ")..removeWhere((it) => it.trim().isEmpty);
          var channel = this.getChannel(input.parameters[2]);

          users.forEach((user) {
            switch (user[0]) {
              case "@":
                channel.ops.add(user.substring(1));
                break;
              case "+":
                channel.voices.add(user.substring(1));
                break;
              case "%":
                channel.halfops.add(user.substring(1));
                break;
              case "~":
                channel.owners.add(user.substring(1));
                break;
              default:
                channel.members.add(user);
                break;
            }
          });
          break;

        case "433": // Nickname is in Use
          var original = input.parameters[0];
          post(new NickInUseEvent(this, original));
          break;

        case "NICK": // Nickname Changed
          var original = input.hostmask.nickname;
          var now = input.message;

          /* Posts the Nickname Change Event. No need for checking if we are the original nickname. */
          post(new NickChangeEvent(this, original, now));
          break;

        case "MODE": // Mode Changed
          var split = input.parameters;

          if (split.length < 3) {
            break;
          }

          var channel = getChannel(split[0]);
          var mode = split[1];
          var who = split[2];

          if (channel != null && (mode == "+b" || mode == "-b")) {
            channel.reloadBans();
          }

          post(new ModeEvent(this, mode, who, channel));
          break;

        case "311": // Beginning of WHOIS
          var split = input.parameters;
          var nickname = split[1];
          var hostname = split[3];
          var realname = input.message;
          var builder = new WhoisBuilder(nickname);
          builder
              ..hostname = hostname
              ..realname = realname;
          _whoisBuilders[nickname] = builder;
          break;

        case "312": // WHOIS Server Information
          var split = input.parameters;
          var nickname = split[1];
          var message = input.message;
          var server_name = split[2];
          var builder = _whoisBuilders[nickname];
          builder.serverName = server_name;
          builder.serverInfo = message;
          break;

        case "313": // WHOIS Operator Information
          var nickname = input.parameters[0];
          var builder = _whoisBuilders[nickname];
          if (builder != null) {
            builder.isServerOperator = true;
          }
          break;

        case "317": // WHOIS Idle Information
          var split = input.parameters;
          var nickname = split[1];
          var idle = int.parse(split[2]);
          var builder = _whoisBuilders[nickname];
          builder.idle = true;
          builder.idleTime = idle;
          break;

        case "318": // End of WHOIS
          var nickname = input.parameters[1];
          var builder = _whoisBuilders.remove(nickname);
          post(new WhoisEvent(this, builder));
          break;

        case "319": // WHOIS Channel Information
          var nickname = input.parameters[1];
          
          if (input.message == null) {
            break;
          }
          
          var message = input.message.trim();
          
          var builder = _whoisBuilders[nickname];
          message.split(" ").forEach((chan) {
            if (chan.startsWith("@")) {
              var c = chan.substring(1);
              builder.channels.add(c);
              builder.opIn.add(c);
            } else if (chan.startsWith("+")) {
              var c = chan.substring(1);
              builder.channels.add(c);
              builder.voiceIn.add(c);
            } else if (chan.startsWith("~")) {
              var c = chan.substring(1);
              builder.ownerIn.add(c);
            } else if (chan.startsWith("%")) {
              var c = chan.substring(1);
              builder.halfOpIn.add(c);
            } else {
              builder.channels.add(chan);
            }
          });
          break;

        case "330": // WHOIS Account Information
          var split = input.parameters;
          var builder = _whoisBuilders[split[1]];
          builder.username = split[2];
          break;

        case "PONG": // PONG from Server
          var message = input.message;
          post(new PongEvent(this, message));
          break;

        case "367": // Ban List Entry
          var channel = this.getChannel(input.parameters[1]);
          if (channel == null) { // We Were Banned
            break;
          }
          var ban = input.parameters[2];
          channel.bans.add(new GlobHostmask(ban));
          break;

        case "KICK": // A user was kicked from a channel.
          var channel = this.getChannel(input.parameters[0]);
          var user = input.parameters[1];
          var reason = input.message;
          var by = input.hostmask.nickname;
          post(new KickEvent(this, channel, user, by, reason));
          break;
        case "372": // MOTD Part
          var part = input.message;
          _motd += part + "\n";
          break;
        case "005": // ISUPPORT
          var params = input.parameters;
          params.removeAt(0);
          var message = params.join(" ");
          post(new ServerSupportsEvent(this, message));
          break;
        case "INVITE": // We Were Invited to a Channel
          var user = input.hostmask.nickname;
          var channel = input.message;
          post(new InviteEvent(this, channel, user));
          break;
        case "303": // ISON Response
          List<String> users;
          if (input.message == null) {
            users = [];
          } else {
            users = input.message.split(" ").map((it) => it.trim()).toList();
          }
        
          post(new IsOnEvent(this, users));
          break;
        case "351": // Server Version Response
          var version = input.parameters[0];
          var server = input.parameters[1];
          var comments = input.message;
          
          post(new ServerVersionEvent(this, server, version, comments));
          
          break;
        case "381": // We are now a Server Operator
          post(new ServerOperatorEvent(this));
          break;
      }

      /* Set the Connection Status */
      register((ConnectEvent event) => this.connected = true);
      register((DisconnectEvent event) {
        this.connected = false;
        
        if (_timer != null && _timer.isActive) {
          _timer.cancel();
        }
      });

      /* Handles when the user quits */
      register((QuitEvent event) {
        for (var chan in channels) {
          if (chan.allUsers.contains(event.user)) {
            post(new QuitPartEvent(this, chan, event.user));
            chan.members.remove(event.user);
            chan.voices.remove(event.user);
            chan.ops.remove(event.user);
            chan.halfops.remove(event.user);
            chan.owners.remove(event.user);
          }
        }
      });

      /* Handles CTCP Events so the action event can be executed */
      register((CTCPEvent event) {
        if (event.message.startsWith("ACTION ")) {
          post(new ActionEvent(this, event.user, event.target, event.message.substring(7)));
        }
      });

      /* Handles User Tracking in Channels when a user joins. A user is a member until it is changed. */
      register((JoinEvent event) => event.channel.members.add(event.user));

      /* Handles User Tracking in Channels when a user leaves */
      register((PartEvent event) {
        var channel = event.channel;
        channel.members.remove(event.user);
        channel.voices.remove(event.user);
        channel.ops.remove(event.user);
        channel.owners.remove(event.user);
        channel.halfops.remove(event.user);
      });

      /* Handles User Tracking in Channels when a user is kicked. */
      register((KickEvent event) {
        var channel = event.channel;
        channel.members.remove(event.user);
        channel.voices.remove(event.user);
        channel.ops.remove(event.user);
        channel.owners.remove(event.user);
        channel.halfops.remove(event.user);
        if (event.user == nickname) {
          channels.remove(channel);
        }
      });

      /* Handles Nickname Changes */
      register((NickChangeEvent event) {
        if (event.original == _nickname) {
          _nickname = event.now;
        } else {
          for (Channel channel in channels) {
            if (channel.allUsers.contains(event.original)) {
              var old = event.original;
              var now = event.now;
              if (channel.members.contains(old)) {
                channel.members.remove(old);
                channel.members.add(now);
              }

              if (channel.voices.contains(old)) {
                channel.voices.remove(old);
                channel.voices.add(now);
              }

              if (channel.ops.contains(old)) {
                channel.ops.remove(old);
                channel.ops.add(now);
              }

              if (channel.halfops.contains(old)) {
                channel.halfops.remove(old);
                channel.halfops.add(now);
              }

              if (channel.owners.contains(old)) {
                channel.owners.remove(old);
                channel.owners.add(now);
              }
            }
          }
        }
      });

      /* Handles Channel User Tracking */
      register((ModeEvent event) {
        if (event.channel != null) {
          var channel = event.channel;
          var prefixes = IrcParserSupport.parseSupportedPrefixes(_supported["PREFIX"]);

          if (prefixes["modes"].contains(event.mode.substring(1))) {
            return;
          }

          switch (event.mode) {
            case "+o":
              channel.ops.add(event.user);
              channel.members.remove(event.user);
              channel.halfops.remove(event.user);
              channel.owners.remove(event.user);
              break;
            case "+v":
              channel.voices.add(event.user);
              channel.members.remove(event.user);
              channel.halfops.remove(event.user);
              channel.owners.remove(event.user);
              break;
            case "-v":
              channel.voices.remove(event.user);
              channel.members.add(event.user);
              channel.halfops.remove(event.user);
              channel.owners.remove(event.user);
              break;
            case "-o":
              channel.ops.remove(event.user);
              channel.members.add(event.user);
              channel.halfops.remove(event.user);
              channel.owners.remove(event.user);
              break;
            case "+q":
              channel.owners.add(event.user);
              channel.ops.remove(event.user);
              channel.voices.remove(event.user);
              channel.members.remove(event.user);
              channel.halfops.remove(event.user);
              break;
            case "-q":
              channel.ops.remove(event.user);
              channel.voices.remove(event.user);
              channel.members.add(event.user);
              channel.owners.remove(event.user);
              channel.halfops.remove(event.user);
              break;
            case "+h":
              channel.ops.remove(event.user);
              channel.voices.remove(event.user);
              channel.members.remove(event.user);
              channel.owners.remove(event.user);
              channel.halfops.add(event.user);
              break;
            case "-h":
              channel.ops.remove(event.user);
              channel.voices.remove(event.user);
              channel.members.add(event.user);
              channel.owners.remove(event.user);
              channel.halfops.remove(event.user);
              break;
          }
        }
      });
    });

    /* When the Bot leaves a channel, we no longer retain the object. */
    register((BotPartEvent event) => channels.remove(event.channel));

    register((ServerSupportsEvent event) {
      _supported.addAll(event.supported);
    });
  }
  
  @override
  Future<bool> isUserOn(String name) {
    var completer = new Completer();
    
    register((IsOnEvent event) {
      completer.complete(event.users.contains(name));
    }, once: true);
    
    send("ISON ${name}");
    
    return completer.future;
  }
  
  @override
  Future<ServerVersionEvent> getServerVersion([String target]) {
    var completer = new Completer();
    
    register((ServerVersionEvent event) {
      completer.complete(event);
    }, once: true);
    
    send(target != null ? "VERSION ${target}" : "VERSION");
    
    return completer.future;
  }
  
  @override
  Future<String> getChannelTopic(String channel) {
    var completer = new Completer();
    
    register((TopicEvent event) {
      completer.complete(event.topic);
    }, filter: (TopicEvent event) => event.channel.name != channel, once: true);
    
    send("TOPIC ${channel}");
    
    return completer.future;
  }
  
  void setChannelTopic(String channel, String topic) {
    if (supported.containsKey("TOPICLEN")) {
      var length = supported["TOPICLEN"];
      
      if (topic.length > length) {
        throw new ArgumentError("Topic exceeds maximum length.");
      }
    }
    
    send("TOPIC ${channel} :${topic}");
  }
  
  void refreshUserList(String channel) {
    send("NAMES ${channel}");
  }
  
  void wallops(String message) {
    send("WALLOPS :${message}");
  }
  
  Timer _timer;
  
  Future<WhoisEvent> whois(String user) {
    var completer = new Completer();
    register((WhoisEvent event) {
      completer.complete(event);
    }, filter: (WhoisEvent event) => event.nickname != user, once: true);
    send("WHOIS ${user}");
    return completer.future;
  }
}
