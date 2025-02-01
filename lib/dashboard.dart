import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'main.dart';
import 'dart:async';
import 'server.dart';
class DashboardPage extends StatefulWidget {
  @override
  _DashboardPageState createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  List servers = [];
  bool isLoading = true;
  String currentView = 'dashboard'; // Tracks which view to display
  Timer? fetchTimer;

  Map<String, dynamic>? selectedServer; // Holds data for the selected server


  @override
  void initState() {
    super.initState();
    fetchServers(); // Fetch servers immediately on load

    // Set up a timer to fetch servers every 4 seconds
    fetchTimer = Timer.periodic(Duration(seconds: 4), (timer) {
      fetchServers();
    });
  }

  @override
  void dispose() {
    // Cancel the timer when the widget is disposed
    fetchTimer?.cancel();
    super.dispose();
  }

  Future<Map<String, dynamic>> fetchServerResources(String uuid) async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? panelUrl = prefs.getString('panel_url');
    String? apiKey = prefs.getString('api_key');

    if (panelUrl == null || apiKey == null) {
      showError('Panel URL or API Key not found. Please set them up again.');
      return {};
    }

    try {
      final response = await http.get(
        Uri.parse('$panelUrl/api/client/servers/$uuid/resources'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body)['attributes'];
        final resources = data['resources'];
        return {
          'current_state': data['current_state'] ?? 'Unknown', // Add current state
          'cpu_usage': resources['cpu_absolute'] ?? 0,
          'memory_usage': (resources['memory_bytes'] / (1024 * 1024)).toStringAsFixed(2), // Convert bytes to MB
          'disk_usage': (resources['disk_bytes'] / (1024 * 1024)).toStringAsFixed(2), // Convert bytes to MB
        };
      } else {
        showError('Failed to fetch resources for server $uuid.');
        return {};
      }
    } catch (e) {
      showError('Failed to connect to the server.');
      return {};
    }
  }



  Future<void> fetchServers() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? panelUrl = prefs.getString('panel_url');
    String? apiKey = prefs.getString('api_key');

    if (panelUrl == null || apiKey == null) {
      showError('Panel URL or API Key not found. Please set them up again.');
      return;
    }

    try {
      final response = await http.get(
        Uri.parse('$panelUrl/api/client'),
        headers: {'Authorization': 'Bearer $apiKey'},
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body)['data'];

        setState(() {
          for (var serverData in data) {
            final attributes = serverData['attributes'];
            final uuid = attributes['uuid'];

            // Find existing server by UUID
            final existingServerIndex =
            servers.indexWhere((server) => server['uuid'] == uuid);

            if (existingServerIndex != -1) {
              // Update existing server data
              servers[existingServerIndex]['cpu'] =
                  attributes['limits']['cpu']?.toString() ?? 'N/A';
              servers[existingServerIndex]['memory'] =
                  attributes['limits']['memory']?.toString() ?? 'N/A';
              servers[existingServerIndex]['disk'] =
                  attributes['limits']['disk']?.toString() ?? 'N/A';
            } else {
              // Add new server if it doesn't exist
              final allocation = attributes['relationships']['allocations']['data']
                  .firstWhere(
                    (alloc) => alloc['attributes']['is_default'] == true,
                orElse: () => null,
              )?['attributes'];

              servers.add({
                'uuid': uuid,
                'name': attributes['name'] ?? 'Unknown Server',
                'description': attributes['description'] ?? 'No description available',
                'cpu': attributes['limits']['cpu']?.toString() ?? 'N/A',
                'memory': attributes['limits']['memory']?.toString() ?? 'N/A',
                'disk': attributes['limits']['disk']?.toString() ?? 'N/A',
                'ip': allocation?['ip'] ?? 'carrot.melonhost.cz', // Replace IP with hardcoded value
                'port': allocation?['port']?.toString() ?? 'N/A',
                // Placeholder for resource usage and state
                'current_state': '-',
                'cpu_usage': '-',
                'memory_usage': '-',
                'disk_usage': '-',
              });
            }
          }
        });

        // Fetch resources for each server after loading basic details
        for (int i = 0; i < servers.length; i++) {
          final uuid = servers[i]['uuid'];
          final resources = await fetchServerResources(uuid);
          setState(() {
            servers[i]['current_state'] = resources['current_state'];
            servers[i]['cpu_usage'] = resources['cpu_usage'];
            servers[i]['memory_usage'] = resources['memory_usage'];
            servers[i]['disk_usage'] = resources['disk_usage'];
          });
        }
      } else {
        showError('Failed to fetch servers. Please check your API Key.');
      }
    } catch (e) {
      showError('Failed to connect to the server.');
    }
  }







  Future<void> logout() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove('panel_url');
    await prefs.remove('api_key');

    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (context) => MyApp()),
    );
  }

  void showError(String message) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Error'),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget buildSidebar({bool isDesktop = false}) {
    return Container(
      width: isDesktop ? 70 : null, // Narrow sidebar for desktop
      color: Color(0xFF1F1F1F), // Sidebar background color
      child: ListView(
        padding: EdgeInsets.zero,
        children: [
          if (!isDesktop)
            DrawerHeader(
              decoration: BoxDecoration(color: Color(0xFFBB86FC)), // Header background color
              child: Center(
                child: Text(
                  'Melodactyl',
                  style: TextStyle(fontSize: 24, color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          IconButton(
            icon: Icon(Icons.dashboard, color: Colors.white),
            tooltip: isDesktop ? "Dashboard" : null,
            onPressed: () {
              setState(() {
                currentView = 'dashboard';
              });
              if (!isDesktop) Navigator.pop(context); // Close drawer on mobile
            },
          ),
          IconButton(
            icon: Icon(Icons.account_circle, color: Colors.white),
            tooltip: isDesktop ? "Account Details" : null,
            onPressed: () {
              setState(() {
                currentView = 'account';
              });
              if (!isDesktop) Navigator.pop(context); // Close drawer on mobile
            },
          ),
          IconButton(
            icon: Icon(Icons.logout, color: Colors.white),
            tooltip: isDesktop ? "Logout" : null,
            onPressed: logout,
          ),
        ],
      ),
    );
  }

  Widget buildDashboardView() {
    return GridView.builder(
      gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 400, // Maximum width of each grid item
        mainAxisExtent: 200, // Fixed height of each grid item
        crossAxisSpacing: 8, // Spacing between columns
        mainAxisSpacing: 8, // Spacing between rows
      ),
      itemCount: servers.length,
      itemBuilder: (context, index) {
        final server = servers[index];

        // Determine the border color based on the server's current state
        Color borderColor;
        switch (server['current_state']) {
          case 'running':
            borderColor = Colors.green; // Green for running
            break;
          case 'offline':
            borderColor = Colors.red; // Red for offline
            break;
          case 'starting':
          default:
            borderColor = Colors.yellow; // Yellow for starting or other states
            break;
        }

        return GestureDetector(
          onTap: () {
            setState(() {
              currentView = 'serverPage';
              selectedServer = server;
            });
          },


          child: Container(
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12), // Rounded corners
            ),
            margin: EdgeInsets.all(8), // Margin around each card
            child: Row(
              children: [
                // Left colored border
                Container(
                  width: 5, // Width of the left border
                  decoration: BoxDecoration(
                    color: borderColor,
                    borderRadius: BorderRadius.only(
                      topLeft: Radius.circular(12), // Match card's rounded corners
                      bottomLeft: Radius.circular(12),
                    ),
                  ),
                ),
                Expanded(
                  child: Card(
                    elevation: 4,
                    shape: RoundedRectangleBorder(
                      borderRadius:
                      BorderRadius.circular(12), // Match container's rounded corners
                    ),
                    child: Padding(
                      padding: const EdgeInsets.all(16.0),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(server['name'],
                              style:
                              TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                          SizedBox(height: 6), // Reduced space between title and details
                          Text(server['description'],
                              style:
                              TextStyle(fontSize: 14, color: Color(0xFF808080))),
                          SizedBox(height: 4), // Reduced space between details lines
                          Text('CPU Usage: ${server['cpu_usage']}% / ${server['cpu']}%',
                              style:
                              TextStyle(fontSize: 14, color: Color(0xFF808080))),
                          Text('RAM Usage: ${server['memory_usage']} MB / ${server['memory']} MB',
                              style:
                              TextStyle(fontSize: 14, color: Color(0xFF808080))),
                          Text('Disk Usage: ${server['disk_usage']} MB / ${server['disk']} MB',
                              style:
                              TextStyle(fontSize: 14, color: Color(0xFF808080))),
                          Text('IP: carrot.melonhost.cz:${server['port']}',
                              style:
                              TextStyle(fontSize: 14, color: Color(0xFF808080))),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }



  Widget buildServerPageView() {
    if (selectedServer == null) return SizedBox.shrink();

    return ServerPage(serverId: selectedServer!['uuid']);
  }



  Widget buildAccountDetailsView() {
    return Center(
      child: Text(
        'Account Details View\n(You can implement this later)',
        textAlign: TextAlign.center,
        style: TextStyle(fontSize: 18, color: Colors.white70),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    bool isDesktop = MediaQuery.of(context).size.width > 600;

    return Scaffold(
      appBar: AppBar(title: Text('Melodactyl Dashboard')), // AppBar always visible on top


      body: Row(
        children: [
          if (isDesktop)
            buildSidebar(isDesktop: true), // Sidebar always visible for desktop
          Expanded(
            child: currentView == 'dashboard'
                ? buildDashboardView()
                : currentView == 'serverPage'
                ? buildServerPageView()
                : buildAccountDetailsView(),


          ),
        ],
      ),


      drawer: isDesktop ? null : Drawer(child: buildSidebar()), // Drawer only for mobile devices

    );
  }
}
