import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:pdf/pdf.dart';
import 'package:printing/printing.dart';
import 'package:share_plus/share_plus.dart';

import '../core/print_layout.dart';
import '../data/print_export.dart';
import '../data/store.dart';
import '../l10n/strings.dart';
import 'theme.dart';
import 'widgets/common.dart';

class PrintScreen extends StatefulWidget {
  const PrintScreen({super.key, required this.loadContent, required this.taken});

  factory PrintScreen.forPhoto(PhotoItem photo) => PrintScreen(
    loadContent: () => loadPrintContent(photo),
    taken: photo.taken,
  );

  final Future<PrintContent> Function() loadContent;
  final DateTime taken;

  @override
  State<PrintScreen> createState() => _PrintScreenState();
}

class _PrintScreenState extends State<PrintScreen> {
  ui.Image? _photo;
  List<ui.Image?> _textures = [];
  List<Color> _palette = [];
  String? _loadError, _actionError;
  String? _busy;
  bool _loading = true;
  PrintStyle _style = PrintStyle.instant;
  PrintPaper _paper = PrintPaper.l;
  bool _landscape = false, _fill = false, _colors = true, _date = true;
  bool _orientationChosen = false;
  final _title = TextEditingController();
  final _place = TextEditingController();
  final _shareKey = GlobalKey();
  final _paperKey = GlobalKey();
  Size? _editingPaperSize;
  bool _editingDetails = false;
  bool _editingPlace = false;
  final _detailFocus = FocusNode();

  PrintLayout get _layout => PrintLayout(
    style: _style, paper: _paper, landscape: _landscape, fill: _fill,
    title: _title.text, place: _place.text,
    date: _date ? '${widget.taken.year}.${widget.taken.month.toString().padLeft(2, '0')}.${widget.taken.day.toString().padLeft(2, '0')}' : '',
    colors: _palette, showColors: _colors,
  );

  // Input hints belong only to the preview; _output always uses _layout.
  PrintLayout get _previewLayout => !_layout.supportsDetails ? _layout : PrintLayout(
    style: _style, paper: _paper, landscape: _landscape, fill: _fill,
    title: _title.text.trim().isEmpty ? context.tr('Add a title', 'タイトルを入力') : _title.text,
    place: _place.text.trim().isEmpty ? context.tr('Add a place', '場所を入力') : _place.text,
    date: _layout.date, colors: _layout.colors, showColors: _colors,
  );

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() { _loading = true; _loadError = null; });
    try {
      final content = await widget.loadContent();
      Future<ui.Image> decode(List<int> bytes) async {
        final codec = await ui.instantiateImageCodec(Uint8List.fromList(bytes));
        try { return (await codec.getNextFrame()).image; }
        finally { codec.dispose(); }
      }
      final photo = await decode(content.photo);
      final textures = <ui.Image?>[];
      for (final bytes in content.textures.take(6)) {
        try { textures.add(bytes == null ? null : await decode(bytes)); }
        catch (_) { textures.add(null); }
      }
      if (!mounted) {
        photo.dispose();
        for (final texture in textures) { texture?.dispose(); }
        return;
      }
      setState(() {
        _photo = photo;
        _textures = textures;
        _palette = content.colors.take(6).toList();
        if (!_orientationChosen) _landscape = photo.width > photo.height;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = context.tr('Could not load this photo. Check that the original is available and try again.', '写真を読み込めませんでした。元の写真を確認して、もう一度お試しください。'));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _photo?.dispose();
    for (final texture in _textures) { texture?.dispose(); }
    _title.dispose();
    _place.dispose();
    _detailFocus.dispose();
    super.dispose();
  }

  Future<void> _output(String action) async {
    if (_busy != null || _photo == null) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() { _busy = action; _actionError = null; });
    final layout = _layout;
    try {
      final bytes = await exportPrintImage(_photo!, layout, fontFamily: uiFamily, textures: _textures);
      if (!mounted) return;
      final filename = 'After-Hue-${DateTime.now().millisecondsSinceEpoch}.jpg';
      if (action == 'Print') {
        await Printing.layoutPdf(
          name: 'After Hue',
          format: PdfPageFormat(layout.size.width * PdfPageFormat.mm, layout.size.height * PdfPageFormat.mm),
          outputType: OutputType.photo,
          onLayout: (format) => printPdf(bytes, format),
        );
        // The system reports submitting/cancelling a job, not physical output.
      } else if (action == 'Save image') {
        final saved = await PhotoManager.editor.saveImage(bytes, filename: filename, title: filename);
        Store.instance.ignoreSavedExport(saved.id);
        if (mounted) {
          Haptics.success();
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(context.tr('Saved to Photos', '写真に保存しました'))));
        }
      } else {
        final directory = await getTemporaryDirectory();
        final file = await File('${directory.path}/$filename').writeAsBytes(bytes);
        if (!mounted) return;
        final box = _shareKey.currentContext?.findRenderObject() as RenderBox?;
        await SharePlus.instance.share(ShareParams(
          files: [XFile(file.path, mimeType: 'image/jpeg')],
          sharePositionOrigin: box == null ? null : box.localToGlobal(Offset.zero) & box.size,
        ));
      }
    } catch (_) {
      if (mounted) {
        setState(() => _actionError = action == 'Save image'
          ? context.tr('Could not save. Check photo access in Settings, or use Share image.', '保存できませんでした。設定で写真へのアクセスを確認するか、共有をお試しください。')
          : action == 'Print'
            ? context.tr('Could not open printing. Please try again.', '印刷画面を開けませんでした。もう一度お試しください。')
            : context.tr('Could not share the image. Please try again.', '画像を共有できませんでした。もう一度お試しください。'));
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _details() async {
    final box = _paperKey.currentContext?.findRenderObject() as RenderBox?;
    setState(() {
      _editingPaperSize = box?.size;
      _editingDetails = true;
    });
  }

  void _selectDetail(bool place) {
    if (!_editingDetails) _details();
    setState(() => _editingPlace = place);
    _detailFocus.requestFocus();
  }

  Widget _detailControls() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        Expanded(child: Wrap(children: [
          ModeChoice(context.tr('Title', 'タイトル'), selected: !_editingPlace, onTap: () => _selectDetail(false)),
          ModeChoice(context.tr('Place', '場所'), selected: _editingPlace, onTap: () => _selectDetail(true)),
        ])),
        TextAction(context.tr('Done', '完了'), onTap: () {
          _detailFocus.unfocus();
          setState(() => _editingDetails = false);
        }),
      ]),
      TextField(
        key: const ValueKey('print-detail-input'),
        controller: _editingPlace ? _place : _title,
        focusNode: _detailFocus, maxLength: 60,
        textCapitalization: _editingPlace ? TextCapitalization.words : TextCapitalization.sentences,
        textInputAction: TextInputAction.done,
        decoration: InputDecoration(
          hintText: _editingPlace ? context.tr('Add a place', '場所を入力') : context.tr('Add a title', 'タイトルを入力'), counterText: '', isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _detailFocus.unfocus(),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 4, alignment: WrapAlignment.center, children: [
        _detailOption(context.tr('Date', '日付'), _date, () => setState(() => _date = !_date)),
        if (_palette.isNotEmpty)
          _detailOption(context.tr('Colors', 'カラーバッジ'), _colors, () => setState(() => _colors = !_colors)),
      ]),
    ]),
  );

  Widget _detailOption(String label, bool on, VoidCallback tap) => TextButton(
    onPressed: tap,
    child: Row(mainAxisSize: MainAxisSize.min, children: [
      Icon(on ? Icons.check_circle : Icons.add_circle_outline, size: 16),
      const SizedBox(width: 5), Text(label),
    ]),
  );

  Widget _preview() {
    if (_loading) return const Center(child: CircularProgressIndicator(strokeWidth: 2));
    if (_loadError != null) { return Center(child: Padding(
      padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        Text(_loadError!, style: Txt.body, textAlign: TextAlign.center),
        TextButton(onPressed: _load, child: Text(context.tr('Try again', 'もう一度試す'))),
      ]),
    )); }
    final layout = _previewLayout;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 12, 28, 24),
      child: Center(child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _editingDetails ? (_editingPaperSize?.width ?? double.infinity) : double.infinity,
          maxHeight: _editingDetails ? (_editingPaperSize?.height ?? double.infinity) : double.infinity,
        ),
        child: AspectRatio(
        aspectRatio: layout.size.aspectRatio,
        child: DecoratedBox(
          key: _paperKey,
          decoration: const BoxDecoration(color: Colors.white, boxShadow: [
            BoxShadow(color: Color(0x0C000000), offset: Offset(0, 3), blurRadius: 10),
          ]),
          child: Semantics(label: context.tr('Print preview', '印刷プレビュー'), image: true,
            child: LayoutBuilder(builder: (context, box) {
              final info = layout.informationRect(Size(_photo!.width.toDouble(), _photo!.height.toDouble()));
              return Stack(fit: StackFit.expand, children: [
              CustomPaint(painter: PrintPainter(photo: _photo!, layout: layout, fontFamily: uiFamily, textures: _textures)),
              if (layout.supportsDetails) Positioned(
                left: info.left / layout.size.width * box.maxWidth,
                right: (layout.size.width - info.right) / layout.size.width * box.maxWidth,
                top: info.top / layout.size.height * box.maxHeight,
                height: info.height / layout.size.height * box.maxHeight,
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  Expanded(flex: 8, child: Semantics(button: true, label: context.tr('Edit title on paper', '用紙上のタイトルを編集'),
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _selectDetail(false)))),
                  Expanded(flex: 5, child: FractionallySizedBox(alignment: Alignment.centerLeft, widthFactor: .6,
                    child: Semantics(button: true, label: context.tr('Edit place on paper', '用紙上の場所を編集'),
                      child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _selectDetail(true))))),
                ]),
              ),
            ]); })),
        ),
      ))),
    );
  }

  Widget _controls() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(children: [
        Text(context.tr('Paper', '用紙'), style: Txt.label),
        const SizedBox(width: 20),
        Expanded(child: DropdownButton<PrintPaper>(
          isExpanded: true, value: _paper, underline: const SizedBox.shrink(),
          items: PrintPaper.values.map((p) {
            final width = _landscape ? p.height : p.width;
            final height = _landscape ? p.width : p.height;
            final precision = p == PrintPaper.postcard ? 1 : 0;
            return DropdownMenuItem(value: p,
              child: Text('${p.label}  /  ${width.toStringAsFixed(precision)} x ${height.toStringAsFixed(precision)} mm', style: Txt.small));
          }).toList(),
          onChanged: (p) { if (p != null) setState(() => _paper = p); },
        )),
        IconButton(tooltip: _landscape ? context.tr('Use portrait paper', '用紙を縦向きにする') : context.tr('Use landscape paper', '用紙を横向きにする'),
          onPressed: () => setState(() {
            _orientationChosen = true;
            _landscape = !_landscape;
          }),
          icon: const Icon(Icons.crop_rotate, size: 22)),
      ]),
      const Hairline(),
      Wrap(alignment: WrapAlignment.center, children: [
        for (final style in PrintStyle.values)
          ModeChoice(context.tr(style.label, switch (style) {
            PrintStyle.photo => '写真のみ', PrintStyle.instant => '余白あり', PrintStyle.fullPhoto => '写真いっぱい',
          }), selected: _style == style,
            onTap: () => setState(() => _style = style)),
      ]),
      Row(children: [
        if (!_layout.overlaysPhoto) ModeChoice(context.tr('Fit', '全体を収める'), selected: !_fill, onTap: () => setState(() => _fill = false)),
        if (!_layout.overlaysPhoto) ModeChoice(context.tr('Fill', '枠を埋める'), selected: _fill, onTap: () => setState(() => _fill = true)),
        if (_layout.supportsDetails) Expanded(child: Align(alignment: Alignment.centerRight,
          child: TextButton(onPressed: _details,
            child: Text(_layout.hasDetails ? context.tr('Edit details', '文字・バッジを編集') : context.tr('Add details', '文字・バッジを追加'), textAlign: TextAlign.end)))),
      ]),
      if (_layout.cropsPhoto) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text(context.tr('The photo is cropped to the area shown.', '表示されている範囲で写真が切り取られます。'), style: Txt.small))
      else if (!_layout.supportsDetails) Padding(padding: const EdgeInsets.only(top: 8),
        child: Text(context.tr('Keeps your full photo. White space may remain to fit the paper.', '写真全体を収めます。用紙との比率によって余白ができます。'), style: Txt.small)),
      if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 12),
        child: Semantics(liveRegion: true, child: Text(_actionError!, style: Txt.body))),
      const SizedBox(height: 16),
      FilledButton(
        style: FilledButton.styleFrom(backgroundColor: Neutral.primary, foregroundColor: Colors.white,
          minimumSize: const Size(44, 48), shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))),
        onPressed: _photo == null || _busy != null ? null : () => _output('Print'),
        child: Text(_busy == 'Print' ? context.tr('Preparing print...', '印刷を準備中…') : context.tr('Print', '印刷')),
      ),
      Row(children: [
        Expanded(child: TextButton(onPressed: _photo == null || _busy != null ? null : () => _output('Save image'),
          child: Text(_busy == 'Save image' ? context.tr('Saving...', '保存中…') : context.tr('Save image', '画像を保存')))),
        Expanded(child: TextButton(key: _shareKey, onPressed: _photo == null || _busy != null ? null : () => _output('Share image'),
          child: Text(_busy == 'Share image' ? context.tr('Preparing...', '準備中…') : context.tr('Share image', '画像を共有')))),
      ]),
    ]),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _busy == null,
    child: Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(title: Text(context.tr('Print', '印刷'), style: Txt.title), centerTitle: true,
        backgroundColor: Colors.white, surfaceTintColor: Colors.transparent,
        leadingWidth: 72,
        leading: TextAction(context.tr('Back', '戻る'), color: Neutral.secondary,
          onTap: _busy == null ? () => Navigator.pop(context) : null)),
      body: SafeArea(top: false, child: LayoutBuilder(builder: (context, constraints) {
        final controls = AbsorbPointer(absorbing: _busy != null, child: _editingDetails ? _detailControls() : _controls());
        if (constraints.maxWidth > constraints.maxHeight && constraints.maxWidth > 600) {
          return Row(children: [Expanded(child: _preview()), SizedBox(width: 340, child: controls)]);
        }
        return Column(children: [
          Expanded(child: _preview()),
          ConstrainedBox(constraints: BoxConstraints(maxHeight: constraints.maxHeight * 0.58), child: controls),
        ]);
      })),
    ),
  );
}
