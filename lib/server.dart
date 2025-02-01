import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Clipboard
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:flutter/services.dart';  // For Shortcuts/Keyboard handling
import 'package:flutter/widgets.dart';    // For Intent/Actions classes




class ServerPage extends StatefulWidget {
  final String serverId; // Full server UUID provided

  const ServerPage({required this.serverId, Key? key}) : super(key: key);

  @override
  _ServerPageState createState() => _ServerPageState();
}

class _ServerPageState extends State<ServerPage> {
  IOWebSocketChannel? channel;
  List<String> consoleMessages = [];
  bool isLoading = true;
  String? errorMessage;
  String? token; // Holds JWT token for auth
  final ScrollController _scrollController = ScrollController();
  Timer? logsTimeout;

  // Stats values
  // Now cpuUsage stores the received percent value (e.g. 28.591)
  double cpuUsage = 0.0;
  double memUsageMB = 0.0;
  double memLimitMB = 0.0;
  int uptimeSeconds = 0;

  // API configuration loaded from SharedPreferences.
  late String panelUrl;
  late String apiKey;

  final TextEditingController _commandController = TextEditingController();
  List<String> _commandHistory = [];
  int _historyIndex = -1;

  Future<void> loadCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    // Retrieve panel_url and remove the protocol ("https://" or "http://")
    String storedPanelUrl = prefs.getString("panel_url") ??
        "https://panel.melonhost.cz";
    panelUrl = storedPanelUrl.replaceAll(RegExp(r'^https?:\/\/'), '');

    // Retrieve api_key
    apiKey = prefs.getString("api_key") ?? "";
  }

  @override
  void initState() {
    super.initState();
    loadCredentials().then((_) {
      initializeWebSocket();
    });
  }


  // Remove ANSI escape codes from a string.
  String stripAnsiCodes(String input) {
    final ansiRegex = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
    return input.replaceAll(ansiRegex, '');
  }

  // Format uptime (in seconds) into "xd xh xm xs".
  String formatUptime(int seconds) {
    int days = seconds ~/ (3600 * 24);
    int hours = (seconds % (3600 * 24)) ~/ 3600;
    int minutes = (seconds % 3600) ~/ 60;
    int secs = seconds % 60;
    return "$days d $hours h $minutes m $secs s";
  }

  Future<void> initializeWebSocket() async {
    try {
      String cleanPanelUrl = panelUrl.replaceAll(RegExp(r'/$'), '');
      String shortServerId = widget.serverId.substring(0, 8);
      String httpUrl =
          "https://$cleanPanelUrl/api/client/servers/$shortServerId/websocket";
      print("HTTP GET Request URL: $httpUrl");

      final response = await http.get(
        Uri.parse(httpUrl),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
      );
      print("HTTP Response Status Code: ${response.statusCode}");
      print("HTTP Response Body: ${response.body}");
      if (response.statusCode != 200) {
        throw Exception(
            "Failed to fetch WebSocket URL: ${response.statusCode} ${response
                .reasonPhrase}");
      }
      final data = jsonDecode(response.body);
      token = data['data']['token'] ?? '';
      final rawSocketUrl = data['data']['socket'] ?? '';
      if (rawSocketUrl.isEmpty || token!.isEmpty) {
        throw Exception("WebSocket URL or token is empty or invalid.");
      }
      // Append token as query parameter.
      String wsUrl = "$rawSocketUrl?token=$token";
      if (wsUrl.startsWith("https://")) {
        wsUrl = wsUrl.replaceFirst("https://", "wss://");
      } else if (wsUrl.startsWith("http://")) {
        wsUrl = wsUrl.replaceFirst("http://", "ws://");
      }
      print("Connecting to WebSocket: $wsUrl");
      // Connect to the WebSocket.
      channel = IOWebSocketChannel.connect(Uri.parse(wsUrl), headers: {
        "Origin": "https://$cleanPanelUrl",
      });
      // Listen for incoming messages.
      channel!.stream.listen(
            (message) {
          print("WebSocket Message Received: $message");
          try {
            var decodedMsg = jsonDecode(message);
            if (decodedMsg is Map && decodedMsg["event"] != null) {
              var evt = decodedMsg["event"];
              if (evt == "auth success") {
                requestLogs();
              } else if (evt == "init logs") {
                logsTimeout?.cancel();
                var args = decodedMsg["args"];
                if (args is List && args.isNotEmpty) {
                  if (args[0] is List) {
                    for (var line in args[0]) {
                      addConsoleMessage(line.toString());
                    }
                  } else {
                    addConsoleMessage(args[0].toString());
                  }
                } else {
                  addConsoleMessage("Unexpected init logs format: $message");
                }
              } else if (evt == "console output") {
                var args = decodedMsg["args"];
                if (args is List && args.isNotEmpty) {
                  addConsoleMessage(args[0].toString());
                }
              } else if (evt == "stats") {
                var args = decodedMsg["args"];
                if (args is List && args.isNotEmpty) {
                  try {
                    var stats = jsonDecode(args[0].toString());
                    if (mounted) {
                      setState(() {
                        // Do not multiply by 100.
                        // Assume stats["cpu_absolute"] is already the percentage.
                        cpuUsage = (stats["cpu_absolute"] ?? 0);
                        memUsageMB =
                            (stats["memory_bytes"] ?? 0) / (1024 * 1024);
                        memLimitMB =
                            (stats["memory_limit_bytes"] ?? 0) / (1024 * 1024);
                        uptimeSeconds = stats["uptime"] ?? 0;
                      });
                    }
                  } catch (e) {

                  }
                }
              } else if (evt == "error") {
                addConsoleMessage("Error received: ${decodedMsg["args"]}");
              } else if (evt == "token expiring") {
                addConsoleMessage("Token expiring; re-authenticating...");
              } else if (evt == "token expired") {
                addConsoleMessage("Token has expired. Reconnecting...");
                reconnectWebSocket();
              }
            } else {
              addConsoleMessage(message);
            }
          } catch (e) {
            addConsoleMessage("JSON error: $e, raw: $message");
          }
        },
        onError: (error) {
          print("WebSocket Error: $error");
          showErrorDialog("WebSocket Error: $error");
        },
        onDone: () {
          print("WebSocket connection closed.");
          showErrorDialog("WebSocket connection closed. Reconnecting...");
          Future.delayed(Duration(seconds: 5), () {
            if (mounted) {
              initializeWebSocket();
            }
          });
        },
      );
      // Send auth message immediately.
      Future.microtask(() {
        final authMsg = jsonEncode({
          "event": "auth",
          "args": [token]
        });
        print("Sending auth message: $authMsg");
        channel!.sink.add(authMsg);
      });
      if (mounted) {
        setState(() {
          isLoading = false;
          errorMessage = null;
        });
      }
    } catch (e) {
      print("Failed to initialize WebSocket: $e");
      showErrorDialog("Failed to initialize WebSocket: $e");
    }
  }

  // Request logs with a retry mechanism.
  void requestLogs({int retryCount = 0}) {
    if (channel != null) {
      final getLogsMsg = jsonEncode({
        "event": "get logs",
        "args": []
      });
      print("Sending get logs message: $getLogsMsg");
      channel!.sink.add(getLogsMsg);
      logsTimeout?.cancel();
      logsTimeout = Timer(Duration(seconds: 5), () {
        if (retryCount < 5) {
          int delaySeconds = 2 * (retryCount + 1);
          print(
              "Timeout: No initial log data received. Retrying get logs in $delaySeconds seconds...");
          Future.delayed(Duration(seconds: delaySeconds), () {
            requestLogs(retryCount: retryCount + 1);
          });
        } else {

        }
      });
    }
  }

  // Reconnect the WebSocket.
  void reconnectWebSocket() {
    channel?.sink.close();
    Future.delayed(Duration(seconds: 2), () {
      if (mounted) {
        initializeWebSocket();
      }
    });
  }

  // Append new console messages.
  void addConsoleMessage(String message) {
    final cleanMessage = stripAnsiCodes(message);
    if (!mounted) return;
    setState(() {
      consoleMessages.add(cleanMessage);
    });
    if (_scrollController.hasClients) {
      Future.delayed(Duration(milliseconds: 100), () {
        if (!mounted) return;
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      });
    }
  }

  // Display an error dialog.
  void showErrorDialog(String message) {
    if (!mounted) return;
    setState(() {
      errorMessage = message;
    });
    showDialog(
      context: context,
      builder: (context) =>
          AlertDialog(
            title: Text('Error'),
            content: Text(message),
            actions: [
              TextButton(
                onPressed: () {
                  if (mounted) Navigator.pop(context);
                },
                child: Text('OK'),
              ),
            ],
          ),
    );
  }

  // Replace your existing sendCommand method with this HTTP version
  Future<void> sendCommand(String command) async {
    if (command.isEmpty) return;

    try {
      final String cleanPanelUrl = panelUrl.replaceAll(RegExp(r'/$'), '');
      final String shortServerId = widget.serverId.substring(0, 8);

      final response = await http.post(
        Uri.parse("https://$cleanPanelUrl/api/client/servers/$shortServerId/command"),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({'command': command}),
      );

      if (response.statusCode == 200 || response.statusCode == 204) {

        _commandHistory.add(command);
        _historyIndex = _commandHistory.length;
      } else {
        addConsoleMessage("Command failed: ${response.body}");
      }
    } catch (e) {
      addConsoleMessage("Error sending command: $e");
    }

    _commandController.clear();
  }


  // ----- POWER BUTTONS -- Using REST API instead of WebSocket ------
  Future<void> sendPowerSignal(String signal) async {
    try {
      String cleanPanelUrl = panelUrl.replaceAll(RegExp(r'/$'), '');
      String shortServerId = widget.serverId.substring(0, 8);
      // Build the power endpoint URL.
      String url = "https://$cleanPanelUrl/api/client/servers/$shortServerId/power";
      print("Sending power signal '$signal' to URL: $url");
      final response = await http.post(
        Uri.parse(url),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: jsonEncode({
          "signal": signal,
        }),
      );
      print("Power API response: ${response.statusCode} ${response.body}");
      if (response.statusCode != 200 && response.statusCode != 204) {
        addConsoleMessage("Failed to send power signal: ${response.body}");
      } else {
        addConsoleMessage("Power signal '$signal' sent successfully.");
      }
    } catch (e) {
      addConsoleMessage("Error sending power signal: $e");
    }
  }

  void powerStart() {
    sendPowerSignal("start");
  }

  void powerRestart() {
    sendPowerSignal("restart");
  }

  void powerStop() {
    sendPowerSignal("stop");
  }

  // -----------------------------------------------------

  // Copy entire console output to clipboard.
  void copyAllOutput() {
    final allOutput = consoleMessages.join("\n");
    Clipboard.setData(ClipboardData(text: allOutput));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text("Console output copied!")),
    );
  }

  @override
  void dispose() {
    logsTimeout?.cancel();
    channel?.sink.close();
    _scrollController.dispose();
    super.dispose();
  }

  // Add this state variable at the top of _ServerPageState
  int _selectedTabIndex = 0;

// Replace the existing build method with this updated version
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: _buildNavigationBar(),
        // Removed entire actions array containing the copy button
      ),
      body: _buildCurrentTab(),
    );
  }


// Update the _buildNavigationBar method
  Widget _buildNavigationBar() {
    return NavigationBar(
      selectedIndex: _selectedTabIndex,
      onDestinationSelected: (index) => setState(() => _selectedTabIndex = index),
      destinations: const [
        NavigationDestination(
          icon: Icon(Icons.terminal),
          label: 'Console',
        ),
        NavigationDestination(
          icon: Icon(Icons.folder),
          label: 'Files',
        ),
        NavigationDestination(
          icon: Icon(Icons.storage),
          label: 'Databases',
        ),
        NavigationDestination(
          icon: Icon(Icons.schedule),
          label: 'Schedules',
        ),
        NavigationDestination(
          icon: Icon(Icons.people),
          label: 'Users',
        ),
        NavigationDestination(
          icon: Icon(Icons.backup),
          label: 'Backups',
        ),
        NavigationDestination(
          icon: Icon(Icons.lan),
          label: 'Network',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings_power),
          label: 'Startup',
        ),
        NavigationDestination(
          icon: Icon(Icons.settings),
          label: 'Settings',
        ),
        NavigationDestination(
          icon: Icon(Icons.timeline),
          label: 'Activity',
        ),
      ],
    );
  }
  // Update the _buildCurrentTab switch statement
  Widget _buildCurrentTab() {
    if (isLoading) return Center(child: CircularProgressIndicator());

    switch (_selectedTabIndex) {
      case 0: return _buildConsoleTab();
      case 1: return _buildFilesTab();
      case 2: return _buildDatabasesTab();
      case 3: return _buildSchedulesTab();
      case 4: return _buildUsersTab();
      case 5: return _buildBackupsTab();
      case 6: return _buildNetworkTab();
      case 7: return _buildStartupTab();
      case 8: return _buildSettingsTab();
      case 9: return _buildActivityTab();
      default: return _buildConsoleTab();
    }
  }

  Widget _buildConsoleTab() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Row(
        children: [
          Expanded(
            flex: 3,
            child: Column(
              children: [
                Expanded(
                  child: Container(
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: Colors.black87,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade700),
                    ),
                    padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Scrollbar(
                      controller: _scrollController,
                      thumbVisibility: true,
                      child: SingleChildScrollView(
                        controller: _scrollController,
                        child: SelectableText(
                          consoleMessages.join("\n"),
                          style: TextStyle(
                            color: Colors.white,
                            fontFamily: 'monospace',
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(8.0),
                  child: Shortcuts(
                    shortcuts: {
                       LogicalKeySet(LogicalKeyboardKey.arrowUp): _HistoryUpIntent(),
                       LogicalKeySet(LogicalKeyboardKey.arrowDown):  _HistoryDownIntent(),
                    },
                    child: Actions(
                      actions: {
                        _HistoryUpIntent: CallbackAction<_HistoryUpIntent>(
                          onInvoke: (_) => _navigateHistory(-1),
                        ),
                        _HistoryDownIntent: CallbackAction<_HistoryDownIntent>(
                          onInvoke: (_) => _navigateHistory(1),
                        ),
                      },
                      child: TextField(
                        controller: _commandController,
                        onSubmitted: (cmd) {
                          sendCommand(cmd);
                          _historyIndex = _commandHistory.length;
                        },
                        style: TextStyle(fontFamily: 'monospace'),
                        decoration: InputDecoration(
                          labelText: "Enter Command",
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),

                ),
              ],
            ),
          ),
          SizedBox(width: 8),
          Container(
            width: 250,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ElevatedButton(
                      onPressed: powerStart,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.blue,
                      ),
                      child: Text("Start"),
                    ),
                    ElevatedButton(
                      onPressed: powerRestart,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.grey,
                      ),
                      child: Text("Restart"),
                    ),
                    ElevatedButton(
                      onPressed: powerStop,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: Text("Stop"),
                    ),
                  ],
                ),
                SizedBox(height: 16),
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "CPU: ${cpuUsage.toStringAsFixed(1)}% / 100%",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "RAM: ${memUsageMB < 1000 ? memUsageMB.toStringAsFixed(0) + ' MB' : (memUsageMB / 1024).toStringAsFixed(1) + ' GB'} / " +
                        "${memLimitMB < 1000 ? memLimitMB.toStringAsFixed(0) + ' MB' : (memLimitMB / 1024).toStringAsFixed(1) + ' GB'}",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
                SizedBox(height: 8),
                Container(
                  padding: EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade900,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    "Uptime: ${formatUptime(uptimeSeconds)}",
                    style: TextStyle(color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

// Add placeholder methods for files and databases tabs
  Widget _buildFilesTab() {
    return Center(
      child: Text("File Manager - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildDatabasesTab() {
    return Center(
      child: Text("Database Manager - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  // Add these placeholder methods to _ServerPageState class
  Widget _buildSchedulesTab() {
    return Center(
      child: Text("Schedules Manager - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildUsersTab() {
    return Center(
      child: Text("User Management - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildBackupsTab() {
    return Center(
      child: Text("Backup System - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildNetworkTab() {
    return Center(
      child: Text("Network Configuration - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildStartupTab() {
    return Center(
      child: Text("Startup Parameters - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildSettingsTab() {
    return Center(
      child: Text("Server Settings - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  Widget _buildActivityTab() {
    return Center(
      child: Text("Activity Monitoring - Implementation Pending",
          style: TextStyle(fontSize: 18)),
    );
  }

  void _navigateHistory(int direction) {
    if (_commandHistory.isEmpty) return;

    setState(() {
      _historyIndex = (_historyIndex + direction).clamp(0, _commandHistory.length);

      if (_historyIndex < _commandHistory.length) {
        _commandController.text = _commandHistory[_historyIndex];
        _commandController.selection = TextSelection.collapsed(
          offset: _commandController.text.length,
        );
      }
    });
  }




}
class _HistoryUpIntent extends Intent {}
class _HistoryDownIntent extends Intent {}