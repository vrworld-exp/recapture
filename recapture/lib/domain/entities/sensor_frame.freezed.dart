// coverage:ignore-file
// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'sensor_frame.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

T _$identity<T>(T value) => value;

final _privateConstructorUsedError = UnsupportedError(
    'It seems like you constructed your class using `MyClass._()`. This constructor is only meant to be used by freezed and you are not supposed to need it nor use it.\nPlease check the documentation here for more information: https://github.com/rrousselGit/freezed#adding-getters-and-methods-to-our-models');

/// @nodoc
mixin _$SensorFrame {
  /// Yaw angle in degrees.
  double get yaw => throw _privateConstructorUsedError;

  /// Camera elevation angle in degrees.
  /// 0° = horizontal, positive = downward, negative = upward.
  double get pitch => throw _privateConstructorUsedError;

  /// Roll angle in degrees. Roll constraint: ±15° (warn, don't block).
  double get roll => throw _privateConstructorUsedError;

  /// Gyroscope magnitude in rad/s.
  /// Stability gate: must be < 0.8 rad/s for 250ms before capture.
  double get gyroMagnitude => throw _privateConstructorUsedError;

  /// Linear acceleration magnitude in g.
  /// Stability gate: must be < 0.15g for 250ms before capture.
  double get accelMagnitude => throw _privateConstructorUsedError;

  /// Sensor reading timestamp, converted from native ms-since-epoch.
  DateTime get timestamp => throw _privateConstructorUsedError;

  /// Create a copy of SensorFrame
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  $SensorFrameCopyWith<SensorFrame> get copyWith =>
      throw _privateConstructorUsedError;
}

/// @nodoc
abstract class $SensorFrameCopyWith<$Res> {
  factory $SensorFrameCopyWith(
          SensorFrame value, $Res Function(SensorFrame) then) =
      _$SensorFrameCopyWithImpl<$Res, SensorFrame>;
  @useResult
  $Res call(
      {double yaw,
      double pitch,
      double roll,
      double gyroMagnitude,
      double accelMagnitude,
      DateTime timestamp});
}

/// @nodoc
class _$SensorFrameCopyWithImpl<$Res, $Val extends SensorFrame>
    implements $SensorFrameCopyWith<$Res> {
  _$SensorFrameCopyWithImpl(this._value, this._then);

  // ignore: unused_field
  final $Val _value;
  // ignore: unused_field
  final $Res Function($Val) _then;

  /// Create a copy of SensorFrame
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? yaw = null,
    Object? pitch = null,
    Object? roll = null,
    Object? gyroMagnitude = null,
    Object? accelMagnitude = null,
    Object? timestamp = null,
  }) {
    return _then(_value.copyWith(
      yaw: null == yaw
          ? _value.yaw
          : yaw // ignore: cast_nullable_to_non_nullable
              as double,
      pitch: null == pitch
          ? _value.pitch
          : pitch // ignore: cast_nullable_to_non_nullable
              as double,
      roll: null == roll
          ? _value.roll
          : roll // ignore: cast_nullable_to_non_nullable
              as double,
      gyroMagnitude: null == gyroMagnitude
          ? _value.gyroMagnitude
          : gyroMagnitude // ignore: cast_nullable_to_non_nullable
              as double,
      accelMagnitude: null == accelMagnitude
          ? _value.accelMagnitude
          : accelMagnitude // ignore: cast_nullable_to_non_nullable
              as double,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
    ) as $Val);
  }
}

/// @nodoc
abstract class _$$SensorFrameImplCopyWith<$Res>
    implements $SensorFrameCopyWith<$Res> {
  factory _$$SensorFrameImplCopyWith(
          _$SensorFrameImpl value, $Res Function(_$SensorFrameImpl) then) =
      __$$SensorFrameImplCopyWithImpl<$Res>;
  @override
  @useResult
  $Res call(
      {double yaw,
      double pitch,
      double roll,
      double gyroMagnitude,
      double accelMagnitude,
      DateTime timestamp});
}

/// @nodoc
class __$$SensorFrameImplCopyWithImpl<$Res>
    extends _$SensorFrameCopyWithImpl<$Res, _$SensorFrameImpl>
    implements _$$SensorFrameImplCopyWith<$Res> {
  __$$SensorFrameImplCopyWithImpl(
      _$SensorFrameImpl _value, $Res Function(_$SensorFrameImpl) _then)
      : super(_value, _then);

  /// Create a copy of SensorFrame
  /// with the given fields replaced by the non-null parameter values.
  @pragma('vm:prefer-inline')
  @override
  $Res call({
    Object? yaw = null,
    Object? pitch = null,
    Object? roll = null,
    Object? gyroMagnitude = null,
    Object? accelMagnitude = null,
    Object? timestamp = null,
  }) {
    return _then(_$SensorFrameImpl(
      yaw: null == yaw
          ? _value.yaw
          : yaw // ignore: cast_nullable_to_non_nullable
              as double,
      pitch: null == pitch
          ? _value.pitch
          : pitch // ignore: cast_nullable_to_non_nullable
              as double,
      roll: null == roll
          ? _value.roll
          : roll // ignore: cast_nullable_to_non_nullable
              as double,
      gyroMagnitude: null == gyroMagnitude
          ? _value.gyroMagnitude
          : gyroMagnitude // ignore: cast_nullable_to_non_nullable
              as double,
      accelMagnitude: null == accelMagnitude
          ? _value.accelMagnitude
          : accelMagnitude // ignore: cast_nullable_to_non_nullable
              as double,
      timestamp: null == timestamp
          ? _value.timestamp
          : timestamp // ignore: cast_nullable_to_non_nullable
              as DateTime,
    ));
  }
}

/// @nodoc

class _$SensorFrameImpl implements _SensorFrame {
  const _$SensorFrameImpl(
      {required this.yaw,
      required this.pitch,
      required this.roll,
      required this.gyroMagnitude,
      required this.accelMagnitude,
      required this.timestamp});

  /// Yaw angle in degrees.
  @override
  final double yaw;

  /// Camera elevation angle in degrees.
  /// 0° = horizontal, positive = downward, negative = upward.
  @override
  final double pitch;

  /// Roll angle in degrees. Roll constraint: ±15° (warn, don't block).
  @override
  final double roll;

  /// Gyroscope magnitude in rad/s.
  /// Stability gate: must be < 0.8 rad/s for 250ms before capture.
  @override
  final double gyroMagnitude;

  /// Linear acceleration magnitude in g.
  /// Stability gate: must be < 0.15g for 250ms before capture.
  @override
  final double accelMagnitude;

  /// Sensor reading timestamp, converted from native ms-since-epoch.
  @override
  final DateTime timestamp;

  @override
  String toString() {
    return 'SensorFrame(yaw: $yaw, pitch: $pitch, roll: $roll, gyroMagnitude: $gyroMagnitude, accelMagnitude: $accelMagnitude, timestamp: $timestamp)';
  }

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        (other.runtimeType == runtimeType &&
            other is _$SensorFrameImpl &&
            (identical(other.yaw, yaw) || other.yaw == yaw) &&
            (identical(other.pitch, pitch) || other.pitch == pitch) &&
            (identical(other.roll, roll) || other.roll == roll) &&
            (identical(other.gyroMagnitude, gyroMagnitude) ||
                other.gyroMagnitude == gyroMagnitude) &&
            (identical(other.accelMagnitude, accelMagnitude) ||
                other.accelMagnitude == accelMagnitude) &&
            (identical(other.timestamp, timestamp) ||
                other.timestamp == timestamp));
  }

  @override
  int get hashCode => Object.hash(
      runtimeType, yaw, pitch, roll, gyroMagnitude, accelMagnitude, timestamp);

  /// Create a copy of SensorFrame
  /// with the given fields replaced by the non-null parameter values.
  @JsonKey(includeFromJson: false, includeToJson: false)
  @override
  @pragma('vm:prefer-inline')
  _$$SensorFrameImplCopyWith<_$SensorFrameImpl> get copyWith =>
      __$$SensorFrameImplCopyWithImpl<_$SensorFrameImpl>(this, _$identity);
}

abstract class _SensorFrame implements SensorFrame {
  const factory _SensorFrame(
      {required final double yaw,
      required final double pitch,
      required final double roll,
      required final double gyroMagnitude,
      required final double accelMagnitude,
      required final DateTime timestamp}) = _$SensorFrameImpl;

  /// Yaw angle in degrees.
  @override
  double get yaw;

  /// Camera elevation angle in degrees.
  /// 0° = horizontal, positive = downward, negative = upward.
  @override
  double get pitch;

  /// Roll angle in degrees. Roll constraint: ±15° (warn, don't block).
  @override
  double get roll;

  /// Gyroscope magnitude in rad/s.
  /// Stability gate: must be < 0.8 rad/s for 250ms before capture.
  @override
  double get gyroMagnitude;

  /// Linear acceleration magnitude in g.
  /// Stability gate: must be < 0.15g for 250ms before capture.
  @override
  double get accelMagnitude;

  /// Sensor reading timestamp, converted from native ms-since-epoch.
  @override
  DateTime get timestamp;

  /// Create a copy of SensorFrame
  /// with the given fields replaced by the non-null parameter values.
  @override
  @JsonKey(includeFromJson: false, includeToJson: false)
  _$$SensorFrameImplCopyWith<_$SensorFrameImpl> get copyWith =>
      throw _privateConstructorUsedError;
}
