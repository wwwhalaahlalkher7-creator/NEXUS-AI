import 'package:material_ui/material_ui.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import 'peer_discovery.dart';

class PairingQrScannerPage extends StatefulWidget {
  const PairingQrScannerPage({super.key});

  @override
  State<PairingQrScannerPage> createState() => _PairingQrScannerPageState();
}

class _PairingQrScannerPageState extends State<PairingQrScannerPage> {
  bool _completed = false;
  String? _message;

  void _handleDetection(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      final raw = barcode.rawValue;
      if (raw == null || raw.isEmpty) continue;
      try {
        final invite = PairingInvitePayload.decode(raw);
        _completed = true;
        Navigator.of(context).pop(invite);
        return;
      } on FormatException catch (error) {
        if (raw.startsWith(pairingQrPrefix) && mounted) {
          setState(() => _message = error.message);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مسح دعوة NEXUS')),
      body: SafeArea(
        child: Column(
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 18, 20, 12),
              child: Text(
                'وجّه الكاميرا إلى رمز QR الذي يعرضه الجهاز المستضيف. لن يبدأ الاتصال قبل مراجعة بيانات الدعوة والموافقة عليها.',
                textAlign: TextAlign.center,
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.all(20),
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(20),
                  child: MobileScanner(onDetect: _handleDetection),
                ),
              ),
            ),
            if (_message != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: Text(
                  _message!,
                  textAlign: TextAlign.center,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 24),
              child: Text(
                'تحقق من اسم الجهاز الذي تظهره شاشة التأكيد قبل المتابعة.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
