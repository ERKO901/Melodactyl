import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;
import 'dart:convert';
import 'dashboard.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pterodactyl Client',
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: Color(0xFF121212), // Darker background
        primaryColor: Color(0xFF1F1F1F), // Primary color for AppBar
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Color(0xFFBB86FC), // Button color
            foregroundColor: Colors.white, // Text color
          ),
        ),

        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Color(0xFF1E1E1E), // Input field background color
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8.0),
            borderSide: BorderSide.none,
          ),
          labelStyle: TextStyle(color: Colors.white70),
        ),
      ),
      home: FutureBuilder<bool>(
        future: checkSavedCredentials(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            // Show a loading indicator until the check is complete.
            return Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          } else {
            // If credentials exist and are valid, go to DashboardPage.
            if (snapshot.data == true) {
              return DashboardPage();
            } else {
              // Otherwise, force the user to log in.
              return ApiKeyInputPage();
            }
          }
        },
      ),

    );
  }
  Future<bool> checkSavedCredentials() async {
    SharedPreferences prefs = await SharedPreferences.getInstance();
    String? savedUrl = prefs.getString('panel_url');
    String? savedApiKey = prefs.getString('api_key');

    // If either is missing, return false to force a login.
    if (savedUrl == null || savedApiKey == null) return false;

    // Validate by making a test request.
    try {
      final response = await http.get(
        Uri.parse('$savedUrl/api/client/account'),
        headers: {
          'Authorization': 'Bearer $savedApiKey',
          'Accept': 'application/json',
        },
      );
      // Credentials are valid if the status code is 200.
      return response.statusCode == 200;
    } catch (e) {
      return false;
    }
  }
}

class ApiKeyInputPage extends StatefulWidget {
  @override
  _ApiKeyInputPageState createState() => _ApiKeyInputPageState();
}

class _ApiKeyInputPageState extends State<ApiKeyInputPage> {
  final TextEditingController urlController = TextEditingController();
  final TextEditingController apiKeyController = TextEditingController();
  bool isLoading = false;




  Future<void> validateAndSave() async {
    setState(() {
      isLoading = true;
    });

    try {
      // Validate API key by making a test request
      final response = await http.get(
        Uri.parse('${urlController.text}/api/client/account'),
        headers: {'Authorization': 'Bearer ${apiKeyController.text}'},
      );

      if (response.statusCode == 200) {
        // Save URL and API key in shared preferences
        SharedPreferences prefs = await SharedPreferences.getInstance();
        await prefs.setString('panel_url', urlController.text);
        await prefs.setString('api_key', apiKeyController.text);

        // Navigate to dashboard
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (context) => DashboardPage()),
        );
      } else {
        showError('Invalid URL or API Key');
      }
    } catch (e) {
      showError('Failed to connect to the server. Please check your inputs.');
    } finally {
      setState(() {
        isLoading = false;
      });
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Melodactyl')),
      body: Center(
        child: Container(
          width: 400, // Max width of the form
          height: 300, // Max height of the form
          padding: const EdgeInsets.all(16.0),
          decoration: BoxDecoration(
            color: Color(0xFF1F1F1F), // Form background color (lighter than page)
            borderRadius: BorderRadius.circular(12.0),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.5),
                blurRadius: 8,
                offset: Offset(2, 2),
              ),
            ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Title above the text fields
              Text(
                'Enter Panel Details',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Colors.white),
              ),
              SizedBox(height: 20), // Space between title and text fields
              TextField(
                controller: urlController,
                decoration:
                InputDecoration(labelText: 'Panel URL (e.g., https://panel.example.com)'),
                style: TextStyle(color: Colors.white),
              ),
              SizedBox(height: 10),
              TextField(
                controller: apiKeyController,
                decoration:
                InputDecoration(labelText: 'API Key'),
                obscureText: true,
                style: TextStyle(color: Colors.white),
              ),
              SizedBox(height: 20),
              ElevatedButton(
                onPressed: isLoading ? null : validateAndSave,
                child:
                isLoading ? CircularProgressIndicator(color: Colors.white) : Text('Login'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
