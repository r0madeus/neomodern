import 'dart:io';

/// External command-line tools detected on the system `PATH`.
class DetectedSystemTools {
  const DetectedSystemTools({this.ytdlpPath, this.ffmpegPath});

  final String? ytdlpPath;
  final String? ffmpegPath;

  bool get hasAny => ytdlpPath != null || ffmpegPath != null;

  List<String> get names => [
        if (ytdlpPath != null) 'yt-dlp',
        if (ffmpegPath != null) 'ffmpeg',
      ];

  @override
  int get hashCode => Object.hash(ytdlpPath, ffmpegPath);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DetectedSystemTools &&
          runtimeType == other.runtimeType &&
          ytdlpPath == other.ytdlpPath &&
          ffmpegPath == other.ffmpegPath;
}

/// Scans `PATH` entries (read-only) for pre-installed `yt-dlp` and `ffmpeg`.
///
/// Never spawns subprocesses and never downloads binaries. Always returns an
/// empty result on Android.
DetectedSystemTools detectSystemToolsOnPath({
  String? pathEnv,
  bool? isWindows,
  bool? isAndroid,
}) {
  if (isAndroid ?? Platform.isAndroid) {
    return const DetectedSystemTools();
  }

  final windows = isWindows ?? Platform.isWindows;
  final rawPath =
      pathEnv ?? Platform.environment['PATH'] ?? Platform.environment['Path'] ?? '';
  if (rawPath.trim().isEmpty) {
    return const DetectedSystemTools();
  }

  final separator = windows ? ';' : ':';
  final pathSep = windows ? r'\' : '/';
  final ytdlpNames = windows ? const ['yt-dlp.exe'] : const ['yt-dlp'];
  final ffmpegNames = windows ? const ['ffmpeg.exe'] : const ['ffmpeg'];

  String? foundYtdlp;
  String? foundFfmpeg;

  for (final rawEntry in rawPath.split(separator)) {
    final dir = rawEntry.trim().replaceAll('"', '');
    if (dir.isEmpty) continue;

    foundYtdlp ??= _findExecutableInDir(dir, ytdlpNames, pathSep, windows);
    foundFfmpeg ??= _findExecutableInDir(dir, ffmpegNames, pathSep, windows);

    if (foundYtdlp != null && foundFfmpeg != null) {
      break;
    }
  }

  return DetectedSystemTools(
    ytdlpPath: foundYtdlp,
    ffmpegPath: foundFfmpeg,
  );
}

String? _findExecutableInDir(
  String dir,
  List<String> candidateNames,
  String pathSep,
  bool windows,
) {
  final normalizedDir = dir.endsWith(pathSep) || dir.endsWith('/')
      ? dir.substring(0, dir.length - 1)
      : dir;
  for (final name in candidateNames) {
    final candidate = '$normalizedDir$pathSep$name';
    if (!FileSystemEntity.isFileSync(candidate)) continue;
    if (!windows) {
      try {
        final mode = File(candidate).statSync().mode;
        if ((mode & 0x49) == 0) continue;
      } catch (_) {
        continue;
      }
    }
    return candidate;
  }
  return null;
}
