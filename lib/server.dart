import 'dart:async';
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'; // For Clipboard
import 'package:http/http.dart' as http;
import 'package:web_socket_channel/io.dart';
import 'package:flutter/services.dart';  // For Shortcuts/Keyboard handling
import 'package:flutter/widgets.dart';    // For Intent/Actions classes
import 'package:file_picker/file_picker.dart';
import 'dart:io';

class Stack<E> {
  final List<E> _storage = [];

  void push(E element) => _storage.add(element);
  E pop() => _storage.removeLast();
  E get peek => _storage.last;
  bool get isEmpty => _storage.isEmpty;
  bool get isNotEmpty => _storage.isNotEmpty;
}



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
  String serverState = "running";


  bool _isUploading = false;
  double _uploadProgress = 0.0;

  // API configuration loaded from SharedPreferences.
  late String panelUrl;
  late String apiKey;


  final TextEditingController _commandController = TextEditingController();
  List<String> _commandHistory = [];
  int _historyIndex = -1;

  List<dynamic> _filesList = [];

  String _currentPath = "/";
  final Stack _navigationStack = Stack();
  bool _isLoadingFiles = false;

  Future<void> fetchFiles({String directory = "/"}) async {
    try {
      setState(() => _isLoadingFiles = true);
      final cleanPanelUrl = panelUrl.replaceAll(RegExp(r'/$'), '');
      final shortServerId = widget.serverId.substring(0, 8);
      final encodedDir = Uri.encodeComponent(directory);

      final response = await http.get(
        Uri.parse(
            "https://$cleanPanelUrl/api/client/servers/$shortServerId/files/list?directory=$encodedDir"
        ),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        // Sort files: folders first, then files, alphabetically within each group
        final sortedList = (data['data'] as List)
          ..sort((a, b) {
            // First sort by type (folders before files)
            final isFileA = a['attributes']['is_file'];
            final isFileB = b['attributes']['is_file'];
            if (isFileA != isFileB) return isFileA ? 1 : -1;

            // Then sort alphabetically by name
            return a['attributes']['name']
                .toLowerCase()
                .compareTo(b['attributes']['name'].toLowerCase());
          });

        setState(() => _filesList = sortedList);
      } else {
        // Handle error cases
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("Error: $e"))
      );
    } finally {
      setState(() => _isLoadingFiles = false);
    }
  }

  void _createFolder() async {
    final TextEditingController _folderNameController = TextEditingController();

    final folderName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Create New Folder'),
        content: TextField(
          controller: _folderNameController,  // Add controller
          autofocus: true,
          decoration: InputDecoration(
            hintText: 'Enter folder name',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, _folderNameController.text);  // Get text from controller
            },
            child: Text('Create'),
          ),
        ],
      ),
    );

    if (folderName != null && folderName.isNotEmpty) {
      try {
        final cleanPanelUrl = panelUrl.replaceAll(RegExp(r'/$'), '');
        final shortServerId = widget.serverId.substring(0, 8);

        final response = await http.post(
          Uri.parse(
            "https://$cleanPanelUrl/api/client/servers/$shortServerId/files/create-folder",
          ),
          headers: {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode({
            'root': _currentPath,
            'name': folderName,
          }),
        );

        if (response.statusCode == 204) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Folder created successfully!')),
          );
          fetchFiles(directory: _currentPath);
        } else {
          final error = jsonDecode(response.body)['errors'][0]['detail'];
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Error: $error')),
          );
        }
      } catch (e) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: ${e.toString()}')),
        );
      }
    }
  }



  Future<void> _uploadFiles(List<PlatformFile> files) async {
    try {
      setState(() {
        _isUploading = true;
        _uploadProgress = 0.0;
      });

      // Validate files first
      if (files.isEmpty) throw Exception("No files selected");

      debugPrint('Starting upload of ${files.length} files:');
      files.forEach((file) => debugPrint('- ${file.name}'));

      final cleanPanelUrl = panelUrl.replaceAll(RegExp(r'/$'), '');
      final shortServerId = widget.serverId.substring(0, 8);
      final encodedDir = Uri.encodeComponent(_currentPath);

      // Get upload URL
      final uploadResponse = await http.get(
        Uri.parse(
            "https://$cleanPanelUrl/api/client/servers/$shortServerId/files/upload?directory=$encodedDir"
        ),
        headers: {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
      ).timeout(const Duration(seconds: 30));

      debugPrint('Upload URL response: ${uploadResponse.statusCode}');
      debugPrint('Response body: ${uploadResponse.body}');

      if (uploadResponse.statusCode != 200) {
        final errorBody = jsonDecode(uploadResponse.body) ?? {};
        final errorMessage = errorBody['errors']?[0]['detail'] ?? 'Unknown error';
        throw Exception("Failed to get upload URL ($errorMessage)");
      }

      final uploadData = jsonDecode(uploadResponse.body) as Map<String, dynamic>;

      // Handle new API response structure
      if (uploadData['object'] != 'signed_url' ||
          uploadData['attributes']?['url'] == null) {
        throw Exception("Invalid API response format - missing upload URL");
      }

      final uploadUrl = uploadData['attributes']['url'] as String;
      debugPrint('Upload URL: $uploadUrl');

      // Upload files with progress tracking
      final List<String> uploadErrors = [];
      for (int i = 0; i < files.length; i++) {
        final file = files[i];
        try {
          debugPrint('Uploading: ${file.name} '
              '(${((file.size ?? 0) / 1024 / 1024).toStringAsFixed(2)} MB)');

          final request = http.MultipartRequest('POST', Uri.parse(uploadUrl))
            ..fields['root'] = _currentPath
            ..files.add(http.MultipartFile.fromBytes(
              'files',
              file.bytes!,
              filename: file.name,
            ));

          final response = await request.send();
          final statusCode = response.statusCode;

          debugPrint('Upload status for ${file.name}: $statusCode');

          if (statusCode != 200) {
            final errorResponse = await response.stream.bytesToString();
            uploadErrors.add("${file.name}: Server rejected upload ($statusCode)");
            debugPrint('Upload error response: $errorResponse');
          }

          setState(() {
            _uploadProgress = (i + 1) / files.length;
            debugPrint('Upload progress: ${(_uploadProgress * 100).toStringAsFixed(1)}%');
          });

        } catch (e) {
          debugPrint('Error uploading ${file.name}: ${e.toString()}');
          uploadErrors.add("${file.name}: ${e.toString()}");
        }
      }

      if (uploadErrors.isNotEmpty) {
        throw Exception("Some files failed to upload:\n${uploadErrors.join('\n')}");
      }

      debugPrint('All files uploaded successfully!');
      fetchFiles(directory: _currentPath);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${files.length} file${files.length > 1 ? 's' : ''} uploaded successfully!'),
          backgroundColor: Colors.green,
        ),
      );

    } on SocketException catch (e) {
      _showErrorDialog('Network error: ${e.message}');
    } on TimeoutException catch (e) {
      _showErrorDialog('Request timed out: ${e.message}');
    } on http.ClientException catch (e) {
      _showErrorDialog('Connection error: ${e.message}');
    } on PlatformException catch (e) {
      _showErrorDialog('File system error: ${e.message}');
    } catch (e) {
      _showErrorDialog(e.toString());
    } finally {
      setState(() => _isUploading = false);
    }
  }

  void _showErrorDialog(String message) {
    debugPrint('Upload Error: $message');
    ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: Colors.red,
          duration: Duration(seconds: 5),
        )
    );
  }




  void _handleFilePicker() async {
    final result = await FilePicker.platform.pickFiles(
      allowMultiple: true,
      withData: true,
    );

    if (result != null && result.files.isNotEmpty) {
      _uploadFiles(result.files);
    }
  }


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
      fetchFiles(); // Initial file fetch
    });
    // If Console is the default tab, scroll to its bottom after the first frame.
    if (_selectedTabIndex == 0) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        Future.delayed(Duration(milliseconds: 100), () {
          if (_scrollController.hasClients) {
            _scrollController.animateTo(
              _scrollController.position.maxScrollExtent,
              duration: Duration(milliseconds: 300),
              curve: Curves.easeOut,
            );
          }
        });
      });
    }
  }



  // Remove ANSI escape codes from a string.
  String stripAnsiCodes(String input) {
    final ansiRegex = RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]');
    return input.replaceAll(ansiRegex, '');
  }

  // Format uptime (in seconds) into "xd xh xm xs".
  String formatUptime(int seconds) {
    int totalSeconds = seconds ~/ 1000;  // Convert ms to seconds
    int days = totalSeconds ~/ (3600 * 24);
    int hours = (totalSeconds % (3600 * 24)) ~/ 3600;
    int minutes = (totalSeconds % 3600) ~/ 60;
    int secs = totalSeconds % 60;
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

      if (response.statusCode != 200) {
        throw Exception(
            "Failed to fetch WebSocket URL: ${response.statusCode} ${response.reasonPhrase}");
      }

      final data = jsonDecode(response.body);
      token = data['data']['token'] ?? '';
      final rawSocketUrl = data['data']['socket'] ?? '';

      if (rawSocketUrl.isEmpty || token!.isEmpty) {
        throw Exception("WebSocket URL or token is empty or invalid.");
      }

      String wsUrl = "$rawSocketUrl?token=$token";
      if (wsUrl.startsWith("https://")) {
        wsUrl = wsUrl.replaceFirst("https://", "wss://");
      } else if (wsUrl.startsWith("http://")) {
        wsUrl = wsUrl.replaceFirst("http://", "ws://");
      }

      print("Connecting to WebSocket: $wsUrl");
      channel = IOWebSocketChannel.connect(Uri.parse(wsUrl), headers: {
        "Origin": "https://$cleanPanelUrl",
      });

      // Updated message handling
      channel!.stream.listen(
            (message) {
          print("WebSocket Message Received: $message");
          try {
            var decodedMsg = jsonDecode(message);
            if (decodedMsg is Map && decodedMsg["event"] != null) {
              var evt = decodedMsg["event"];
              var args = decodedMsg["args"];

              switch (evt) {
                case "auth success":
                // Immediately request logs after successful auth
                  channel!.sink.add(jsonEncode({
                    "event": "send logs",
                    "args": [null]
                  }));
                  break;

                case "send logs": // Changed from "init logs"
                  logsTimeout?.cancel();
                  if (args is List && args.isNotEmpty) {
                    final logs = args[0] as List;
                    setState(() {
                      consoleMessages.addAll(
                          logs.map((line) => stripAnsiCodes(line.toString()))
                      );
                    });
                  }
                  break;

                case "console output":
                  if (args is List && args.isNotEmpty) {
                    addConsoleMessage(args[0].toString());
                  }
                  break;

                case "stats":
                  try {
                    var stats = jsonDecode(args[0].toString());
                    if (mounted) {
                      setState(() {
                        cpuUsage = (stats["cpu_absolute"] ?? 0);
                        memUsageMB = (stats["memory_bytes"] ?? 0) / (1024 * 1024);
                        memLimitMB = (stats["memory_limit_bytes"] ?? 0) / (1024 * 1024);
                        uptimeSeconds = stats["uptime"] ?? 0;
                        // Save the state from stats (e.g.: "running", "stopping", etc.)
                        serverState = stats["state"] ?? "running";
                      });
                    }
                  } catch (e) {
                    print("Stats parsing error: $e");
                  }
                  break;


                case "token expiring":
                  renewAuthToken();
                  break;

                case "token expired":
                  addConsoleMessage("Token has expired. Reconnecting...");
                  reconnectWebSocket();
                  break;

                default:

              }
            }
          } catch (e) {
            addConsoleMessage("Message processing error: $e");
          }
        },
        onError: (error) {
          print("WebSocket Error: $error");
          showErrorDialog("WebSocket Error: $error");
        },
        onDone: () {
          print("WebSocket connection closed.");
          showErrorDialog("Connection closed. Reconnecting...");
          scheduleReconnect();
        },
      );

      // Initial auth handshake
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
      print("WebSocket initialization failed: $e");
      showErrorDialog("Connection failed: ${e.toString()}");
    }
  }

  void renewAuthToken() async {
    try {
      final response = await http.get(
        Uri.parse("https://${panelUrl.replaceAll(RegExp(r'/$'), '')}/api/client/servers/${widget.serverId.substring(0, 8)}/websocket"),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode == 200) {
        final newData = jsonDecode(response.body);
        token = newData['data']['token'];
        channel!.sink.add(jsonEncode({
          "event": "auth",
          "args": [token]
        }));
      }
    } catch (e) {
      print("Token renewal failed: $e");
    }
  }

  void scheduleReconnect() {
    if (!mounted) return;
    Future.delayed(Duration(seconds: 5), () {
      if (mounted) initializeWebSocket();
    });
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

  void addConsoleMessage(String message) {
    final cleanMessage = stripAnsiCodes(message);
    if (!mounted) return;
    setState(() {
      consoleMessages.add(cleanMessage);
    });
    // After the frame builds, scroll to the bottom
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
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

  void powerKill() {
    sendPowerSignal("kill");
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
        backgroundColor: Color(0xFF121212),
        // Disable the default Material 3 surface tint effect:
        surfaceTintColor: Colors.transparent,
        // Remove the change in elevation when scrolled under:
        scrolledUnderElevation: 0,
        title: _buildNavigationBar(),
      ),
      body: _buildCurrentTab(),
    );
}


// Update the _buildNavigationBar method
  Widget _buildNavigationBar() {
    return NavigationBar(
      selectedIndex: _selectedTabIndex,
      onDestinationSelected: (index) {
        setState(() {
          _selectedTabIndex = index;
        });
        if (index == 0) { // When Console tab is selected
          WidgetsBinding.instance.addPostFrameCallback((_) {
            Future.delayed(Duration(milliseconds: 100), () {
              if (_scrollController.hasClients) {
                _scrollController.animateTo(
                  _scrollController.position.maxScrollExtent,
                  duration: Duration(milliseconds: 300),
                  curve: Curves.easeOut,
                );
              }
            });
          });
        }
      },
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
                      LogicalKeySet(LogicalKeyboardKey.arrowDown): _HistoryDownIntent(),
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
                      onPressed: () async {
                        if (serverState == "stopping") {
                          // Show confirmation dialog before sending kill
                          bool? confirmed = await showDialog<bool>(
                            context: context,
                            barrierDismissible: false,
                            builder: (context) {
                              return AlertDialog(
                                title: Text("Confirm Kill"),
                                content: Text("Are you sure you want to kill the server?"),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(false),
                                    child: Text("Cancel"),
                                  ),
                                  TextButton(
                                    onPressed: () => Navigator.of(context).pop(true),
                                    child: Text("Kill"),
                                  ),
                                ],
                              );
                            },
                          );
                          if (confirmed == true) {
                            powerKill();
                          }
                        } else {
                          powerStop();
                        }
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.red,
                      ),
                      child: Text(serverState == "stopping" ? "Kill" : "Stop"),
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


// Update the _buildFilesTab method
  Widget _buildFilesTab() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 4.0),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Existing path navigation
              Expanded(
                child: Row(
                  children: [
                    if (_currentPath != "/")
                      IconButton(
                        icon: Icon(Icons.arrow_back),
                        onPressed: () {
                          if (_navigationStack.isNotEmpty) {
                            setState(() {
                              _currentPath = _navigationStack.pop();
                            });
                            fetchFiles(directory: _currentPath);
                          }
                        },
                      ),
                    Expanded(
                      child: Text(
                        "Path: $_currentPath",
                        style: TextStyle(fontSize: 16),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              // New action buttons
              Container(
                decoration: BoxDecoration(
                  color: Colors.transparent, // Transparent background
                  borderRadius: BorderRadius.circular(8),
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      _buildActionButton(
                        onPressed: _createFolder,
                        icon: Icons.create_new_folder,
                        label: 'Create Folder',
                        color: Colors.grey,
                        textColor: Colors.white,

                      ),
                      SizedBox(width: 8),
                      _buildActionButton(
                        onPressed: _handleFilePicker,
                        icon: Icons.upload_file,
                        label: 'Upload File',
                        color: Colors.blue,
                        textColor: Colors.white,
                      ),
                      SizedBox(width: 8),
                      _buildActionButton(
                        onPressed: _createFolder,
                        icon: Icons.insert_drive_file,
                        label: 'New File',
                        color: Colors.blue,
                        textColor: Colors.white,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _isLoadingFiles
              ? Center(child: CircularProgressIndicator())
              : ListView.builder(
            itemCount: _filesList.length,
            itemBuilder: (context, index) {
              final file = _filesList[index];
              return ListTile(
                leading: Icon(
                  file['attributes']['is_file']
                      ? Icons.insert_drive_file
                      : Icons.folder,
                  color: file['attributes']['is_file']
                      ? Colors.blue
                      : Colors.amber,
                ),
                title: Text(file['attributes']['name']),
                subtitle: file['attributes']['is_file']
                    ? Text(
                    "${(file['attributes']['size'] / 1024).toStringAsFixed(2)} KB")
                    : null,
                onTap: () {
                  if (!file['attributes']['is_file']) {
                    _navigationStack.push(_currentPath);
                    final currentUri = Uri.parse(_currentPath);
                    List<String> newSegments = [
                      ...currentUri.pathSegments,
                      file['attributes']['name'].toString()
                    ];
                    setState(() {
                      _currentPath = Uri(pathSegments: newSegments).path;
                    });
                    fetchFiles(directory: _currentPath);
                  }
                },
              );
            },
          ),
        ),
      ],
    );
  }

  // Update the _buildActionButton widget definition
  Widget _buildActionButton({
    required IconData icon,
    required String label,
    required Color color,
    required Color textColor,
    required VoidCallback onPressed, // Add this parameter
  }) {
    return Container(
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(8),
      ),
      child: TextButton.icon(
        style: TextButton.styleFrom(
          foregroundColor: textColor,
          padding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        ),
        onPressed: onPressed, // Use the provided callback
        icon: Icon(icon, size: 20),
        label: Text(label),
      ),
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