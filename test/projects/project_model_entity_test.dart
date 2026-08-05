// test/projects/project_model_entity_test.dart
//
// ProjectModelView parsing of the USDZ artifact (iOS AR Quick Look's format)
// from BOTH backend shapes:
//   • staff (`/admin/projects/:id/models`): URLs nested under `artifacts`;
//   • owner (`GET /projects/:id` → `model`): flat `usdzUrl`.
// The USDZ is an AR enhancement only — many Meshy runs don't produce one —
// so `isViewable` must stay keyed on the GLB alone.
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/project_model.dart';

void main() {
  group('tryFromStaffMap — artifacts.usdz', () {
    Map<String, Object?> staff({Map<String, Object?>? artifacts}) => {
          'id': 'm1',
          'source': 'meshy',
          'status': 'SUCCEEDED',
          if (artifacts != null) 'artifacts': artifacts,
        };

    test('parses usdz alongside glb', () {
      final model = ProjectModelView.tryFromStaffMap(staff(artifacts: {
        'glb': 'https://cdn/model.glb',
        'usdz': 'https://cdn/model.usdz',
      }));

      expect(model?.glbUrl, 'https://cdn/model.glb');
      expect(model?.usdzUrl, 'https://cdn/model.usdz');
    });

    test('absent usdz → null, and the model stays viewable on GLB alone', () {
      final model = ProjectModelView.tryFromStaffMap(
        staff(artifacts: {'glb': 'https://cdn/model.glb'}),
      );

      expect(model?.usdzUrl, isNull);
      expect(model?.isViewable, isTrue);
    });

    test('no artifacts map at all → both urls null, not viewable', () {
      final model = ProjectModelView.tryFromStaffMap(staff());

      expect(model?.glbUrl, isNull);
      expect(model?.usdzUrl, isNull);
      expect(model?.isViewable, isFalse);
    });
  });

  group('tryFromStaffMap — progress (live worker sub-status)', () {
    test('parses phase + percent', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'PROCESSING',
        'progress': {'phase': 'GENERATING', 'percent': 42},
      });

      expect(model?.progress?.phase, ModelProgressPhase.generating);
      expect(model?.progress?.percent, 42);
    });

    test('absent progress → null (older backend / QUEUED record)', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'PROCESSING',
      });

      expect(model?.progress, isNull);
    });

    test('unknown phase and out-of-range percent degrade, never throw', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'PROCESSING',
        'progress': {'phase': 'SOMETHING_NEW', 'percent': 250},
      });

      expect(model?.progress?.phase, ModelProgressPhase.unknown);
      expect(model?.progress?.percent, 100);
    });
  });

  group('tryFromOwnerMap — flat usdzUrl', () {
    test('parses usdzUrl alongside glbUrl', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'meshy',
        'glbUrl': 'https://cdn/model.glb',
        'usdzUrl': 'https://cdn/model.usdz',
      });

      expect(model?.glbUrl, 'https://cdn/model.glb');
      expect(model?.usdzUrl, 'https://cdn/model.usdz');
    });

    test('absent usdzUrl → null, and the model stays viewable', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'meshy',
        'glbUrl': 'https://cdn/model.glb',
      });

      expect(model?.usdzUrl, isNull);
      expect(model?.isViewable, isTrue);
    });

    test('a USDZ without a GLB is still not parseable — GLB is mandatory', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'meshy',
        'usdzUrl': 'https://cdn/model.usdz',
      });

      expect(model, isNull);
    });
  });

  // `optimizationPending` is the flag that tells a SUCCEEDED model apart from a
  // FINISHED one: the asset pipeline runs as a second job, and until it lands
  // both shapes' URLs still point at the untouched original.
  group('optimizationPending', () {
    test('staff shape carries the flag', () {
      final model = ProjectModelView.tryFromStaffMap({
        'id': 'm1',
        'source': 'meshy',
        'status': 'SUCCEEDED',
        'artifacts': {'glb': 'https://cdn/model.glb'},
        'optimizationPending': true,
      });

      expect(model?.optimizationPending, isTrue);
      // Openable, but not something to open yet.
      expect(model?.isViewable, isTrue);
      expect(model?.isSettled, isFalse);
    });

    test('owner shape carries the flag', () {
      final model = ProjectModelView.tryFromOwnerMap({
        'id': 'm1',
        'source': 'meshy',
        'glbUrl': 'https://cdn/model.glb',
        'optimizationPending': true,
      });

      expect(model?.optimizationPending, isTrue);
      expect(model?.isSettled, isFalse);
    });

    // A backend that predates the flag, and every record generated before the
    // pipeline existed, must read as settled — nothing is ever going to write
    // an optimization for them, so waiting would be waiting forever.
    test('absent reads as settled, on both shapes', () {
      expect(
        ProjectModelView.tryFromStaffMap({
          'id': 'm1',
          'source': 'meshy',
          'status': 'SUCCEEDED',
          'artifacts': {'glb': 'https://cdn/model.glb'},
        })?.isSettled,
        isTrue,
      );
      expect(
        ProjectModelView.tryFromOwnerMap({
          'id': 'm1',
          'source': 'meshy',
          'glbUrl': 'https://cdn/model.glb',
        })?.isSettled,
        isTrue,
      );
    });
  });
}
