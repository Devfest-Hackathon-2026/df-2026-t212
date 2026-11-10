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
import '../core/renderer.dart';
import '../data/print_export.dart';
import '../data/store.dart';
import 'theme.dart';
import 'widgets/common.dart';

class PrintScreen extends StatefulWidget {
  const PrintScreen({super.key, required this.loadPhoto, required this.colors, required this.taken});

  factory PrintScreen.forPhoto(PhotoItem photo) => PrintScreen(
    loadPhoto: () => loadPrintPhoto(photo),
    colors: photo.hues.map((c) {
      final rgb = oklabToRgb8(c.l, c.a, c.b);
      return Color.fromARGB(255, rgb[0], rgb[1], rgb[2]);
    }).toList(),
    taken: photo.taken,
  );

  final Future<Uint8List> Function() loadPhoto;
  final List<Color> colors;
  final DateTime taken;

  @override
  State<PrintScreen> createState() => _PrintScreenState();
}

class _PrintScreenState extends State<PrintScreen> {
  ui.Image? _photo;
  String? _loadError, _actionError;
  String? _busy;
  bool _loading = true;
  PrintStyle _style = PrintStyle.photo;
  PrintPaper _paper = PrintPaper.l;
  bool _landscape = false, _fill = false, _colors = false, _date = false;
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
    colors: widget.colors.take(6).toList(), showColors: _colors,
  );

  PrintLayout get _previewLayout => !_editingDetails ? _layout : PrintLayout(
    style: _style, paper: _paper, landscape: _landscape, fill: _fill,
    title: _title.text.trim().isEmpty ? 'Add a title' : _title.text,
    place: _place.text.trim().isEmpty ? 'Add a place' : _place.text,
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
      final codec = await ui.instantiateImageCodec(await widget.loadPhoto());
      final frame = await codec.getNextFrame();
      codec.dispose();
      if (!mounted) { frame.image.dispose(); return; }
      setState(() {
        _photo = frame.image;
        _landscape = frame.image.width > frame.image.height;
      });
    } catch (_) {
      if (mounted) setState(() => _loadError = 'Could not load this photo. Check that the original is available and try again.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _photo?.dispose();
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
      final bytes = await exportPrintImage(_photo!, layout, fontFamily: uiFamily);
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
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Saved to Photos')));
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
          ? 'Could not save. Check photo access in Settings, or use Share image.'
          : 'Could not ${action == 'Print' ? 'open printing' : 'share the image'}. Please try again.');
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
    setState(() => _editingPlace = place);
    _detailFocus.requestFocus();
  }

  Widget _detailControls() => Padding(
    padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
    child: Column(mainAxisSize: MainAxisSize.min, children: [
      Row(children: [
        ModeChoice('Title', selected: !_editingPlace, onTap: () => _selectDetail(false)),
        ModeChoice('Place', selected: _editingPlace, onTap: () => _selectDetail(true)),
        const Spacer(),
        TextAction('Done', onTap: () {
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
          hintText: _editingPlace ? 'Add a place' : 'Add a title', counterText: '', isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        ),
        onChanged: (_) => setState(() {}),
        onSubmitted: (_) => _detailFocus.unfocus(),
      ),
      const SizedBox(height: 4),
      Wrap(spacing: 4, alignment: WrapAlignment.center, children: [
        _detailOption('Date', _date, () => setState(() => _date = !_date)),
        if (widget.colors.isNotEmpty)
          _detailOption('Colors', _colors, () => setState(() => _colors = !_colors)),
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
        TextButton(onPressed: _load, child: const Text('Try again')),
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
            BoxShadow(color: Color(0x18000000), offset: Offset(0, 8), blurRadius: 20),
          ]),
          child: Semantics(label: 'Print preview', image: true,
            child: LayoutBuilder(builder: (context, box) => Stack(fit: StackFit.expand, children: [
              CustomPaint(painter: PrintPainter(photo: _photo!, layout: layout, fontFamily: uiFamily)),
              if (_editingDetails) Positioned(
                left: layout.inset / layout.size.width * box.maxWidth,
                right: layout.inset / layout.size.width * box.maxWidth,
                top: (layout.photoRect.bottom + 1) / layout.size.height * box.maxHeight,
                height: 44,
                child: Row(children: [
                  Expanded(flex: 65, child: Semantics(button: true, label: 'Edit title on paper',
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _selectDetail(false)))),
                  Expanded(flex: 35, child: Semantics(button: true, label: 'Edit place on paper',
                    child: GestureDetector(behavior: HitTestBehavior.opaque, onTap: () => _selectDetail(true)))),
                ]),
              ),
            ]))),
        ),
      ))),
    );
  }

  Widget _controls() => SingleChildScrollView(
    padding: const EdgeInsets.fromLTRB(24, 0, 24, 16),
    child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [
        for (final style in PrintStyle.values)
          ModeChoice(style == PrintStyle.photo ? 'Photo' : 'Instant', selected: _style == style,
            onTap: () => setState(() => _style = style)),
      ]),
      const Hairline(),
      Row(children: [
        Text('Paper', style: Txt.label),
        const SizedBox(width: 20),
        Expanded(child: DropdownButton<PrintPaper>(
          isExpanded: true, value: _paper, underline: const SizedBox.shrink(),
          items: PrintPaper.values.map((p) => DropdownMenuItem(value: p,
            child: Text('${p.label}  /  ${p.width.toStringAsFixed(p == PrintPaper.postcard ? 1 : 0)} x ${p.height.toStringAsFixed(p == PrintPaper.postcard ? 1 : 0)} mm', style: Txt.small))).toList(),
          onChanged: (p) { if (p != null) setState(() => _paper = p); },
        )),
        IconButton(tooltip: _landscape ? 'Use portrait paper' : 'Use landscape paper',
          onPressed: () => setState(() => _landscape = !_landscape),
          icon: const Icon(Icons.crop_rotate, size: 22)),
      ]),
      Row(children: [
        ModeChoice('Fit', selected: !_fill, onTap: () => setState(() => _fill = false)),
        ModeChoice('Fill', selected: _fill, onTap: () => setState(() => _fill = true)),
        Expanded(child: Align(alignment: Alignment.centerRight,
          child: TextButton(onPressed: _details,
            child: Text(_layout.hasDetails ? 'Edit details' : 'Add details', textAlign: TextAlign.end)))),
      ]),
      const SizedBox(height: 12),
      Text(_fill ? 'Fill crops the photo to the area shown.' : 'The whole photo stays in view.', style: Txt.small),
      if (_actionError != null) Padding(padding: const EdgeInsets.only(top: 12),
        child: Semantics(liveRegion: true, child: Text(_actionError!, style: Txt.body))),
      const SizedBox(height: 16),
      FilledButton(
        onPressed: _photo == null || _busy != null ? null : () => _output('Print'),
        child: Text(_busy == 'Print' ? 'Preparing print...' : 'Print'),
      ),
      Row(children: [
        Expanded(child: TextButton(onPressed: _photo == null || _busy != null ? null : () => _output('Save image'),
          child: Text(_busy == 'Save image' ? 'Saving...' : 'Save image'))),
        Expanded(child: TextButton(key: _shareKey, onPressed: _photo == null || _busy != null ? null : () => _output('Share image'),
          child: Text(_busy == 'Share image' ? 'Preparing...' : 'Share image'))),
      ]),
    ]),
  );

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: _busy == null,
    child: Scaffold(
      appBar: AppBar(title: Text('Print', style: Txt.title), centerTitle: true,
        leadingWidth: 72,
        leading: TextAction('Back', color: Neutral.secondary,
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
