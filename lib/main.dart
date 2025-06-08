import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:http/http.dart' as http;
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:audio/audio.dart';

import 'chat_card.dart';
import 'evi_message.dart' as evi;
import 'pinecone_service.dart';
import 'hume_tts_service.dart';

class ConfigManager {
  static final ConfigManager _instance = ConfigManager._internal();

  String humeApiKey = "";
  String humeAccessToken = "";
  late final String humeConfigId;
  
  // Pinecone configuration
  late final String pineconeApiKey;
  late final String pineconeAssistantName;
  late final String pineconeBaseUrl;

  ConfigManager._internal();

  static ConfigManager get instance => _instance;

  // WARNING! For development only. In production, the app should hit your own backend server to get an access token, using "token authentication" (see https://dev.hume.ai/docs/introduction/api-key#token-authentication)
  String fetchHumeApiKey() {
    return dotenv.env['HUME_API_KEY'] ?? "";
  }

  Future<String> fetchAccessToken() async {
    // Make a get request to dotenv.env['MY_SERVER_URL'] to get the access token
    final authUrl = dotenv.env['MY_SERVER_AUTH_URL'];
    if (authUrl == null) {
      throw Exception('Please set MY_SERVER_AUTH_URL in your .env file');
    }
    final url = Uri.parse(authUrl);
    final response = await http.get(url);
    if (response.statusCode == 200) {
      return jsonDecode(response.body)['access_token'];
    } else {
      throw Exception('Failed to load access token');
    }
  }

  Future<void> loadConfig() async {
    // Make sure to create a .env file in your root directory which mirrors the .env.example file
    // and add your API key and an optional EVI config ID.
    await dotenv.load();

    // WARNING! For development only.
    humeApiKey = fetchHumeApiKey();

    // Uncomment this to use an access token in production.
    // humeAccessToken = await fetchAccessToken();
    humeConfigId = dotenv.env['HUME_CONFIG_ID'] ?? '';
    
    // Load Pinecone configuration
    pineconeApiKey = dotenv.env['PINECONE_API_KEY'] ?? '';
    pineconeAssistantName = dotenv.env['PINECONE_ASSISTANT_NAME'] ?? 'tes';
    pineconeBaseUrl = dotenv.env['PINECONE_BASE_URL'] ?? 'https://prod-1-data.ke.pinecone.io';
  }
}

void main() async {
  // Ensure Flutter binding is initialized before calling asynchronous operations
  WidgetsFlutterBinding.ensureInitialized();

  // Load config in singleton
  await ConfigManager.instance.loadConfig();

  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    if (ConfigManager.instance.humeApiKey.isEmpty &&
        ConfigManager.instance.humeAccessToken.isEmpty) {
      return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Nissan Voice Assistant',
          home: ErrorMessage(
            message:
                "Error: Please set your Hume API key in .env file",
          ),
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(seedColor: Colors.grey),
          ));
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Nissan Voice Assistant',
      home: const MyHomePage(),
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.grey),
      ),
    );
  }

  static List<Score> extractTopThreeEmotions(evi.Inference models) {
    // extract emotion scores from the message
    final scores = models.prosody?.scores ?? {};

    // convert the emotions object into an array of key-value pairs
    final scoresArray = scores.entries.toList();

    // sort the array by the values in descending order
    scoresArray.sort((a, b) => b.value.compareTo(a.value));

    // extract the top three emotions and convert them back to an object
    final topThreeEmotions = scoresArray.take(3).map((entry) {
      return Score(emotion: entry.key, score: entry.value);
    }).toList();

    return topThreeEmotions;
  }
}

class ErrorMessage extends StatelessWidget {
  final String message;

  const ErrorMessage({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Center(
        child: Text(
          message,
          style: const TextStyle(fontSize: 18, color: Colors.red),
          textAlign: TextAlign.center,
        ),
      ),
    );
  }
}

class MyHomePage extends StatefulWidget {
  const MyHomePage({super.key});

  @override
  State<MyHomePage> createState() => _MyHomePageState();
}

class _MyHomePageState extends State<MyHomePage> {
  final TextEditingController _controller = TextEditingController();
  
  // Hume AI EVI components
  final Audio _audio = Audio();
  WebSocketChannel? _chatChannel;
  bool _isConnected = false;
  bool _isMuted = false;
  var chatEntries = <ChatEntry>[];
  
  // Pinecone service
  late PineconeService _pineconeService;
  late HumeTTSService _ttsService;

  @override
  void initState() {
    super.initState();
    // Initialize Pinecone service
    _pineconeService = PineconeService(
      apiKey: ConfigManager.instance.pineconeApiKey,
      assistantName: ConfigManager.instance.pineconeAssistantName,
      baseUrl: ConfigManager.instance.pineconeBaseUrl,
    );
    
    // Initialize TTS service
    _ttsService = HumeTTSService(
      apiKey: ConfigManager.instance.humeApiKey,
    );
  }

  // EVI sends back transcripts of both the user's speech and the assistants speech, along
  // with an analysis of the emotional content of the speech. This method takes
  // of a message from EVI, parses it into a `ChatMessage` type and adds it to `chatEntries` so
  // it can be displayed.
  void appendNewChatMessage(evi.ChatMessage chatMessage, evi.Inference models) {
    final role = chatMessage.role == 'assistant' ? Role.assistant : Role.user;
    final entry = ChatEntry(
        role: role,
        timestamp: DateTime.now().toString(),
        content: chatMessage.content,
        scores: MyApp.extractTopThreeEmotions(models));
    setState(() {
      chatEntries.add(entry);
    });
  }

  void _onSubmit() async {
    final input = _controller.text.trim();
    if (input.isNotEmpty) {
      // Add user message to chat
      setState(() {
        chatEntries.add(ChatEntry(
          role: Role.user,
          timestamp: DateTime.now().toString(),
          content: input,
          scores: [],
        ));
      });
      
      // Query Pinecone for enhanced responses
      if (ConfigManager.instance.pineconeApiKey.isNotEmpty) {
        // Show loading indicator
        setState(() {
          chatEntries.add(ChatEntry(
            role: Role.assistant,
            timestamp: DateTime.now().toString(),
            content: "🤔 Searching knowledge base...",
            scores: [],
          ));
        });
        
        try {
          final pineconeResponse = await _pineconeService.queryNissanAssistant(input);
          
          // Remove loading message and add Pinecone response
          setState(() {
            chatEntries.removeLast(); // Remove loading message
            if (pineconeResponse != null) {
              chatEntries.add(ChatEntry(
                role: Role.assistant,
                timestamp: DateTime.now().toString(),
                content: "📚 Knowledge Base: $pineconeResponse",
                scores: [],
              ));
            }
          });
          
          // Convert Pinecone response to speech
          if (pineconeResponse != null) {
            _convertToSpeechAndPlay(pineconeResponse);
          }
        } catch (e) {
          setState(() {
            chatEntries.removeLast(); // Remove loading message
            chatEntries.add(ChatEntry(
              role: Role.assistant,
              timestamp: DateTime.now().toString(),
              content: "❌ Could not fetch from knowledge base. Please try again.",
              scores: [],
            ));
          });
        }
      }
      
      // Send to Hume AI if connected
      if (_isConnected && _chatChannel != null) {
        // For text input, we can send it as a message
        _sendTextMessage(input);
      }
      
      _controller.clear();
    }
  }

  void _onEngineOilPressed() {
    final message = "Tell me about engine oil maintenance for my Nissan vehicle.";
    _controller.text = message;
    _onSubmit();
  }

  void _onTirePressurePressed() {
    final message = "What should I know about tire pressure for my Nissan?";
    _controller.text = message;
    _onSubmit();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: Column(
        children: [
          const SizedBox(height: 60),
          Center(
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // Nissan logo
                Image.asset(
                  'nissan-seeklogo.png',
                  height: 100,
                  width: 100,
                ),
                const SizedBox(width: 16),
                // Connection status indicator
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: _isConnected ? Colors.green : Colors.red,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    _isConnected ? 'Connected' : 'Disconnected',
                    style: const TextStyle(color: Colors.white, fontSize: 12),
                  ),
                ),
              ],
            ),
          ),

          // Chat section
          Expanded(
            child: chatEntries.isEmpty
                ? const Center(
                    child: Text(
                      "Ask me anything about your Nissan vehicle!",
                      style: TextStyle(
                        fontSize: 16,
                        color: Colors.grey,
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: chatEntries.length,
                    itemBuilder: (context, index) {
                      final entry = chatEntries[index];
                      final isUser = entry.role == Role.user;
                      return Align(
                        alignment: isUser ? Alignment.centerRight : Alignment.centerLeft,
                        child: Container(
                          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 12),
                          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 14),
                          decoration: BoxDecoration(
                            color: isUser ? Colors.orange : Colors.grey.shade200,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width * 0.7,
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.content,
                                style: TextStyle(
                                  color: isUser ? Colors.white : Colors.black,
                                  fontSize: 16,
                                ),
                              ),
                              // Add speak button for assistant messages
                              if (!isUser && !entry.content.contains("🤔 Searching"))
                                Padding(
                                  padding: const EdgeInsets.only(top: 8.0),
                                  child: InkWell(
                                    onTap: () => _convertToSpeechAndPlay(entry.content),
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.blue.shade100,
                                        borderRadius: BorderRadius.circular(8),
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(Icons.volume_up, size: 16, color: Colors.blue.shade700),
                                          const SizedBox(width: 4),
                                          Text(
                                            "Speak",
                                            style: TextStyle(
                                              color: Colors.blue.shade700,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w500,
                                            ),
                                          ),
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
                  ),
          ),

          // Control buttons
          Align(
            alignment: Alignment.centerRight,
            child: Padding(
              padding: const EdgeInsets.only(right: 16.0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // Connect/Disconnect button
                  FloatingActionButton(
                    heroTag: 'connect',
                    onPressed: _isConnected ? _disconnect : _connect,
                    tooltip: _isConnected ? 'Disconnect' : 'Connect',
                    backgroundColor: _isConnected ? Colors.red : Colors.green,
                    child: Icon(_isConnected ? Icons.stop : Icons.play_arrow),
                  ),
                  const SizedBox(width: 16),
                  // Mute/Unmute button (only show when connected)
                  if (_isConnected)
                    FloatingActionButton(
                      heroTag: 'mute',
                      onPressed: _isMuted ? _unmuteInput : _muteInput,
                      tooltip: _isMuted ? 'Unmute' : 'Mute',
                      backgroundColor: _isMuted ? Colors.orange : Colors.grey,
                      child: Icon(_isMuted ? Icons.mic_off : Icons.mic),
                    ),
                  const SizedBox(width: 16),
                  FloatingActionButton(
                    heroTag: 'btn1',
                    onPressed: _onEngineOilPressed,
                    tooltip: 'Engine Oil',
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    backgroundColor: Colors.orange,
                    child: const Icon(Icons.oil_barrel, color: Colors.white),
                  ),
                  const SizedBox(width: 16),
                  FloatingActionButton(
                    heroTag: 'btn2',
                    onPressed: _onTirePressurePressed,
                    tooltip: 'Tire Pressure',
                    backgroundColor: Colors.black,
                    child: const Icon(Icons.tire_repair, color: Colors.white),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 16),

          // Input field
          Padding(
            padding: const EdgeInsets.all(16.0),
            child: TextField(
              controller: _controller,
              onSubmitted: (_) => _onSubmit(),
              decoration: InputDecoration(
                hintText: 'Enter your query here...',
                suffixIcon: IconButton(
                  icon: const Icon(Icons.send),
                  onPressed: _onSubmit,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    _audio.dispose();
    super.dispose();
  }

  void _sendTextMessage(String text) {
    if (_chatChannel != null) {
      _chatChannel!.sink.add(jsonEncode({
        'type': 'user_input',
        'text': text,
      }));
    }
  }

  // Opens a websocket connection to the EVI API and registers a listener to handle
  // incoming messages.
  void _connect() {
    setState(() {
      _isConnected = true;
    });
    if (ConfigManager.instance.humeApiKey.isNotEmpty &&
        ConfigManager.instance.humeAccessToken.isNotEmpty) {
      throw Exception(
          'Please use either an API key or an access token, not both');
    }

    var uri = 'wss://api.hume.ai/v0/evi/chat';
    if (ConfigManager.instance.humeAccessToken.isNotEmpty) {
      uri += '?access_token=${ConfigManager.instance.humeAccessToken}';
    } else if (ConfigManager.instance.humeApiKey.isNotEmpty) {
      uri += '?api_key=${ConfigManager.instance.humeApiKey}';
    } else {
      throw Exception('Please set your Hume API credentials in .env file');
    }

    if (ConfigManager.instance.humeConfigId.isNotEmpty) {
      uri += "&config_id=${ConfigManager.instance.humeConfigId}";
    }

    _chatChannel = WebSocketChannel.connect(Uri.parse(uri));

    _chatChannel!.stream.listen(
      (event) async {
        final message = evi.EviMessage.decode(event);
        debugPrint("Received message: ${message.type}");
        // This message contains audio data for playback.
        switch (message) {
          case (evi.ErrorMessage errorMessage):
            debugPrint("Error: ${errorMessage.message}");
            break;
          case (evi.ChatMetadataMessage chatMetadataMessage):
            debugPrint("Chat metadata: ${chatMetadataMessage.rawJson}");
            _prepareAudioSettings();
            _startRecording();
            break;
          case (evi.AudioOutputMessage audioOutputMessage):
            _audio.enqueueAudio(audioOutputMessage.data);
            break;
          case (evi.UserInterruptionMessage _):
            _handleInterruption();
            break;
          // These messages contain the transcript text of the user's or the assistant's speech
          // as well as emotional analysis of the speech.
          case (evi.AssistantMessage assistantMessage):
            appendNewChatMessage(
                assistantMessage.message, assistantMessage.models);
            break;
          case (evi.UserMessage userMessage):
            appendNewChatMessage(userMessage.message, userMessage.models);
            _handleInterruption();
            
            // Query Pinecone for additional context when user speaks
            if (ConfigManager.instance.pineconeApiKey.isNotEmpty) {
              _queryPineconeForVoiceInput(userMessage.message.content);
            }
            break;
          case (evi.UnknownMessage unknownMessage):
            debugPrint("Unknown message: ${unknownMessage.rawJson}");
            break;
        }
      },
      onError: (error) {
        debugPrint("Connection error: $error");
        _handleConnectionClosed();
      },
      onDone: () {
        debugPrint("Connection closed");
        _handleConnectionClosed();
      },
    );

    debugPrint("Connected");
  }

  void _disconnect() {
    _handleConnectionClosed();
    _handleInterruption();
    _chatChannel?.sink.close();
    debugPrint("Disconnected");
  }

  void _handleConnectionClosed() {
    setState(() {
      _isConnected = false;
    });
    _stopRecording();
  }

  void _handleInterruption() {
    _audio.stopPlayback();
  }

  void _muteInput() {
    _stopRecording();
    setState(() {
      _isMuted = true;
    });
  }

  void _prepareAudioSettings() {
    // set session settings to prepare EVI for receiving linear16 encoded audio
    // https://dev.hume.ai/docs/empathic-voice-interface-evi/configuration#session-settings
    _chatChannel!.sink.add(jsonEncode({
      'type': 'session_settings',
      'audio': {
        'encoding': 'linear16',
        'sample_rate': 48000,
        'channels': 1,
      },
    }));
  }

  void _sendAudio(String base64) {
    _chatChannel!.sink.add(jsonEncode({
      'type': 'audio_input',
      'data': base64,
    }));
  }

  void _startRecording() async {
    await _audio.startRecording();

    _audio.audioStream.listen((data) async {
      _sendAudio(data);
    });
    _audio.audioStream.handleError((error) {
      debugPrint("Error recording audio: $error");
    });
  }

  void _stopRecording() {
    _audio.stopRecording();
  }

  void _unmuteInput() {
    _startRecording();
    setState(() {
      _isMuted = false;
    });
  }

  /// Query Pinecone when user speaks to EVI
  void _queryPineconeForVoiceInput(String userSpeech) async {
    try {
      final pineconeResponse = await _pineconeService.queryNissanAssistant(userSpeech);
      
      if (pineconeResponse != null) {
        setState(() {
          chatEntries.add(ChatEntry(
            role: Role.assistant,
            timestamp: DateTime.now().toString(),
            content: "💡 Knowledge Insight: $pineconeResponse",
            scores: [],
          ));
        });
        
        // Convert to speech for voice input as well
        _convertToSpeechAndPlay(pineconeResponse);
      }
    } catch (e) {
      debugPrint("Error querying Pinecone for voice input: $e");
    }
  }

  /// Convert text to speech using Hume TTS and play it
  void _convertToSpeechAndPlay(String text) async {
    try {
      final audioData = await _ttsService.textToSpeech(text);
      if (audioData != null) {
        // Convert Uint8List to base64 for audio playback
        final base64Audio = base64Encode(audioData);
        _audio.enqueueAudio(base64Audio);
        
        debugPrint("Playing TTS audio for: ${text.substring(0, text.length > 50 ? 50 : text.length)}...");
      }
    } catch (e) {
      debugPrint("Error converting text to speech: $e");
    }
  }
}
