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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( UiEvent_State value)?  state,TResult Function( UiEvent_Position value)?  position,TResult Function( UiEvent_LibraryChanged value)?  libraryChanged,TResult Function( UiEvent_ScanProgress value)?  scanProgress,TResult Function( UiEvent_SyncChanged value)?  syncChanged,TResult Function( UiEvent_DownloadsChanged value)?  downloadsChanged,TResult Function( UiEvent_ArtistScanProgress value)?  artistScanProgress,TResult Function( UiEvent_ToolInstallProgress value)?  toolInstallProgress,TResult Function( UiEvent_Error value)?  error,required TResult orElse(),}){
final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that);case UiEvent_Position() when position != null:
return position(_that);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that);case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that);case UiEvent_SyncChanged() when syncChanged != null:
return syncChanged(_that);case UiEvent_DownloadsChanged() when downloadsChanged != null:
return downloadsChanged(_that);case UiEvent_ArtistScanProgress() when artistScanProgress != null:
return artistScanProgress(_that);case UiEvent_ToolInstallProgress() when toolInstallProgress != null:
return toolInstallProgress(_that);case UiEvent_Error() when error != null:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( UiEvent_State value)  state,required TResult Function( UiEvent_Position value)  position,required TResult Function( UiEvent_LibraryChanged value)  libraryChanged,required TResult Function( UiEvent_ScanProgress value)  scanProgress,required TResult Function( UiEvent_SyncChanged value)  syncChanged,required TResult Function( UiEvent_DownloadsChanged value)  downloadsChanged,required TResult Function( UiEvent_ArtistScanProgress value)  artistScanProgress,required TResult Function( UiEvent_ToolInstallProgress value)  toolInstallProgress,required TResult Function( UiEvent_Error value)  error,}){
final _that = this;
switch (_that) {
case UiEvent_State():
return state(_that);case UiEvent_Position():
return position(_that);case UiEvent_LibraryChanged():
return libraryChanged(_that);case UiEvent_ScanProgress():
return scanProgress(_that);case UiEvent_SyncChanged():
return syncChanged(_that);case UiEvent_DownloadsChanged():
return downloadsChanged(_that);case UiEvent_ArtistScanProgress():
return artistScanProgress(_that);case UiEvent_ToolInstallProgress():
return toolInstallProgress(_that);case UiEvent_Error():
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( UiEvent_State value)?  state,TResult? Function( UiEvent_Position value)?  position,TResult? Function( UiEvent_LibraryChanged value)?  libraryChanged,TResult? Function( UiEvent_ScanProgress value)?  scanProgress,TResult? Function( UiEvent_SyncChanged value)?  syncChanged,TResult? Function( UiEvent_DownloadsChanged value)?  downloadsChanged,TResult? Function( UiEvent_ArtistScanProgress value)?  artistScanProgress,TResult? Function( UiEvent_ToolInstallProgress value)?  toolInstallProgress,TResult? Function( UiEvent_Error value)?  error,}){
final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that);case UiEvent_Position() when position != null:
return position(_that);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged(_that);case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that);case UiEvent_SyncChanged() when syncChanged != null:
return syncChanged(_that);case UiEvent_DownloadsChanged() when downloadsChanged != null:
return downloadsChanged(_that);case UiEvent_ArtistScanProgress() when artistScanProgress != null:
return artistScanProgress(_that);case UiEvent_ToolInstallProgress() when toolInstallProgress != null:
return toolInstallProgress(_that);case UiEvent_Error() when error != null:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( UiPlayerSnapshot field0)?  state,TResult Function( double seconds,  double? duration)?  position,TResult Function()?  libraryChanged,TResult Function( BigInt scanned,  BigInt total,  bool done)?  scanProgress,TResult Function()?  syncChanged,TResult Function()?  downloadsChanged,TResult Function( bool running,  int total,  int done,  String? current,  String? error)?  artistScanProgress,TResult Function( String tool,  String stage,  BigInt received,  BigInt? total)?  toolInstallProgress,TResult Function( String field0)?  error,required TResult orElse(),}) {final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that.field0);case UiEvent_Position() when position != null:
return position(_that.seconds,_that.duration);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged();case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that.scanned,_that.total,_that.done);case UiEvent_SyncChanged() when syncChanged != null:
return syncChanged();case UiEvent_DownloadsChanged() when downloadsChanged != null:
return downloadsChanged();case UiEvent_ArtistScanProgress() when artistScanProgress != null:
return artistScanProgress(_that.running,_that.total,_that.done,_that.current,_that.error);case UiEvent_ToolInstallProgress() when toolInstallProgress != null:
return toolInstallProgress(_that.tool,_that.stage,_that.received,_that.total);case UiEvent_Error() when error != null:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( UiPlayerSnapshot field0)  state,required TResult Function( double seconds,  double? duration)  position,required TResult Function()  libraryChanged,required TResult Function( BigInt scanned,  BigInt total,  bool done)  scanProgress,required TResult Function()  syncChanged,required TResult Function()  downloadsChanged,required TResult Function( bool running,  int total,  int done,  String? current,  String? error)  artistScanProgress,required TResult Function( String tool,  String stage,  BigInt received,  BigInt? total)  toolInstallProgress,required TResult Function( String field0)  error,}) {final _that = this;
switch (_that) {
case UiEvent_State():
return state(_that.field0);case UiEvent_Position():
return position(_that.seconds,_that.duration);case UiEvent_LibraryChanged():
return libraryChanged();case UiEvent_ScanProgress():
return scanProgress(_that.scanned,_that.total,_that.done);case UiEvent_SyncChanged():
return syncChanged();case UiEvent_DownloadsChanged():
return downloadsChanged();case UiEvent_ArtistScanProgress():
return artistScanProgress(_that.running,_that.total,_that.done,_that.current,_that.error);case UiEvent_ToolInstallProgress():
return toolInstallProgress(_that.tool,_that.stage,_that.received,_that.total);case UiEvent_Error():
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( UiPlayerSnapshot field0)?  state,TResult? Function( double seconds,  double? duration)?  position,TResult? Function()?  libraryChanged,TResult? Function( BigInt scanned,  BigInt total,  bool done)?  scanProgress,TResult? Function()?  syncChanged,TResult? Function()?  downloadsChanged,TResult? Function( bool running,  int total,  int done,  String? current,  String? error)?  artistScanProgress,TResult? Function( String tool,  String stage,  BigInt received,  BigInt? total)?  toolInstallProgress,TResult? Function( String field0)?  error,}) {final _that = this;
switch (_that) {
case UiEvent_State() when state != null:
return state(_that.field0);case UiEvent_Position() when position != null:
return position(_that.seconds,_that.duration);case UiEvent_LibraryChanged() when libraryChanged != null:
return libraryChanged();case UiEvent_ScanProgress() when scanProgress != null:
return scanProgress(_that.scanned,_that.total,_that.done);case UiEvent_SyncChanged() when syncChanged != null:
return syncChanged();case UiEvent_DownloadsChanged() when downloadsChanged != null:
return downloadsChanged();case UiEvent_ArtistScanProgress() when artistScanProgress != null:
return artistScanProgress(_that.running,_that.total,_that.done,_that.current,_that.error);case UiEvent_ToolInstallProgress() when toolInstallProgress != null:
return toolInstallProgress(_that.tool,_that.stage,_that.received,_that.total);case UiEvent_Error() when error != null:
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


class UiEvent_SyncChanged extends UiEvent {
  const UiEvent_SyncChanged(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_SyncChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent.syncChanged()';
}


}




/// @nodoc


class UiEvent_DownloadsChanged extends UiEvent {
  const UiEvent_DownloadsChanged(): super._();
  






@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_DownloadsChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
    return 'UiEvent.downloadsChanged()';
}


}




/// @nodoc


class UiEvent_ArtistScanProgress extends UiEvent {
  const UiEvent_ArtistScanProgress({required this.running, required this.total, required this.done, this.current, this.error}): super._();
  

 final  bool running;
 final  int total;
 final  int done;
 final  String? current;
 final  String? error;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ArtistScanProgressCopyWith<UiEvent_ArtistScanProgress> get copyWith => _$UiEvent_ArtistScanProgressCopyWithImpl<UiEvent_ArtistScanProgress>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_ArtistScanProgress&&(identical(other.running, running) || other.running == running)&&(identical(other.total, total) || other.total == total)&&(identical(other.done, done) || other.done == done)&&(identical(other.current, current) || other.current == current)&&(identical(other.error, error) || other.error == error));
}


@override
int get hashCode {
    return Object.hash(runtimeType,running,total,done,current,error);
}

@override
String toString() {
    return 'UiEvent.artistScanProgress(running: $running, total: $total, done: $done, current: $current, error: $error)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ArtistScanProgressCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ArtistScanProgressCopyWith(UiEvent_ArtistScanProgress value, $Res Function(UiEvent_ArtistScanProgress) _then) = _$UiEvent_ArtistScanProgressCopyWithImpl;
@useResult
$Res call({
 bool running, int total, int done, String? current, String? error
});




}
/// @nodoc
class _$UiEvent_ArtistScanProgressCopyWithImpl<$Res>
    implements $UiEvent_ArtistScanProgressCopyWith<$Res> {
  _$UiEvent_ArtistScanProgressCopyWithImpl(this._self, this._then);

  final UiEvent_ArtistScanProgress _self;
  final $Res Function(UiEvent_ArtistScanProgress) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? running = null,Object? total = null,Object? done = null,Object? current = freezed,Object? error = freezed,}) {
  return _then(UiEvent_ArtistScanProgress(
running: null == running ? _self.running : running // ignore: cast_nullable_to_non_nullable
as bool,total: null == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as int,done: null == done ? _self.done : done // ignore: cast_nullable_to_non_nullable
as int,current: freezed == current ? _self.current : current // ignore: cast_nullable_to_non_nullable
as String?,error: freezed == error ? _self.error : error // ignore: cast_nullable_to_non_nullable
as String?,
  ));
}


}

/// @nodoc


class UiEvent_ToolInstallProgress extends UiEvent {
  const UiEvent_ToolInstallProgress({required this.tool, required this.stage, required this.received, this.total}): super._();
  

 final  String tool;
 final  String stage;
 final  BigInt received;
 final  BigInt? total;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$UiEvent_ToolInstallProgressCopyWith<UiEvent_ToolInstallProgress> get copyWith => _$UiEvent_ToolInstallProgressCopyWithImpl<UiEvent_ToolInstallProgress>(this, _$identity);



@override
bool operator ==(Object other) {
    return identical(this, other) || (other.runtimeType == runtimeType&&other is UiEvent_ToolInstallProgress&&(identical(other.tool, tool) || other.tool == tool)&&(identical(other.stage, stage) || other.stage == stage)&&(identical(other.received, received) || other.received == received)&&(identical(other.total, total) || other.total == total));
}


@override
int get hashCode {
    return Object.hash(runtimeType,tool,stage,received,total);
}

@override
String toString() {
    return 'UiEvent.toolInstallProgress(tool: $tool, stage: $stage, received: $received, total: $total)';
}


}

/// @nodoc
abstract mixin class $UiEvent_ToolInstallProgressCopyWith<$Res> implements $UiEventCopyWith<$Res> {
  factory $UiEvent_ToolInstallProgressCopyWith(UiEvent_ToolInstallProgress value, $Res Function(UiEvent_ToolInstallProgress) _then) = _$UiEvent_ToolInstallProgressCopyWithImpl;
@useResult
$Res call({
 String tool, String stage, BigInt received, BigInt? total
});




}
/// @nodoc
class _$UiEvent_ToolInstallProgressCopyWithImpl<$Res>
    implements $UiEvent_ToolInstallProgressCopyWith<$Res> {
  _$UiEvent_ToolInstallProgressCopyWithImpl(this._self, this._then);

  final UiEvent_ToolInstallProgress _self;
  final $Res Function(UiEvent_ToolInstallProgress) _then;

/// Create a copy of UiEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? tool = null,Object? stage = null,Object? received = null,Object? total = freezed,}) {
  return _then(UiEvent_ToolInstallProgress(
tool: null == tool ? _self.tool : tool // ignore: cast_nullable_to_non_nullable
as String,stage: null == stage ? _self.stage : stage // ignore: cast_nullable_to_non_nullable
as String,received: null == received ? _self.received : received // ignore: cast_nullable_to_non_nullable
as BigInt,total: freezed == total ? _self.total : total // ignore: cast_nullable_to_non_nullable
as BigInt?,
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
