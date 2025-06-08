import 'dart:convert';
import 'package:http/http.dart' as http;

class PineconeService {
  final String apiKey;
  final String assistantName;
  final String baseUrl;

  PineconeService({
    required this.apiKey,
    required this.assistantName,
    this.baseUrl = 'https://prod-1-data.ke.pinecone.io',
  });

  /// Query Pinecone Assistant for knowledge-based answers
  Future<String?> queryAssistant(String question) async {
    try {
      final url = Uri.parse('$baseUrl/assistant/chat/$assistantName');
      
      final response = await http.post(
        url,
        headers: {
          'Api-Key': apiKey,
          'Content-Type': 'application/json',
        },
        body: jsonEncode({
          'messages': [
            {
              'role': 'user',
              'content': question,
            }
          ],
          'stream': false,
          'model': 'gpt-4o',
        }),
      );

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        return data['message']?['content'];
      } else {
        print('Pinecone API error: ${response.statusCode} - ${response.body}');
        return null;
      }
    } catch (e) {
      print('Error querying Pinecone: $e');
      return null;
    }
  }

  /// Enhanced query that combines Nissan context with user question
  Future<String?> queryNissanAssistant(String userQuestion) async {
    // Add Nissan-specific context to improve responses
    final enhancedQuestion = '''
Context: You are a Nissan vehicle assistant helping with car maintenance and support.
User Question: $userQuestion

Please provide a helpful answer related to Nissan vehicles, maintenance, or automotive topics.
''';

    return await queryAssistant(enhancedQuestion);
  }

  /// Stream responses for real-time interaction
  Stream<String> queryAssistantStream(String question) async* {
    try {
      final url = Uri.parse('$baseUrl/assistant/chat/$assistantName');
      
      final request = http.Request('POST', url);
      request.headers.addAll({
        'Api-Key': apiKey,
        'Content-Type': 'application/json',
      });
      request.body = jsonEncode({
        'messages': [
          {
            'role': 'user',
            'content': question,
          }
        ],
        'stream': true,
        'model': 'gpt-4o',
      });

      final streamedResponse = await request.send();
      
      if (streamedResponse.statusCode == 200) {
        await for (final chunk in streamedResponse.stream.transform(utf8.decoder)) {
          if (chunk.trim().isNotEmpty) {
            try {
              final data = jsonDecode(chunk);
              final content = data['message']?['content'];
              if (content != null) {
                yield content;
              }
            } catch (e) {
              // Handle partial JSON chunks
              continue;
            }
          }
        }
      }
    } catch (e) {
      print('Error streaming from Pinecone: $e');
    }
  }
}
