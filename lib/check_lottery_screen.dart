import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class CheckLotteryScreen extends StatefulWidget {
  const CheckLotteryScreen({
    super.key,
    this.selectedDrawId,
    this.drawOptions = const <GloDrawOption>[],
    this.loadingDraws = false,
    this.drawLoadError,
    this.onDrawChanged,
  });

  final String? selectedDrawId;
  final List<GloDrawOption> drawOptions;
  final bool loadingDraws;
  final String? drawLoadError;
  final ValueChanged<String?>? onDrawChanged;

  @override
  State<CheckLotteryScreen> createState() => _CheckLotteryScreenState();
}

class _CheckLotteryScreenState extends State<CheckLotteryScreen> {
  static final Uri _gloResultsApiUri = Uri.parse(
    'https://www.glo.or.th/api/lottery/getLotteryResultByPage',
  );

  final TextEditingController _ticketController = TextEditingController();

  bool _loading = false;
  String? _error;
  GloDrawResult? _draw;
  LotteryCheckResult? _check;

  @override
  void initState() {
    super.initState();
    unawaited(_loadSelected());
  }

  @override
  void didUpdateWidget(covariant CheckLotteryScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.selectedDrawId != widget.selectedDrawId) {
      unawaited(_loadSelected());
    }
  }

  @override
  void dispose() {
    _ticketController.dispose();
    super.dispose();
  }

  Future<void> _loadSelected() async {
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      final selectedId = widget.selectedDrawId;
      final draw = selectedId == null
          ? await GloClient().fetchLatestDraw()
          : await GloClient().fetchDrawById(selectedId);
      if (!mounted) return;
      setState(() {
        _draw = draw;
        _check = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = 'ดึงข้อมูลผลรางวัลไม่สำเร็จ';
      });
    } finally {
      if (mounted) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  void _runCheck() {
    final draw = _draw;
    if (draw == null) return;

    final ticket = _ticketController.text.trim();
    if (!_isValidTicket6(ticket)) {
      setState(() {
        _check = LotteryCheckResult(
          ticketNumber: ticket,
          matches: const [],
          error: 'กรุณากรอกเลข 6 หลักให้ครบ',
        );
      });
      return;
    }

    final matches = <PrizeMatch>[];

    if (ticket == draw.firstPrize) {
      matches.add(const PrizeMatch(label: 'รางวัลที่ 1', amountBaht: 6000000));
    }

    if (draw.adjacentFirst.contains(ticket)) {
      matches.add(
        const PrizeMatch(label: 'รางวัลข้างเคียงรางวัลที่ 1', amountBaht: 100000),
      );
    }

    if (draw.prize2.contains(ticket)) {
      matches.add(const PrizeMatch(label: 'รางวัลที่ 2', amountBaht: 200000));
    }

    if (draw.prize3.contains(ticket)) {
      matches.add(const PrizeMatch(label: 'รางวัลที่ 3', amountBaht: 80000));
    }

    if (draw.prize4.contains(ticket)) {
      matches.add(const PrizeMatch(label: 'รางวัลที่ 4', amountBaht: 40000));
    }

    if (draw.prize5.contains(ticket)) {
      matches.add(const PrizeMatch(label: 'รางวัลที่ 5', amountBaht: 20000));
    }

    final front3 = ticket.substring(0, 3);
    final last3 = ticket.substring(3);
    final last2 = ticket.substring(4);

    if (draw.front3.contains(front3)) {
      matches.add(
        const PrizeMatch(label: 'รางวัลเลขหน้า 3 ตัว', amountBaht: 4000),
      );
    }

    if (draw.last3.contains(last3)) {
      matches.add(
        const PrizeMatch(label: 'รางวัลเลขท้าย 3 ตัว', amountBaht: 4000),
      );
    }

    if (draw.last2 == last2) {
      matches.add(
        const PrizeMatch(label: 'รางวัลเลขท้าย 2 ตัว', amountBaht: 2000),
      );
    }

    setState(() {
      _check = LotteryCheckResult(ticketNumber: ticket, matches: matches);
    });
  }

  @override
  Widget build(BuildContext context) {
    final draw = _draw;

    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'ตรวจสลากฯ',
          style: TextStyle(fontWeight: FontWeight.w800),
        ),
        actions: [
          IconButton(
            onPressed: _loading ? null : _loadSelected,
            icon: const Icon(Icons.refresh),
            tooltip: 'รีเฟรชผลรางวัล',
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (widget.drawOptions.isNotEmpty)
                DropdownButtonFormField<String>(
                  key: ValueKey<String?>(widget.selectedDrawId),
                  initialValue: widget.selectedDrawId,
                  items: widget.drawOptions
                      .map(
                        (e) => DropdownMenuItem<String>(
                          value: e.id,
                          child: Text(e.label, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (widget.loadingDraws) ? null : widget.onDrawChanged,
                  decoration: InputDecoration(
                    filled: true,
                    fillColor: Colors.grey.shade50,
                    contentPadding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 12,
                    ),
                    border: const OutlineInputBorder(),
                  ),
                ),
              if (widget.loadingDraws)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'กำลังโหลดงวด…',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (widget.drawLoadError != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    widget.drawLoadError!,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.red,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              if (widget.drawOptions.isNotEmpty) const SizedBox(height: 12),
              if (draw != null)
                Text(
                  'ผลรางวัล: ${draw.drawDateText} (${draw.source == 'firestore' ? 'Firebase' : 'เว็บ GLO'})',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              if (draw == null)
                Text(
                  _loading ? 'กำลังโหลดผลรางวัล…' : 'ยังไม่มีข้อมูลผลรางวัล',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    _error!,
                    style: Theme.of(
                      context,
                    ).textTheme.bodyMedium?.copyWith(color: Colors.red),
                  ),
                ),
              const SizedBox(height: 16),
              TextField(
                controller: _ticketController,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'เลขสลาก 6 หลัก',
                  border: OutlineInputBorder(),
                  counterText: '',
                ),
                onChanged: (_) {
                  if (_check != null) setState(() => _check = null);
                },
                onSubmitted: (_) => _runCheck(),
              ),
              const SizedBox(height: 12),
              FilledButton(
                onPressed: (_loading || draw == null) ? null : _runCheck,
                child: const Text(
                  'ตรวจสลาก',
                  style: TextStyle(fontWeight: FontWeight.w900),
                ),
              ),
              if (draw != null && draw.source != 'firestore')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    'หมายเหตุ: ยังไม่พบข้อมูลผลรางวัลจาก PDF ใน Firebase จึงตรวจได้เฉพาะ รางวัลที่ 1/หน้า3/ท้าย3/ท้าย2 (รางวัล 2–5 และข้างเคียงจะต้องรอซิงค์ PDF ก่อน)',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Colors.grey.shade700,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Expanded(child: _buildResultArea(context)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildResultArea(BuildContext context) {
    final check = _check;
    if (check == null) {
      return const SizedBox.shrink();
    }

    if (check.error != null) {
      return _ResultCard(
        title: 'ตรวจไม่สำเร็จ',
        subtitle: check.error!,
        color: Colors.red.shade50,
      );
    }

    if (check.matches.isEmpty) {
      return _ResultCard(
        title: 'ไม่ถูกรางวัล',
        subtitle: 'เลข ${check.ticketNumber}',
        color: Colors.grey.shade100,
      );
    }

    final total = check.matches.fold<int>(
      0,
      (totalSoFar, item) => totalSoFar + item.amountBaht,
    );

    return Card(
      elevation: 0,
      color: Colors.green.shade50,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'ถูกรางวัล!',
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 4),
            Text(
              'เลข ${check.ticketNumber}',
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 12),
            ...check.matches.map(
              (m) => Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        m.label,
                        style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Text(
                      '${_formatBaht(m.amountBaht)} บาท',
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Divider(height: 20),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'รวม',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Text(
                  '${_formatBaht(total)} บาท',
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResultCard extends StatelessWidget {
  const _ResultCard({
    required this.title,
    required this.subtitle,
    required this.color,
  });

  final String title;
  final String subtitle;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Card(
      elevation: 0,
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(subtitle),
          ],
        ),
      ),
    );
  }
}

class LotteryCheckResult {
  const LotteryCheckResult({
    required this.ticketNumber,
    required this.matches,
    this.error,
  });

  final String ticketNumber;
  final List<PrizeMatch> matches;
  final String? error;
}

class PrizeMatch {
  const PrizeMatch({required this.label, required this.amountBaht});

  final String label;
  final int amountBaht;
}

class GloDrawResult {
  const GloDrawResult({
    required this.source,
    this.drawDateIso,
    required this.drawDateText,
    required this.firstPrize,
    required this.front3,
    required this.last3,
    required this.last2,
    required this.adjacentFirst,
    required this.prize2,
    required this.prize3,
    required this.prize4,
    required this.prize5,
    this.pdfStoragePath,
    this.pdfSha256,
  });

  final String source; // 'firestore' | 'api'
  final String? drawDateIso; // YYYY-MM-DD when coming from Firestore
  final String drawDateText;
  final String firstPrize;
  final List<String> front3;
  final List<String> last3;
  final String last2;
  final List<String> adjacentFirst;
  final List<String> prize2;
  final List<String> prize3;
  final List<String> prize4;
  final List<String> prize5;
  final String? pdfStoragePath;
  final String? pdfSha256;
}

class GloDrawOption {
  const GloDrawOption({
    required this.id,
    required this.dateIso,
    required this.label,
    required this.fromFirestore,
    this.apiPage,
    this.apiIndex,
  });

  final String id;
  final String dateIso; // YYYY-MM-DD
  final String label;
  final bool fromFirestore;
  final int? apiPage;
  final int? apiIndex;
}

class GloClient {
  Future<List<GloDrawOption>> fetchDrawOptions({
    int firestoreLimit = 20,
    int apiPages = 6,
    int daysBack = 366,
  }) async {
    final out = <GloDrawOption>[];
    final seenLabels = <String>{};

    final cutoffIso = _isoCutoffDate(daysBack);

    // 1) Firestore draws (if available)
    try {
      final query = await FirebaseFirestore.instance
          .collection('lottery_draws')
          .orderBy('date', descending: true)
          .limit(firestoreLimit)
          .get();

      for (final doc in query.docs) {
        final raw = doc.data();
        final dateIso = (raw['date'] as String?)?.trim() ?? doc.id.trim();
        if (dateIso.compareTo(cutoffIso) < 0) continue;
        final labelDate = _formatIsoDateToThaiLabel(dateIso) ?? dateIso;
        final label = 'งวดวันที่ $labelDate';
        if (seenLabels.contains(label)) continue;
        seenLabels.add(label);
        out.add(
          GloDrawOption(
            id: dateIso,
            dateIso: dateIso,
            label: label,
            fromFirestore: true,
          ),
        );
      }
    } catch (_) {
      // Ignore; can happen on platforms where Firebase isn't initialized.
    }

    // 2) API draws for checking past results (page 1..N)
    try {
      final apiOptions = await _fetchDrawOptionsFromApi(pages: apiPages);
      for (final opt in apiOptions) {
        if (opt.dateIso.compareTo(cutoffIso) < 0) continue;
        if (seenLabels.contains(opt.label)) continue;
        seenLabels.add(opt.label);
        out.add(opt);
      }
    } catch (_) {
      // Ignore; we still may have Firestore options.
    }

    return out;
  }

  String _isoCutoffDate(int daysBack) {
    final days = daysBack < 1 ? 1 : daysBack;
    final cutoff = DateTime.now().toUtc().subtract(Duration(days: days));
    final y = cutoff.year.toString().padLeft(4, '0');
    final m = cutoff.month.toString().padLeft(2, '0');
    final d = cutoff.day.toString().padLeft(2, '0');
    return '$y-$m-$d';
  }

  Future<GloDrawResult> fetchDrawById(String id) async {
    if (id == 'latest') {
      return fetchLatestDraw(preferFirestore: true);
    }

    final apiMatch = RegExp(r'^api:(\d+):(\d+)$').firstMatch(id);
    if (apiMatch != null) {
      final page = int.tryParse(apiMatch.group(1) ?? '');
      final index = int.tryParse(apiMatch.group(2) ?? '');
      if (page != null && index != null) {
        final fromApi = await _fetchDrawFromApiPageIndex(page: page, index: index);
        if (fromApi != null) return fromApi;
      }
      return fetchLatestDraw(preferFirestore: true);
    }

    // If looks like ISO date, try Firestore doc by id.
    if (RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(id)) {
      final fromDb = await _fetchDrawFromFirestoreByIsoDate(id);
      if (fromDb != null) return fromDb;
    }
    // Fallback: latest (API or Firestore).
    return fetchLatestDraw(preferFirestore: true);
  }

  Future<List<GloDrawOption>> _fetchDrawOptionsFromApi({required int pages}) async {
    final httpClient = http.Client();
    try {
      final out = <GloDrawOption>[];
      for (var page = 1; page <= pages; page++) {
        final resp = await httpClient.post(
          _CheckLotteryScreenState._gloResultsApiUri,
          headers: const {
            'Accept': 'application/json',
            'Content-Type': 'application/json',
          },
          body: jsonEncode({'page': page}),
        );
        if (resp.statusCode < 200 || resp.statusCode >= 300) {
          break;
        }
        final decoded = jsonDecode(resp.body);
        final items = _extractResultItems(decoded);
        if (items.isEmpty) break;
        for (var i = 0; i < items.length; i++) {
          final date = (items[i]['date'] as String?)?.trim();
          if (date == null || date.isEmpty) continue;
          out.add(
            GloDrawOption(
              id: 'api:$page:$i',
              dateIso: date,
              label: 'งวดวันที่ $date',
              fromFirestore: false,
              apiPage: page,
              apiIndex: i,
            ),
          );
        }
      }
      return out;
    } finally {
      httpClient.close();
    }
  }

  Future<GloDrawResult?> _fetchDrawFromApiPageIndex({
    required int page,
    required int index,
  }) async {
    final httpClient = http.Client();
    try {
      final resp = await httpClient.post(
        _CheckLotteryScreenState._gloResultsApiUri,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'page': page}),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) return null;
      final decoded = jsonDecode(resp.body);
      final items = _extractResultItems(decoded);
      if (index < 0 || index >= items.length) return null;
      final item = items[index];
      final date = (item['date'] as String?)?.trim();
      final data = item['data'];
      if (date == null || date.isEmpty || data is! Map<String, dynamic>) {
        return null;
      }

      final firstPrize = _extractFirstString(data['first']);
      final front3 = _extractStringList(data['last3f']);
      final last3 = _extractStringList(data['last3b']);
      final last2 = _extractFirstString(data['last2']);
      if (firstPrize.isEmpty || last2.isEmpty) return null;

      return GloDrawResult(
        source: 'api',
        drawDateIso: null,
        drawDateText: date,
        firstPrize: firstPrize,
        front3: front3,
        last3: last3,
        last2: last2,
        adjacentFirst: const [],
        prize2: const [],
        prize3: const [],
        prize4: const [],
        prize5: const [],
        pdfStoragePath: null,
        pdfSha256: null,
      );
    } finally {
      httpClient.close();
    }
  }

  Future<GloDrawResult> fetchLatestDraw({
    http.Client? client,
    bool preferFirestore = true,
  }) async {
    if (preferFirestore) {
      final fromDb = await _fetchLatestDrawFromFirestore();
      if (fromDb != null) return fromDb;
    }

    final httpClient = client ?? http.Client();
    try {
      final resp = await httpClient.post(
        _CheckLotteryScreenState._gloResultsApiUri,
        headers: const {
          'Accept': 'application/json',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'page': 1}),
      );
      if (resp.statusCode < 200 || resp.statusCode >= 300) {
        throw StateError('HTTP ${resp.statusCode}');
      }

      final decoded = jsonDecode(resp.body);
      final item = _extractFirstResultItem(decoded);
      final date = (item['date'] as String?)?.trim();
      final data = item['data'];
      if (date == null || date.isEmpty || data is! Map<String, dynamic>) {
        throw StateError('Unexpected API payload');
      }

      final firstPrize = _extractFirstString(data['first']);
      final front3 = _extractStringList(data['last3f']);
      final last3 = _extractStringList(data['last3b']);
      final last2 = _extractFirstString(data['last2']);

      return GloDrawResult(
        source: 'api',
        drawDateIso: null,
        drawDateText: date,
        firstPrize: firstPrize,
        front3: front3,
        last3: last3,
        last2: last2,
        adjacentFirst: const [],
        prize2: const [],
        prize3: const [],
        prize4: const [],
        prize5: const [],
        pdfStoragePath: null,
        pdfSha256: null,
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  Future<GloDrawResult?> _fetchDrawFromFirestoreByIsoDate(String isoDate) async {
    try {
      final doc = await FirebaseFirestore.instance
          .collection('lottery_draws')
          .doc(isoDate)
          .get();
      if (!doc.exists) return null;
      final raw = doc.data();
      if (raw == null) return null;
      return _mapFirestoreDraw(raw);
    } catch (_) {
      return null;
    }
  }

  Future<GloDrawResult?> _fetchLatestDrawFromFirestore() async {
    try {
      final query = await FirebaseFirestore.instance
          .collection('lottery_draws')
          .orderBy('date', descending: true)
          .limit(1)
          .get();

      if (query.docs.isEmpty) return null;
      final raw = query.docs.first.data();
      return _mapFirestoreDraw(raw);
    } catch (_) {
      return null;
    }
  }

  GloDrawResult? _mapFirestoreDraw(Map<String, dynamic> raw) {
    final dateIso = (raw['date'] as String?)?.trim();
    final results = raw['results'];
    if (dateIso == null || dateIso.isEmpty || results is! Map<String, dynamic>) {
      return null;
    }

    final firstPrize = (results['firstPrize'] as String?)?.trim() ?? '';
    final last2 = (results['last2'] as String?)?.trim() ?? '';

    final last3f = results['last3f'];
    final last3b = results['last3b'];
    final adjacentFirstRaw = results['adjacentFirst'];
    final prize2Raw = results['prize2'];
    final prize3Raw = results['prize3'];
    final prize4Raw = results['prize4'];
    final prize5Raw = results['prize5'];

    final front3 = (last3f is List)
        ? last3f
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final last3 = (last3b is List)
        ? last3b
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final adjacentFirst = (adjacentFirstRaw is List)
        ? adjacentFirstRaw
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final prize2 = (prize2Raw is List)
        ? prize2Raw
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final prize3 = (prize3Raw is List)
        ? prize3Raw
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final prize4 = (prize4Raw is List)
        ? prize4Raw
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final prize5 = (prize5Raw is List)
        ? prize5Raw
            .whereType<String>()
            .map((s) => s.trim())
            .where((s) => s.isNotEmpty)
            .toList(growable: false)
        : const <String>[];

    final pdf = raw['pdf'];
    String? storagePath;
    String? sha256;
    if (pdf is Map<String, dynamic>) {
      storagePath = (pdf['storagePath'] as String?)?.trim();
      sha256 = (pdf['sha256'] as String?)?.trim();
    }

    if (firstPrize.isEmpty || last2.isEmpty) return null;

    final thaiDate = _formatIsoDateToThaiLabel(dateIso);
    return GloDrawResult(
      source: 'firestore',
      drawDateIso: dateIso,
      drawDateText: thaiDate != null ? 'งวดวันที่ $thaiDate' : dateIso,
      firstPrize: firstPrize,
      front3: front3,
      last3: last3,
      last2: last2,
      adjacentFirst: adjacentFirst,
      prize2: prize2,
      prize3: prize3,
      prize4: prize4,
      prize5: prize5,
      pdfStoragePath: storagePath,
      pdfSha256: sha256,
    );
  }

  String? _formatIsoDateToThaiLabel(String iso) {
    final m = RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(iso.trim());
    if (m == null) return null;
    final year = int.tryParse(m.group(1) ?? '');
    final month = int.tryParse(m.group(2) ?? '');
    final day = int.tryParse(m.group(3) ?? '');
    if (year == null || month == null || day == null) return null;

    const months = <int, String>{
      1: 'มกราคม',
      2: 'กุมภาพันธ์',
      3: 'มีนาคม',
      4: 'เมษายน',
      5: 'พฤษภาคม',
      6: 'มิถุนายน',
      7: 'กรกฎาคม',
      8: 'สิงหาคม',
      9: 'กันยายน',
      10: 'ตุลาคม',
      11: 'พฤศจิกายน',
      12: 'ธันวาคม',
    };
    final monthText = months[month];
    if (monthText == null) return null;
    final buddhistYear = year + 543;
    return '$day $monthText $buddhistYear';
  }

  Map<String, dynamic> _extractFirstResultItem(Object decoded) {
    Object? response = decoded;
    if (decoded is Map<String, dynamic> && decoded.containsKey('response')) {
      response = decoded['response'];
    }

    Object? dataContainer = response;
    if (dataContainer is Map<String, dynamic> && dataContainer['data'] != null) {
      dataContainer = dataContainer['data'];
    }

    if (dataContainer is List && dataContainer.isNotEmpty) {
      final first = dataContainer.first;
      if (first is Map<String, dynamic>) return first;
    }

    if (response is Map<String, dynamic>) {
      final maybeItem = response['item'] ?? response['result'];
      if (maybeItem is Map<String, dynamic>) return maybeItem;
    }

    throw StateError('No result item');
  }

  List<Map<String, dynamic>> _extractResultItems(Object decoded) {
    Object? response = decoded;
    if (decoded is Map<String, dynamic> && decoded.containsKey('response')) {
      response = decoded['response'];
    }

    Object? dataContainer = response;
    if (dataContainer is Map<String, dynamic> && dataContainer['data'] != null) {
      dataContainer = dataContainer['data'];
    }

    if (dataContainer is List) {
      return dataContainer.whereType<Map<String, dynamic>>().toList(growable: false);
    }

    if (response is Map<String, dynamic>) {
      final maybe = response['item'] ?? response['result'];
      if (maybe is List) {
        return maybe.whereType<Map<String, dynamic>>().toList(growable: false);
      }
      if (maybe is Map<String, dynamic>) return [maybe];
    }

    return const <Map<String, dynamic>>[];
  }

  String _extractFirstString(Object? value) {
    if (value is String) return value;
    if (value is List) {
      for (final item in value) {
        if (item is String) return item;
      }
    }
    return '';
  }

  List<String> _extractStringList(Object? value) {
    if (value is List) {
      return value
          .whereType<String>()
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList(growable: false);
    }
    if (value is String && value.trim().isNotEmpty) return [value.trim()];
    return const [];
  }
}

bool _isValidTicket6(String value) {
  return RegExp(r'^\d{6}$').hasMatch(value);
}

String _formatBaht(int value) {
  final digits = value.toString();
  final out = StringBuffer();
  for (var i = 0; i < digits.length; i++) {
    final fromEnd = digits.length - i;
    out.write(digits[i]);
    if (fromEnd > 1 && fromEnd % 3 == 1) out.write(',');
  }
  return out.toString();
}
