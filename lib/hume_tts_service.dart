import 'dart:convert';
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:audio/audio.dart';

class HumeTTSService {
  final String apiKey;

  HumeTTSService({required this.apiKey});

  /// Convert text to speech using Hume AI TTS API
  Future<Uint8List?> textToSpeech(String text) async {
    try {
      final url = Uri.parse('https://api.hume.ai/v0/tts');
      
      final response = await http.post(
        url,
        headers: {
          'X-Hume-Api-Key': apiKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'utterances': [
            {
              'text': text,
              'description': 'A friendly, professional voice assistant for Nissan vehicle support with a warm and helpful tone.',
            }
          ],
          'format': {
            'type': 'mp3',
          },
          'num_generations': 1,
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        final audioBase64 = data['generations']?[0]?['audio'];
        
        if (audioBase64 != null) {
          // Decode base64 audio
          return base64Decode(audioBase64);
        }
      } else {
        print('Hume TTS error: ${response.statusCode} - ${response.body}');
      }
    } catch (e) {
      print('Error with Hume TTS: $e');
    }
    return null;
  }

  /// Stream TTS for real-time playback
  Stream<Uint8List> textToSpeechStream(String text) async* {
    try {
      final url = Uri.parse('https://api.hume.ai/v0/tts/stream/json');
      
      final request = http.Request('POST', url);
      request.headers.addAll({
        'X-Hume-Api-Key': apiKey,
        'Content-Type': 'application/json',
      });
      request.body = jsonEncode({
        'utterances': [
          {
            'text': text,
            'description': 'A friendly, professional voice assistant for Nissan vehicle support with a warm and helpful tone.',
          }
        ],
        'format': {
          'type': 'mp3',
        },
        'num_generations': 1,
        'instant_mode': true,
      });

      final streamedResponse = await request.send();
      
      if (streamedResponse.statusCode == 200) {
        await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
          if (chunk.trim().isNotEmpty) {
            try {
              final data = jsonDecode(chunk);
              final audioBase64 = data['audio'];
              if (audioBase64 != null) {
                yield base64Decode(audioBase64);
              }
            } catch (e) {
              // Handle partial JSON chunks
              continue;
            }
          }
        }
      }
    } catch (e) {
      print('Error streaming TTS: $e');
    }
  }
}
