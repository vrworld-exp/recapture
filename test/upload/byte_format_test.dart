// test/upload/byte_format_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/utils/byte_format.dart';

void main() {
  test('bytesToMb: guarded, never NaN/negative', () {
    expect(bytesToMb(0), 0.0);
    expect(bytesToMb(-100), 0.0);
    expect(bytesToMb(kBytesPerMb), 1.0);
    expect(bytesToMb(kBytesPerMb ~/ 2), closeTo(0.5, 1e-9));
  });

  test('formatMb: one-decimal precision', () {
    expect(formatMb(0), '0.0');
    expect(formatMb(kBytesPerMb), '1.0');
    expect(formatMb((42.5 * kBytesPerMb).round()), '42.5');
  });

  test('formatMbProgress: clamps uploaded into [0,total]', () {
    expect(formatMbProgress(0, 110 * kBytesPerMb), '0.0 / 110.0 MB');
    expect(formatMbProgress(55 * kBytesPerMb, 110 * kBytesPerMb),
        '55.0 / 110.0 MB');
    // Transient over-report clamps to the total.
    expect(formatMbProgress(200 * kBytesPerMb, 110 * kBytesPerMb),
        '110.0 / 110.0 MB');
    // Negative guarded.
    expect(formatMbProgress(-5, -5), '0.0 / 0.0 MB');
  });
}
