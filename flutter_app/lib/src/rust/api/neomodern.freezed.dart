// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint, type=warning, deprecated_member_use, deprecated_member_use_from_same_package
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'neomodern.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$UiEvent {





@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent()';
}


}

/// @nodoc
class $UiEventCopyWith<$Res>  {
$UiEventCopyWith(UiEvent _, $Res Function(UiEvent) __);
}


/// Adds pattern-matching-related methods to [UiEvent].
extension UiEventPatterns on UiEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( UiEvent_State value)?  state,TResult Function( UiEvent_Position value)?  position,TResult Function( UiEvent_LibraryChanged value)?  libraryChanged,TResult Function( UiEvent_ScanProgress value)?  scanProgress,TResult Function( UiEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that);case UiEvent_Position() when position != null:
return position(_that);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that);case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that);case UiEvent_Error() when error != null:
return error(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( UiEvent_State value)  state,required TResult Function( UiEvent_Position value)  position,required TResult Function( UiEvent_LibraryChanged value)  libraryChanged,required TResult Function( UiEvent_ScanProgress value)  scanProgress,required TResult Function( UiEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case UiEvent_State():
return state(_that);case UiEvent_Position():
return position(_that);case UiEvent_LibraryChanged():
return libraryChanged(_that);case UiEvent_ScanProgress():
return scanProgress(_that);case UiEvent_Error():
return error(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( UiEvent_State value)?  state,TResult? Function( UiEvent_Position value)?  position,TResult? Function( UiEvent_LibraryChanged value)?  libraryChanged,TResult? Function( UiEvent_ScanProgress value)?  scanProgress,TResult? Function( UiEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that);case UiEvent_Position() when position != null:
return position(_that);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that);case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that);case UiEvent_Error() when error != null:
return error(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( UiPlayerSnapshot field0)?  state,TResult Function( double seconds,  double? duration)?  position,TResult Function()?  libraryChanged,TResult Function( BigInt scanned,  BigInt total,  bool done)?  scanProgress,TResult Function( String field0)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that.field0);case UiEvent_Position() when position != null:
return position(_that.seconds,_that.duration);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged();case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that.scanned,_that.total,_that.done);case UiEvent_Error() when error != null:
return error(_that.field0);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( UiPlayerSnapshot field0)  state,required TResult Function( double seconds,  double? duration)  position,required TResult Function()  libraryChanged,required TResult Function( BigInt scanned,  BigInt total,  bool done)  scanProgress,required TResult Function( String field0)  error,}) {final _that = this;
switch (_that) {
case UiEvent_State():
return state(_that.field0);case UiEvent_Position():
return position(_that.seconds,_that.duration);case UiEvent_LibraryChanged():
return libraryChanged();case UiEvent_ScanProgress():
return scanProgress(_that.scanned,_that.total,_that.done);case UiEvent_Error():
return error(_that.field0);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( UiPlayerSnapshot field0)?  state,TResult? Function( double seconds,  double? duration)?  position,TResult? Function()?  libraryChanged,TResult? Function( BigInt scanned,  BigInt total,  bool done)?  scanProgress,TResult? Function( String field0)?  error,}) {final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that.field0);case UiEvent_Position() when position != null:
return position(_that.seconds,_that.duration);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged();case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that.scanned,_that.total,_that.done);case UiEvent_Error() when error != null:
return error(_that.field0);case _:
  return null;

}
}

}

/// @nodoc


class UiEvent_State extends UiEvent {
  const UiEvent_State(this.field0): super._();
  

 final  UiPlayerSnapshot field0;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_StateCopyWith<UiEvent_State> get copyWith => _$UiEvent_StateCopyWithImpl<UiEvent_State>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_State&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'UiEvent.state(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $UiEvent_StateCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_StateCopyWith(UiEvent_State value, $Res Function(UiEvent_State) _then) = _$UiEvent_StateCopyWithImpl;
@useResult
$Res call({
 UiPlayerSnapshot field0
});




}
/// @nodoc
class _$UiEvent_StateCopyWithImpl<$Res>
    implements $UiEvent_StateCopyWith<$Res> {
  _$UiEvent_StateCopyWithImpl(this._self, this._then);

  final UiEvent_State _self;
  final $Res Function(UiEvent_State) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(UiEvent_State(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as UiPlayerSnapshot,
  ));
}


}

/// @nodoc


class UiEvent_Position extends UiEvent {
  const UiEvent_Position({required this.seconds, this.duration}): super._();
  

 final  double seconds;
 final  double? duration;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_PositionCopyWith<UiEvent_Position> get copyWith => _$UiEvent_PositionCopyWithImpl<UiEvent_Position>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Position&&(identical(other.seconds, seconds) || other.seconds == seconds)&&(identical(other.duration, duration) || other.duration == duration));
}


@override
int get hashCode {
    return Object.hash(runtimeType,seconds,duration);
}

@override
String toString() {
    return 'UiEvent.position(seconds: $seconds, duration: $duration)';
}


}

/// @nodoc
abstract mixin class $UiEvent_PositionCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_PositionCopyWith(UiEvent_Position value, $Res Function(UiEvent_Position) _then) = _$UiEvent_PositionCopyWithImpl;
@useResult
$Res call({
 double seconds, double? duration
});




}
/// @nodoc
class _$UiEvent_PositionCopyWithImpl<$Res>
    implements $UiEvent_PositionCopyWith<$Res> {
  _$UiEvent_PositionCopyWithImpl(this._self, this._then);

  final UiEvent_Position _self;
  final $Res Function(UiEvent_Position) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? seconds = null,Object? duration = freezed,}) {
  return _then(UiEvent_Position(
seconds: null == seconds ? _self.seconds : seconds // ignore: cast_nullable_to_non_nullable
as double,duration: freezed == duration ? _self.duration : duration // ignore: cast_nullable_to_non_nullable
as double?,
  ));
}


}

/// @nodoc


class UiEvent_LibraryChanged extends UiEvent {
  const UiEvent_LibraryChanged(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_LibraryChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent.libraryChanged()';
}


}




/// @nodoc


class UiEvent_ScanProgress extends UiEvent {
  const UiEvent_ScanProgress({required this.scanned, required this.total, required this.done}): super._();
  

 final  BigInt scanned;
 final  BigInt total;
 final  bool done;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ScanProgressCopyWith<UiEvent_ScanProgress> get copyWith => _$UiEvent_ScanProgressCopyWithImpl<UiEvent_ScanProgress>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_ScanProgress&&(identical(other.scanned, scanned) || other.scanned == scanned)&&(identical(other.total, total) || other.total == total)&&(identical(other.done, done) || other.done == done));
}


@override
int get hashCode {
    return Object.hash(runtimeType,scanned,total,done);
}

@override
String toString() {
    return 'UiEvent.scanProgress(scanned: $scanned, total: $total, done: $done)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ScanProgressCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ScanProgressCopyWith(UiEvent_ScanProgress value, $Res Function(UiEvent_ScanProgress) _then) = _$UiEvent_ScanProgressCopyWithImpl;
@useResult
$Res call({
 BigInt scanned, BigInt total, bool done
});




}
/// @nodoc
class _$UiEvent_ScanProgressCopyWithImpl<$Res>
    implements $UiEvent_ScanProgressCopyWith<$Res> {
  _$UiEvent_ScanProgressCopyWithImpl(this._self, this._then);

  final UiEvent_ScanProgress _self;
  final $Res Function(UiEvent_ScanProgress) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? scanned = null,Object? total = null,Object? done = null,}) {
  return _then(UiEvent_ScanProgress(
scanned: null == scanned ? _self.scanned : scanned // ignore: cast_nullable_to_non_nullable
as BigInt,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt,done: null == done ? _self.done : done // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

/// @nodoc


class UiEvent_Error extends UiEvent {
  const UiEvent_Error(this.field0): super._();
  

 final  String field0;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ErrorCopyWith<UiEvent_Error> get copyWith => _$UiEvent_ErrorCopyWithImpl<UiEvent_Error>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_Error&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode {
    return Object.hash(runtimeType,field0);
}

@override
String toString() {
    return 'UiEvent.error(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ErrorCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ErrorCopyWith(UiEvent_Error value, $Res Function(UiEvent_Error) _then) = _$UiEvent_ErrorCopyWithImpl;
@useResult
$Res call({
 String field0
});




}
/// @nodoc
class _$UiEvent_ErrorCopyWithImpl<$Res>
    implements $UiEvent_ErrorCopyWith<$Res> {
  _$UiEvent_ErrorCopyWithImpl(this._self, this._then);

  final UiEvent_Error _self;
  final $Res Function(UiEvent_Error) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(UiEvent_Error(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as String,
  ));
}


}

// dart format on
