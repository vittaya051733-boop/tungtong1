import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

class AdminSupportInboxScreen extends StatelessWidget {
  const AdminSupportInboxScreen({super.key});

  static const String _supportChatsCollection = 'support_chats';

  String _pickDisplayName(Map<String, dynamic>? data, String uid) {
    final v = (data?['userName'] ?? data?['displayName'] ?? data?['userEmail'] ?? '')
        .toString()
        .trim();
    if (v.isNotEmpty && v.toLowerCase() != 'null') return v;
    return uid;
  }

  String _pickLastMessage(Map<String, dynamic>? data) {
    final preview = (data?['lastMessagePreview'] ?? '').toString().trim();
    if (preview.isNotEmpty && preview.toLowerCase() != 'null') return preview;
    final last = (data?['lastMessage'] ?? '').toString().trim();
    if (last.isNotEmpty && last.toLowerCase() != 'null') return last;
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection(_supportChatsCollection)
        .orderBy('lastMessageAt', descending: true)
        .limit(100)
        .snapshots();

    return Scaffold(
      appBar: AppBar(
        title: const Text('แชทลูกค้า (แอดมิน)'),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: stream,
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('โหลดรายการแชทไม่สำเร็จ'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? const [];
          if (docs.isEmpty) {
            return const Center(child: Text('ยังไม่มีแชท'));
          }

          return ListView.separated(
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, index) {
              final doc = docs[index];
              final data = doc.data();
              final uid = doc.id;
              final name = _pickDisplayName(data, uid);
              final last = _pickLastMessage(data);

              return ListTile(
                title: Text(name, style: const TextStyle(fontWeight: FontWeight.w800)),
                subtitle: last.isEmpty ? null : Text(last, maxLines: 1, overflow: TextOverflow.ellipsis),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => AdminSupportChatScreen(
                        customerUid: uid,
                        customerName: name,
                      ),
                    ),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class AdminSupportChatScreen extends StatefulWidget {
  const AdminSupportChatScreen({
    super.key,
    required this.customerUid,
    required this.customerName,
  });

  final String customerUid;
  final String customerName;

  @override
  State<AdminSupportChatScreen> createState() => _AdminSupportChatScreenState();
}

class _AdminSupportChatScreenState extends State<AdminSupportChatScreen> {
  static const String _supportChatsCollection = 'support_chats';
  static const String _supportMessagesSubcollection = 'messages';

  Stream<QuerySnapshot<Map<String, dynamic>>> _messagesStream() {
    return FirebaseFirestore.instance
        .collection(_supportChatsCollection)
        .doc(widget.customerUid)
        .collection(_supportMessagesSubcollection)
        .orderBy('createdAt', descending: true)
        .limit(200)
        .snapshots();
  }

  bool _isAdminMessage(Map<String, dynamic> data) {
    final role = (data['senderRole'] ?? '').toString().trim().toLowerCase();
    if (role.isNotEmpty) return role != 'user';
    final senderUid = (data['senderUid'] ?? '').toString().trim();
    if (senderUid.isNotEmpty) return senderUid != widget.customerUid;
    return true;
  }

  Widget _bubble({required Widget child, required bool isAdmin}) {
    final bg = isAdmin ? Colors.red.shade50 : Colors.grey.shade200;
    final align = isAdmin ? Alignment.centerRight : Alignment.centerLeft;
    final radius = BorderRadius.circular(14);

    return Align(
      alignment: align,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        margin: const EdgeInsets.symmetric(vertical: 4),
        decoration: BoxDecoration(color: bg, borderRadius: radius),
        child: child,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.customerName),
      ),
      body: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
        stream: _messagesStream(),
        builder: (context, snapshot) {
          if (snapshot.hasError) {
            return const Center(child: Text('โหลดข้อความไม่สำเร็จ'));
          }
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          final docs = snapshot.data?.docs ?? const [];
          if (docs.isEmpty) {
            return const Center(child: Text('ยังไม่มีข้อความ'));
          }

          return ListView.builder(
            reverse: true,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
            itemCount: docs.length,
            itemBuilder: (context, index) {
              final data = docs[index].data();
              final type = (data['type'] ?? 'text').toString().trim().toLowerCase();
              final isAdmin = _isAdminMessage(data);

              if (type == 'image') {
                final imageUrl = (data['imageUrl'] ?? '').toString().trim();
                if (imageUrl.isEmpty) return const SizedBox.shrink();
                return _bubble(
                  isAdmin: isAdmin,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(14),
                    child: Image.network(
                      imageUrl,
                      height: 220,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                );
              }

              final text = (data['text'] ?? '').toString().trim();
              if (text.isEmpty) return const SizedBox.shrink();
              return _bubble(
                isAdmin: isAdmin,
                child: Text(text, style: const TextStyle(fontWeight: FontWeight.w700)),
              );
            },
          );
        },
      ),
    );
  }
}
