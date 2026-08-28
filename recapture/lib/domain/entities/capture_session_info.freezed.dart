// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'capture_session_info.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$CaptureSessionInfo {
  String get status => throw _privateConstructorUsedError;
  String get sessionId => throw _privateConstructorUsedError;

  /// Create a copy of CaptureSessionInfo
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $CaptureSessionInfoCopyWith<CaptureSessionInfo> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $CaptureSessionInfoCopyWith<$Res> {
  factory $CaptureSessionInfoCopyWith(
          CaptureSessionInfo value, $Res Function(CaptureSessionInfo) then) =
      _$CaptureSessionInfoCopyWithImpl<$Res, CaptureSessionInfo>;
  @useResult
  $Res call({String status, String sessionId});
}

/// @nodoc
class _$CaptureSessionInfoCopyWithImpl<$Res, $Val extends CaptureSessionInfo>
    implements $CaptureSessionInfoCopyWith<$Res> {
  _$CaptureSessionInfoCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of CaptureSessionInfo
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? sessionId = null,
  }) {
    return _then(_value.copyWith(
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as String,
      sessionId: null == sessionId
          ? _value.sessionId
          : sessionId // ignore: cast_nullable_to_non_nullable
              as String,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$CaptureSessionInfoImplCopyWith<$Res>
    implements $CaptureSessionInfoCopyWith<$Res> {
  factory _$$CaptureSessionInfoImplCopyWith(_$CaptureSessionInfoImpl value,
          $Res Function(_$CaptureSessionInfoImpl) then) =
      __$$CaptureSessionInfoImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call({String status, String sessionId});
}

/// @nodoc
class __$$CaptureSessionInfoImplCopyWithImpl<$Res>
    extends _$CaptureSessionInfoCopyWithImpl<$Res, _$CaptureSessionInfoImpl>
    implements _$$CaptureSessionInfoImplCopyWith<$Res> {
  __$$CaptureSessionInfoImplCopyWithImpl(_$CaptureSessionInfoImpl _value,
      $Res Function(_$CaptureSessionInfoImpl) _then)
      : super(_value, _then);

  /// Create a copy of CaptureSessionInfo
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? status = null,
    Object? sessionId = null,
  }) {
    return _then(_$CaptureSessionInfoImpl(
      status: null == status
          ? _value.status
          : status // ignore: cast_nullable_to_non_nullable
              as String,
      sessionId: null == sessionId
          ? _value.sessionId
          : sessionId // ignore: cast_nullable_to_non_nullable
              as String,
    ));
  }
}

/// @nodoc

class _$CaptureSessionInfoImpl implements _CaptureSessionInfo {
  const _$CaptureSessionInfoImpl(
      {required this.status, required this.sessionId});

  @override
  final String status;
  @override
  final String sessionId;

  @override
  String toString() {
    return 'CaptureSessionInfo(status: $status, sessionId: $sessionId)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$CaptureSessionInfoImpl &&
            (identical(other.status, status) || other.status == status) &&
            (identical(other.sessionId, sessionId) ||
                other.sessionId == sessionId));
  }

  @override
  int get hashCode => Object.hash(runtimeType, status, sessionId);

  /// Create a copy of CaptureSessionInfo
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$CaptureSessionInfoImplCopyWith<_$CaptureSessionInfoImpl> get copyWith =>
      __$$CaptureSessionInfoImplCopyWithImpl<_$CaptureSessionInfoImpl>(
          this, _$identity);
}

abstract class _CaptureSessionInfo implements CaptureSessionInfo {
  const factory _CaptureSessionInfo(
      {required final String status,
      required final String sessionId}) = _$CaptureSessionInfoImpl;

  @override
  String get status;
  @override
  String get sessionId;

  /// Create a copy of CaptureSessionInfo
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$CaptureSessionInfoImplCopyWith<_$CaptureSessionInfoImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
