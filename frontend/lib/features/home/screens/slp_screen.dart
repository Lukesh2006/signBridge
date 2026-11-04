import 'package:flutter/material.dart';

class SlpScreen extends StatefulWidget {
  const SlpScreen({super.key});

  @override
  State<SlpScreen> createState() => _SlpScreenState();
}

class _SlpScreenState extends State<SlpScreen> {
  final _textController = TextEditingController();
  List<String> _words = const [];
  bool _hasAnalyzed = false;

  @override
  void dispose() {
    _textController.dispose();
    super.dispose();
  }

  void _analyzeText() {
    final words = _textController.text
        .toLowerCase()
        .replaceAll(RegExp(r"[^a-z0-9' ]"), ' ')
        .split(RegExp(r'\s+'))
        .where((word) => word.isNotEmpty)
        .toList();
    setState(() {
      _words = words;
      _hasAnalyzed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    const navy = Color(0xFF1E2158);
    const blue = Color(0xFF4B6CF7);

    return Scaffold(
      backgroundColor: const Color(0xFFF5F7FF),
      appBar: AppBar(
        title: const Text('Text to Sign'),
        backgroundColor: const Color(0xFFF5F7FF),
        foregroundColor: navy,
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 28),
          children: [
            const Text(
              'Type a short English message',
              style: TextStyle(fontSize: 22, fontWeight: FontWeight.bold, color: navy),
            ),
            const SizedBox(height: 8),
            const Text(
              'The prototype will split the text into words. Sign clips and an avatar are not connected yet, so it will show which words still need sign data.',
              style: TextStyle(color: Colors.black54, height: 1.4),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: _textController,
              onChanged: (_) => setState(() {}),
              minLines: 3,
              maxLines: 5,
              textCapitalization: TextCapitalization.sentences,
              decoration: InputDecoration(
                hintText: 'Example: I am fine',
                filled: true,
                fillColor: Colors.white,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(16),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _textController.text.trim().isEmpty ? null : _analyzeText,
              icon: const Icon(Icons.text_fields),
              label: const Text('Analyze text'),
              style: FilledButton.styleFrom(
                backgroundColor: blue,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
            if (_hasAnalyzed) ...[
              const SizedBox(height: 24),
              const Text(
                'Word breakdown',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: navy),
              ),
              const SizedBox(height: 10),
              if (_words.isEmpty)
                const Text('Enter some text to analyze.')
              else
                ..._words.asMap().entries.map(
                  (entry) => Card(
                    color: Colors.white,
                    child: ListTile(
                      leading: CircleAvatar(
                        backgroundColor: const Color(0xFFEEF2FF),
                        foregroundColor: blue,
                        child: Text('${entry.key + 1}'),
                      ),
                      title: Text(entry.value),
                      subtitle: const Text('No approved sign clip is mapped yet'),
                      trailing: const Icon(Icons.pending_outlined, color: Colors.orange),
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: const Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Icon(Icons.info_outline, color: blue),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Avatar signing needs reviewed ISL gloss mappings and animation data. This repository currently includes neither, so no sign animation is played for this message.',
                        style: TextStyle(color: Colors.black54, height: 1.4),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
