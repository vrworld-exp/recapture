// test/offline/offline_action_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:recapture/domain/entities/offline_action.dart';

void main() {
  group('OfflineAction.toMap/fromMap', () {
    test('round-trips a well-formed action', () {
      final action = OfflineAction(
        id: 'abc',
        type: OfflineActionType.renameProject,
        payload: const {'projectId': 'p1', 'newName': 'Sofa'},
        createdAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
        attempts: 2,
      );
      final back = OfflineAction.fromMap(action.toMap());
      expect(back.id, 'abc');
      expect(back.type, OfflineActionType.renameProject);
      expect(back.payload, {'projectId': 'p1', 'newName': 'Sofa'});
      expect(back.createdAt, DateTime.utc(2026, 1, 2, 3, 4, 5));
      expect(back.attempts, 2);
    });

    test('createdAt is serialized in UTC', () {
      final action = OfflineAction(
        id: 'x',
        type: OfflineActionType.deleteProject,
        payload: const {},
        createdAt: DateTime.utc(2026, 6, 14, 12),
      );
      expect(action.toMap()['createdAt'], '2026-06-14T12:00:00.000Z');
    });

    test('unknown type string maps to OfflineActionType.unknown', () {
      final back = OfflineAction.fromMap({
        'id': 'y',
        'type': 'somethingFromANewerAppVersion',
        'payload': const {},
        'createdAt': DateTime.utc(2026).toIso8601String(),
        'attempts': 0,
      });
      expect(back.type, OfflineActionType.unknown);
    });

    test('missing fields degrade to safe defaults (no throw)', () {
      final back = OfflineAction.fromMap(const {});
      expect(back.id, isNotEmpty); // generated
      expect(back.type, OfflineActionType.unknown);
      expect(back.payload, isEmpty);
      expect(back.attempts, 0);
      expect(back.createdAt.isUtc, isTrue);
    });
  });

  test('incremented() bumps attempts and preserves the rest', () {
    final action = OfflineAction(
      id: 'id1',
      type: OfflineActionType.retryProject,
      payload: const {'projectId': 'p9'},
      createdAt: DateTime.utc(2026),
      attempts: 1,
    );
    final next = action.incremented();
    expect(next.attempts, 2);
    expect(next.id, 'id1');
    expect(next.type, OfflineActionType.retryProject);
    expect(next.payload, {'projectId': 'p9'});
    expect(next.createdAt, action.createdAt);
  });

  test('newId() returns distinct ids', () {
    final ids = {for (var i = 0; i < 100; i++) OfflineAction.newId()};
    expect(ids.length, 100);
  });

  test('analyticsValue maps each type to snake_case', () {
    expect(OfflineActionType.renameProject.analyticsValue, 'rename_project');
    expect(OfflineActionType.deleteProject.analyticsValue, 'delete_project');
    expect(OfflineActionType.retryProject.analyticsValue, 'retry_project');
    expect(OfflineActionType.unknown.analyticsValue, 'unknown');
  });
}
