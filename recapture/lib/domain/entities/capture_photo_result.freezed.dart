// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'capture_photo_result.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$CapturePhotoResult {
  String get filePath => throw _privateConstructorUsedError;

  /// Capture timestamp, converted from native milliseconds-since-epoch.
  DateTime get timestamp => throw _privateConstructorUsedError;

  /// Laplacian variance blur score.
  /// <40 = reject, 40-80 = warn, >80 = accept (per PRD thresholds).
  double get blurScore => throw _privateConstructorUsedError;

  /// Whether this photo passed quality checks and counts toward
  /// the ring segment coverage.
  bool get accepted => throw _privateConstructorUsedError;

  /// Create a copy of CapturePhotoResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $CapturePhotoResultCopyWith<CapturePhotoResult> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $CapturePhotoResultCopyWith<$Res> {
  factory $CapturePhotoResultCopyWith(
          CapturePhotoResult value, $Res Function(CapturePhotoResult) then) =
      _$CapturePhotoResultCopyWithImpl<$Res, CapturePhotoResult>;
  @useResult
  $Res call(
      {String filePath, DateTime timestamp, double blurScore, bool accepted});
}

/// @nodoc
class _$CapturePhotoResultCopyWithImpl<$Res, $Val extends CapturePhotoResult>
    implements $CapturePhotoResultCopyWith<$Res> {
  _$CapturePhotoResultCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of CapturePhotoResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? filePath = null,
    Object? timestamp = null,
    Object? blurScore = null,
    Object? accepted = null,
  }) {
    return _then(_value.copyWith(
      filePath: null == filePath
          ? _value.filePath
          : filePath // ignore: cast_nullable_to_non_nullable
              as String,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
      blurScore: null == blurScore
          ? _value.blurScore
          : blurScore // ignore: cast_nullable_to_non_nullable
              as double,
      accepted: null == accepted
          ? _value.accepted
          : accepted // ignore: cast_nullable_to_non_nullable
              as bool,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$CapturePhotoResultImplCopyWith<$Res>
    implements $CapturePhotoResultCopyWith<$Res> {
  factory _$$CapturePhotoResultImplCopyWith(_$CapturePhotoResultImpl value,
          $Res Function(_$CapturePhotoResultImpl) then) =
      __$$CapturePhotoResultImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {String filePath, DateTime timestamp, double blurScore, bool accepted});
}

/// @nodoc
class __$$CapturePhotoResultImplCopyWithImpl<$Res>
    extends _$CapturePhotoResultCopyWithImpl<$Res, _$CapturePhotoResultImpl>
    implements _$$CapturePhotoResultImplCopyWith<$Res> {
  __$$CapturePhotoResultImplCopyWithImpl(_$CapturePhotoResultImpl _value,
      $Res Function(_$CapturePhotoResultImpl) _then)
      : super(_value, _then);

  /// Create a copy of CapturePhotoResult
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? filePath = null,
    Object? timestamp = null,
    Object? blurScore = null,
    Object? accepted = null,
  }) {
    return _then(_$CapturePhotoResultImpl(
      filePath: null == filePath
          ? _value.filePath
          : filePath // ignore: cast_nullable_to_non_nullable
              as String,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
      blurScore: null == blurScore
          ? _value.blurScore
          : blurScore // ignore: cast_nullable_to_non_nullable
              as double,
      accepted: null == accepted
          ? _value.accepted
          : accepted // ignore: cast_nullable_to_non_nullable
              as bool,
    ));
  }
}

/// @nodoc

class _$CapturePhotoResultImpl implements _CapturePhotoResult {
  const _$CapturePhotoResultImpl(
      {required this.filePath,
      required this.timestamp,
      required this.blurScore,
      required this.accepted});

  @override
  final String filePath;

  /// Capture timestamp, converted from native milliseconds-since-epoch.
  @override
  final DateTime timestamp;

  /// Laplacian variance blur score.
  /// <40 = reject, 40-80 = warn, >80 = accept (per PRD thresholds).
  @override
  final double blurScore;

  /// Whether this photo passed quality checks and counts toward
  /// the ring segment coverage.
  @override
  final bool accepted;

  @override
  String toString() {
    return 'CapturePhotoResult(filePath: $filePath, timestamp: $timestamp, blurScore: $blurScore, accepted: $accepted)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$CapturePhotoResultImpl &&
            (identical(other.filePath, filePath) ||
                other.filePath == filePath) &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp) &&
            (identical(other.blurScore, blurScore) ||
                other.blurScore == blurScore) &&
            (identical(other.accepted, accepted) ||
                other.accepted == accepted));
  }

  @override
  int get hashCode =>
      Object.hash(runtimeType, filePath, timestamp, blurScore, accepted);

  /// Create a copy of CapturePhotoResult
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$CapturePhotoResultImplCopyWith<_$CapturePhotoResultImpl> get copyWith =>
      __$$CapturePhotoResultImplCopyWithImpl<_$CapturePhotoResultImpl>(
          this, _$identity);
}

abstract class _CapturePhotoResult implements CapturePhotoResult {
  const factory _CapturePhotoResult(
      {required final String filePath,
      required final DateTime timestamp,
      required final double blurScore,
      required final bool accepted}) = _$CapturePhotoResultImpl;

  @override
  String get filePath;

  /// Capture timestamp, converted from native milliseconds-since-epoch.
  @override
  DateTime get timestamp;

  /// Laplacian variance blur score.
  /// <40 = reject, 40-80 = warn, >80 = accept (per PRD thresholds).
  @override
  double get blurScore;

  /// Whether this photo passed quality checks and counts toward
  /// the ring segment coverage.
  @override
  bool get accepted;

  /// Create a copy of CapturePhotoResult
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$CapturePhotoResultImplCopyWith<_$CapturePhotoResultImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
