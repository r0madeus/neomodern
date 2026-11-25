import 'dart:ui';

/// Supported UI language choices and Turkish/English translation lookup.
class AppStrings {
  AppStrings._();

  static const String system = 'system';
  static const String en = 'en';
  static const String tr = 'tr';

  static String _language = system;

  static String get currentLanguage => _language;

  static void setLanguage(String language) {
    final normalized = language.trim().toLowerCase();
    if (normalized == en || normalized == tr || normalized == system) {
      _language = normalized;
    } else {
      _language = system;
    }
  }

  static String resolveLanguage([Locale? locale]) {
    if (_language == en || _language == tr) {
      return _language;
    }
    final activeLocale = locale ?? PlatformDispatcher.instance.locale;
    return activeLocale.languageCode.toLowerCase() == tr ? tr : en;
  }

  static bool get isTurkish => resolveLanguage() == tr;

  static String translate(String key, [Map<String, Object?>? params]) {
    final text = isTurkish ? (_tr[key] ?? key) : key;
    if (params == null || params.isEmpty) return text;
    return text.replaceAllMapped(RegExp(r'\{(\w+)\}'), (match) {
      final name = match.group(1);
      if (name != null && params.containsKey(name)) {
        return '${params[name]}';
      }
      return match.group(0) ?? '';
    });
  }

  static const Map<String, String> _tr = {
    // App & initialization
    'Starting NeoModern...': 'NeoModern başlatılıyor...',
    'Failed to initialize NeoModern core': 'NeoModern çekirdeği başlatılamadı',

    // Navigation & sidebar
    'Home': 'Ana Menü',
    'Songs': 'Şarkılar',
    'Albums': 'Albümler',
    'Artists': 'Sanatçılar',
    'Sources': 'Kaynaklar',
    'Recap': 'Özet',
    'Settings': 'Ayarlar',
    'YOUR LIBRARY': 'KÜTÜPHANEN',
    'PINNED': 'SABİTLENENLER',
    'Favorites': 'Favoriler',
    'Create Playlist': 'Çalma Listesi Oluştur',
    'Import M3U Playlist': 'M3U Çalma Listesi İçe Aktar',
    'Scanning ({n})': 'Taranıyor ({n})',
    'Add folder in Settings': 'Ayarlar\'dan klasör ekle',
    '{songs} songs · {albums} albums': '{songs} şarkı · {albums} albüm',
    'Profile': 'Profil',
    'Resize sidebar': 'Kenar çubuğunu yeniden boyutlandır',
    'Resize right panel': 'Sağ paneli yeniden boyutlandır',

    // Common actions & labels
    'Play': 'Çal',
    'Play All': 'Tümünü Çal',
    'Shuffle': 'Karıştır',
    'Save': 'Kaydet',
    'Cancel': 'Vazgeç',
    'Close': 'Kapat',
    'Create': 'Oluştur',
    'Delete': 'Sil',
    'Rename': 'Yeniden Adlandır',
    'Edit': 'Düzenle',
    'Apply': 'Uygula',
    'Undo': 'Geri Al',
    'Retry': 'Tekrar Dene',
    'Refresh': 'Yenile',
    'Add': 'Ekle',
    'Remove': 'Kaldır',
    'Clear': 'Temizle',
    'Search': 'Ara',
    'Skip': 'Geç',
    'Reset': 'Sıfırla',
    'Unknown Artist': 'Bilinmeyen Sanatçı',
    'Unknown Album': 'Bilinmeyen Albüm',
    'Loading...': 'Yükleniyor...',
    'Title': 'Başlık',
    'Artist': 'Sanatçı',
    'Album': 'Albüm',
    'Time': 'Süre',
    'Off': 'Kapalı',
    'Active': 'Etkin',
    'Disabled': 'Devre dışı',

    // Player bar
    'Nothing playing': 'Çalan bir şey yok',
    'Pick a track to play': 'Çalmak için bir parça seç',
    'Shuffle on': 'Karıştırma açık',
    'Shuffle off': 'Karıştırma kapalı',
    'Previous': 'Önceki',
    'Next': 'Sonraki',
    'Repeat: off': 'Tekrar: Kapalı',
    'Repeat: all': 'Tekrar: Tümü',
    'Repeat: one': 'Tekrar: Tek parça',
    'Sleep Timer active': 'Uyku Zamanlayıcısı etkin',
    'Lyrics': 'Şarkı Sözleri',
    'Queue': 'Sıra',
    'Mute': 'Sesi kapat',
    'Unmute': 'Sesi aç',

    // Right panel (Lyrics & Queue)
    'Close panel': 'Paneli kapat',
    'Now Playing': 'Şimdi Çalıyor',
    'Recently played': 'Son çalınanlar',
    'Play a track to view lyrics.': 'Şarkı sözlerini görmek için bir parça çal.',
    'Reload lyrics': 'Sözleri yenile',
    'Save .lrc': '.lrc kaydet',
    'Saved .lrc to {path}': '.lrc kaydedildi: {path}',
    'No local lyrics found (Offline Mode is on).':
        'Yerel şarkı sözü bulunamadı (Çevrimdışı Mod açık).',
    'No lyrics found for this track.': 'Bu parça için şarkı sözü bulunamadı.',
    'Instrumental': 'Enstrümantal',
    'NOW PLAYING': 'ŞİMDİ ÇALIYOR',
    'Queue ({n})': 'Sıra ({n})',
    'Clear Added': 'Eklenenleri Temizle',
    'Queue is empty.': 'Sıra boş.',
    'Remove from queue': 'Sıradan kaldır',

    // Home view
    'Welcome to NeoModern': 'NeoModern\'e Hoş Geldin',
    'Add a music folder in Settings to scan your local collection.':
        'Yerel arşivini taramak için Ayarlar\'dan bir müzik klasörü ekle.',
    'Open Folder Settings': 'Klasör Ayarlarını Aç',
    'Refresh Home': 'Ana Menüyü Yenile',
    '{n} starred tracks': '{n} favori parça',
    'Dynamic Mixes': 'Dinamik Karışımlar',
    'Recently Added': 'Son Eklenenler',
    'Recently Played': 'Son Çalınanlar',
    'Save as Playlist': 'Çalma Listesi Olarak Kaydet',
    'Save Mix as Playlist': 'Karışımı Çalma Listesi Olarak Kaydet',
    'Saved "{name}"': '"{name}" kaydedildi',
    'Back to Home': 'Ana Menüye Dön',
    'Play Mix': 'Karışımı Çal',
    '{n} tracks': '{n} parça',
    '{n} track': '{n} parça',
    '{subtitle} · {n} tracks': '{subtitle} · {n} parça',
    '{n} tracks · {subtitle}': '{n} parça · {subtitle}',

    // Songs view
    'Search songs, artists, albums...': 'Şarkı, sanatçı, albüm ara...',
    'No matching songs found.': 'Eşleşen şarkı bulunamadı.',
    'No songs in library yet.': 'Kütüphanede henüz şarkı yok.',
    'Add Music Folder in Settings': 'Ayarlar\'dan Müzik Klasörü Ekle',

    // Albums view
    '{n} albums': '{n} albüm',
    'Search albums or artists...': 'Albüm veya sanatçı ara...',
    'No matching albums found.': 'Eşleşen albüm bulunamadı.',
    'No albums yet.': 'Henüz albüm yok.',
    'Back to Albums': 'Albümlere Dön',
    'Pin': 'Sabitle',
    'Unpin': 'Sabitlemeyi Kaldır',
    'Match Metadata': 'Meta Veri Eşleştir',

    // Artists view
    '{n} artists': '{n} sanatçı',
    'Search artists...': 'Sanatçı ara...',
    'No matching artists found.': 'Eşleşen sanatçı bulunamadı.',
    'No artists yet. Add a music folder in Settings.':
        'Henüz sanatçı yok. Ayarlar\'dan bir müzik klasörü ekle.',
    'Back to Artists': 'Sanatçılara Dön',
    '{albums} albums · {tracks} tracks': '{albums} albüm · {tracks} parça',
    '{n} plays': '{n} dinlenme',
    'Popular Tracks': 'Popüler Parçalar',
    'All Tracks': 'Tüm Parçalar',

    // Favorites view
    '{n} starred track': '{n} favori parça',
    'No favorite songs yet.': 'Henüz favori şarkı yok.',
    'Click the star icon on any track to add it here.':
        'Buraya eklemek için herhangi bir parçanın yıldız simgesine tıkla.',

    // Playlists view
    'PLAYLIST': 'ÇALMA LİSTESİ',
    'Playlist not found.': 'Çalma listesi bulunamadı.',
    'Rename Playlist': 'Çalma Listesini Yeniden Adlandır',
    'Playlist name': 'Çalma listesi adı',
    'Delete Playlist': 'Çalma Listesini Sil',
    'Delete "{name}"? Your audio files will not be touched.':
        '"{name}" silinsin mi? Ses dosyalarına dokunulmayacak.',
    'This playlist is empty. Right-click any song or use ... to add tracks.':
        'Bu çalma listesi boş. Parça eklemek için herhangi bir şarkıya sağ tıkla veya ... menüsünü kullan.',
    'Remove from Playlist': 'Çalma Listesinden Çıkar',
    'Change Cover': 'Kapağı Değiştir',
    'Export M3U': 'M3U Dışa Aktar',
    'Exported {n} tracks to M3U': '{n} parça M3U olarak dışa aktarıldı',
    'Import M3U': 'M3U İçe Aktar',
    'Imported playlist "{name}"': '"{name}" çalma listesi içe aktarıldı',

    // Track menu & multi-select
    'Play Next': 'Sıradaki Olarak Çal',
    'Add to Queue': 'Sıraya Ekle',
    'Add to Favorites': 'Favorilere Ekle',
    'Remove from Favorites': 'Favorilerden Kaldır',
    'Add to Playlist...': 'Çalma Listesine Ekle...',
    'Edit Tags...': 'Etiketleri Düzenle...',
    'Go to Artist': 'Sanatçıya Git',
    'Go to Album': 'Albüme Git',
    'More options': 'Diğer seçenekler',
    'Add to Playlist': 'Çalma Listesine Ekle',
    'New Playlist': 'Yeni Çalma Listesi',
    'Create New Playlist': 'Yeni Çalma Listesi Oluştur',
    'No playlists yet.': 'Henüz çalma listesi yok.',
    '{n} selected': '{n} seçili',
    'Star': 'Yıldızla',
    'Unstar': 'Yıldızı Kaldır',
    'Add to Playlist ': 'Listeye Ekle',

    // Settings view
    'Audio playback, watched folders, and offline privacy':
        'Ses çalma, izlenen klasörler, dil ve çevrimdışı gizlilik',
    'Language': 'Dil',
    'Choose the interface language': 'Arayüz dilini seç',
    'System': 'Sistem',
    'English': 'English',
    'Türkçe': 'Türkçe',
    'Library Folders': 'Kütüphane Klasörleri',
    '{n} watched folder': '{n} izlenen klasör',
    '{n} watched folders': '{n} izlenen klasör',
    'Rescan': 'Yeniden Tara',
    'Scanning...': 'Taranıyor...',
    'Add Folder': 'Klasör Ekle',
    'Scanning library... {n} files processed':
        'Kütüphane taranıyor... {n} dosya işlendi',
    'No music folders added yet. Click "Add Folder" to scan local audio files.':
        'Henüz müzik klasörü eklenmedi. Yerel ses dosyalarını taramak için "Klasör Ekle"ye tıkla.',
    'Remove folder': 'Klasörü kaldır',
    'Select music folder': 'Müzik klasörü seç',
    'Playlists & M3U': 'Çalma Listeleri ve M3U',
    'Import an .m3u or .m3u8 playlist file into your library':
        'Bir .m3u veya .m3u8 çalma listesi dosyasını kütüphanene aktar',
    'Playback': 'Çalma',
    'ReplayGain': 'ReplayGain',
    'Normalize loudness using embedded ReplayGain tags':
        'Gömülü ReplayGain etiketleriyle ses yüksekliğini dengele',
    'Track': 'Parça',
    'Gapless Playback': 'Kesintisiz Çalma',
    'Seamless transitions between consecutive tracks':
        'Ardışık parçalar arasında boşluksuz geçişler',
    'WASAPI Exclusive Mode': 'WASAPI Özel Modu',
    'Bypass Windows audio mixer for bit-perfect output (takes effect on next track)':
        'Bit-mükemmel çıkış için Windows ses karıştırıcısını atla (sonraki parçada geçerli olur)',
    'Crossfade': 'Geçiş (Crossfade)',
    'Smoothly blend into the next local track':
        'Sonraki yerel parçaya yumuşak geçiş yap',
    'Sleep Timer': 'Uyku Zamanlayıcısı',
    'Automatically fade out and pause playback':
        'Sesi yavaşça kısıp çalmayı otomatik duraklat',
    'Active: End of track': 'Etkin: Parça sonu',
    '{n} min': '{n} dk',
    'End of Track': 'Parça Sonu',
    '10-Band Equalizer': '10 Bantlı Ekolayzer',
    'Reset Flat': 'Düzleştir',
    'Preamp': 'Ön Kazanç',
    'Network': 'Ağ',
    'Offline Mode': 'Çevrimdışı Mod',
    'Block all network requests (online lyrics lookups remain disabled)':
        'Tüm ağ isteklerini engelle (çevrimiçi söz aramaları kapalı kalır)',

    // Recap view
    'Your Wrapped': 'Özetin',
    'Listening Stats': 'Dinleme İstatistikleri',
    'Recap of your local listening activity':
        'Yerel dinleme etkinliğinin özeti',
    '7 Days': '7 Gün',
    '30 Days': '30 Gün',
    'This Year': 'Bu Yıl',
    'All Time': 'Tüm Zamanlar',
    'Custom': 'Özel',
    'From': 'Başlangıç',
    'To': 'Bitiş',
    'Select start date': 'Başlangıç tarihi seç',
    'Select end date': 'Bitiş tarihi seç',
    'Refresh Stats': 'İstatistikleri Yenile',
    'No listening history for this period yet.':
        'Bu dönem için henüz dinleme geçmişi yok.',
    'Play tracks to build up your local listening recap.':
        'Yerel dinleme özetini oluşturmak için parça çal.',
    'Listening time': 'Dinleme süresi',
    'Listening Time': 'Dinleme Süresi',
    'Plays': 'Dinlenme',
    'Total Plays': 'Toplam Dinlenme',
    'Unique tracks': 'Farklı parça',
    'Unique Tracks': 'Farklı Parça',
    'Unique artists': 'Farklı sanatçı',
    'Unique Artists': 'Farklı Sanatçı',
    'Active Days': 'Etkin Gün',
    'Longest streak': 'En uzun seri',
    'Longest Streak': 'En Uzun Seri',
    'Completion rate': 'Tamamlama oranı',
    'Current streak': 'Güncel seri',
    '{n} day': '{n} gün',
    '{n} days': '{n} gün',
    '{n}d streak': '{n}g seri',
    'Peak hour': 'En yoğun saat',
    'Favorite day': 'Favori gün',
    'Completed / Skipped': 'Tamamlanan / Atlanan',
    '{done} finished · {skipped} skipped':
        '{done} tamamlandı · {skipped} atlandı',
    'Morning listener': 'Sabah dinleyicisi',
    'Afternoon listener': 'Öğleden sonra dinleyicisi',
    'Evening listener': 'Akşam dinleyicisi',
    'Night owl': 'Gece kuşu',
    'Monday': 'Pazartesi',
    'Tuesday': 'Salı',
    'Wednesday': 'Çarşamba',
    'Thursday': 'Perşembe',
    'Friday': 'Cuma',
    'Saturday': 'Cumartesi',
    'Sunday': 'Pazar',
    'Mon': 'Pzt',
    'Tue': 'Sal',
    'Wed': 'Çar',
    'Thu': 'Per',
    'Fri': 'Cum',
    'Sat': 'Cmt',
    'Sun': 'Paz',
    'By time': 'Süreye göre',
    'By plays': 'Dinlenmeye göre',
    'Save as playlist': 'Çalma listesi olarak kaydet',
    'Top tracks': 'En çok dinlenen parçalar',
    'Top Tracks': 'En Çok Dinlenen Parçalar',
    'No track plays recorded.': 'Kayıtlı parça dinlenmesi yok.',
    'Top artists': 'En çok dinlenen sanatçılar',
    'Top Artists': 'En Çok Dinlenen Sanatçılar',
    'No artist plays recorded.': 'Kayıtlı sanatçı dinlenmesi yok.',
    'Top albums': 'En çok dinlenen albümler',
    'Top Albums': 'En Çok Dinlenen Albümler',
    'No album plays recorded.': 'Kayıtlı albüm dinlenmesi yok.',
    'Top genres': 'En çok dinlenen türler',
    'No genres recorded.': 'Kayıtlı tür yok.',
    'Listening rhythm': 'Dinleme ritmi',
    'Hours of the day': 'Günün saatleri',
    'Weekdays': 'Haftanın günleri',
    'Monthly trend': 'Aylık eğilim',
    'Recent activity': 'Son etkinlikler',
    'Clear history': 'Geçmişi temizle',
    'Clear all listening history?': 'Tüm dinleme geçmişi temizlensin mi?',
    'Completed': 'Tamamlandı',
    'Skipped': 'Atlandı',
    'Partial': 'Kısmi',
    'Online': 'Çevrimiçi',

    // Search & Genre views
    'Browse all': 'Tümüne göz at',
    'In your library': 'Kütüphanende',
    'No matches in your library.': 'Kütüphanende eşleşme yok.',
    'External Sources': 'Harici Kaynaklar',
    'Search your library': 'Kütüphanende ara',
    'Type to search your local library.':
        'Yerel kütüphanende aramak için yaz.',
    'Clear search': 'Aramayı temizle',
    'No tracks found for this genre.': 'Bu tür için parça bulunamadı.',
    '< 1 min': '< 1 dk',
    '{m} min': '{m} dk',
    '{h} hr {m} min': '{h} sa {m} dk',
    '{n} album': '{n} albüm',
    'Load more': 'Daha fazla yükle',

    // External sources & Sync
    'External Sources (HTTP/JSON)': 'Harici Kaynaklar (HTTP/JSON)',
    'Optional external catalog and stream providers':
        'İsteğe bağlı harici katalog ve yayın sağlayıcıları',
    'Add Source': 'Kaynak Ekle',
    'Add External Source': 'Harici Kaynak Ekle',
    'No external sources configured. Add a neutral HTTP/JSON provider (e.g. self-hosted bridge) to search and stream external catalogs.':
        'Yapılandırılmış harici kaynak yok. Harici katalogları aramak ve dinlemek için tarafsız bir HTTP/JSON sağlayıcı (ör. kendi barındırdığın köprü) ekle.',
    'Search and stream from configured HTTP/JSON providers':
        'Yapılandırılmış HTTP/JSON sağlayıcılarından ara ve dinle',
    'Search external catalog...': 'Harici katalogda ara...',
    'Enable an external source in Settings to search and stream.':
        'Aramak ve dinlemek için Ayarlar\'dan bir harici kaynağı etkinleştir.',
    'Enter a query above to search this provider.':
        'Bu sağlayıcıda arama yapmak için yukarıya bir sorgu gir.',
    'No matching tracks found.': 'Eşleşen parça bulunamadı.',
    'Phone Sync & Remote Control': 'Telefon Eşitleme ve Uzaktan Kontrol',
    'Experimental — Party Queue': 'Deneysel — Parti Sırası',
    'Disabled by default. Turn on to host a local Party Queue session.':
        'Varsayılan olarak kapalıdır. Yerel bir Parti Sırası oturumu başlatmak için aç.',
    'Start Session': 'Oturumu Başlat',

    // Tag Editor Dialog
    'Edit Tags': 'Etiketleri Düzenle',
    'Track Title': 'Parça Başlığı',
    'Album Artist': 'Albüm Sanatçısı',
    'Track #': 'Parça No',
    'Disc #': 'Disk No',
    'Year': 'Yıl',
    'Genre': 'Tür',
    'Tags saved': 'Etiketler kaydedildi',
    'Track # must be a whole number': 'Parça No tam sayı olmalı',
    'Disc # must be a whole number': 'Disk No tam sayı olmalı',
    'Year must be a whole number': 'Yıl tam sayı olmalı',

    // MusicBrainz Metadata Match Dialog
    'Match Album Metadata': 'Albüm Meta Verilerini Eşleştir',
    'Searching MusicBrainz...': 'MusicBrainz aranıyor...',
    'No matching releases found on MusicBrainz.':
        'MusicBrainz\'te eşleşen sürüm bulunamadı.',
    'Release Candidates': 'Sürüm Adayları',
    'Score: {score}': 'Puan: {score}',
    'Album Field Changes': 'Albüm Alan Değişiklikleri',
    'Track Changes': 'Parça Değişiklikleri',
    'No field changes': 'Alan değişikliği yok',
    'Unmatched': 'Eşleşmedi',
    'Download cover art': 'Kapak görselini indir',
    'Undo Last Batch': 'Son Toplu İşlemi Geri Al',
    'Undid {n} tracks': '{n} parça geri alındı',
    'Applied metadata to {n} tracks': '{n} parçaya meta veri uygulandı',
    'Confirm & Apply': 'Onayla ve Uygula',

    // Playlist Cover Picker Dialog
    'Playlist Cover': 'Çalma Listesi Kapağı',
    'Auto 4-cover collage': 'Otomatik 4 kapak kolajı',
    'Gradient + Icon': 'Gradyan + Simge',
    'Custom Image': 'Özel Görsel',
    'Choose Image...': 'Görsel Seç...',
    'Select cover image': 'Kapak görseli seç',
    'Color Palette': 'Renk Paleti',
    'Music Icon': 'Müzik Simgesi',
    'Selected: {path}': 'Seçilen: {path}',
    'No image selected yet.': 'Henüz görsel seçilmedi.',

    // Welcome Dialog
    'Set up your music library': 'Müzik kütüphaneni kur',
    'Choose where NeoModern should scan your local music files. Your files stay in place.':
        'NeoModern\'in yerel müzik dosyalarını nereden tarayacağını seç. Dosyaların yerinde kalır.',
    'Detected Music Folder': 'Algılanan Müzik Klasörü',
    'Add & Scan': 'Ekle ve Tara',
    'Choose Folder': 'Klasör Seç',
    'No default Music folder was detected automatically.':
        'Varsayılan Müzik klasörü otomatik olarak algılanamadı.',

    // Online search, tools & downloads
    'Online Search': 'Çevrimiçi Ara',
    'Online Albums': 'Çevrimiçi Albümler',
    'Online Songs': 'Çevrimiçi Şarkılar',
    'Search online music...': 'Çevrimiçi müzik ara...',
    'Search online albums and songs...': 'Çevrimiçi albüm ve şarkı ara...',
    'Auto-install': 'Otomatik kur',
    'Installing...': 'Kuruluyor...',
    'Installing {tool}...': '{tool} kuruluyor...',
    'Downloads': 'İndirilenler',
    'Download': 'İndir',
    'Download Track': 'Parçayı İndir',
    'Download Album': 'Albümü İndir',
    'Download Folder': 'İndirme Klasörü',
    'Select download folder': 'İndirme klasörü seç',
    'No active downloads.': 'Etkin indirme yok.',
    'Clear Finished': 'Tamamlananları Temizle',
    'Queued': 'Sırada',
    'Downloading': 'İndiriliyor',
    'Failed': 'Başarısız',
    'Cancelled': 'İptal edildi',
    'yt-dlp path': 'yt-dlp yolu',
    'yt-dlp & FFmpeg': 'yt-dlp ve FFmpeg',
    'Available': 'Kullanılabilir',
    'Not installed': 'Kurulu değil',

    // Artist enrichment
    'Fetch artist info': 'Sanatçı bilgisini getir',
    'Fetch Artist Info': 'Sanatçı Bilgisini Getir',
    'Enrich all artists': 'Tüm sanatçıları zenginleştir',
    'Enrich All Artists': 'Tüm Sanatçıları Zenginleştir',
    'Enriching artists...': 'Sanatçılar zenginleştiriliyor...',
    'Enriching artists ({done}/{total})':
        'Sanatçılar zenginleştiriliyor ({done}/{total})',
    'Artist Enrichment': 'Sanatçı Zenginleştirme',
    'About Artist': 'Sanatçı Hakkında',
    'Biography': 'Biyografi',
    'Discography': 'Diskografi',

    // Network & Privacy
    'Network & Privacy': 'Ağ ve Gizlilik',
    'Offline mode': 'Çevrimdışı mod',
    'Online search & streaming': 'Çevrimiçi arama ve dinleme',
    'Lyrics lookup': 'Şarkı sözü arama',
    'Artist info & bio': 'Sanatçı bilgisi ve biyografi',
    'Metadata matching': 'Meta veri eşleştirme',
    'Update checks': 'Güncelleme denetimleri',
    'Save fetched lyrics': 'Bulunan sözleri kaydet',
    'Sidecar (.lrc)': 'Yan dosya (.lrc)',
    'Embed in audio file': 'Ses dosyasına göm',
    'Do not save': 'Kaydetme',
    'NetEase lyrics fallback': 'NetEase şarkı sözü yedeği',

    // Lyrics coverage & sharing
    'Lyrics Coverage': 'Şarkı Sözü Kapsamı',
    'With lyrics': 'Sözlü',
    'Without lyrics': 'Sözsüz',
    'Unchecked': 'Denetlenmemiş',
    'Save Cached Lyrics': 'Önbellekteki Sözleri Kaydet',
    'Saved {saved} · Skipped {skipped}': '{saved} kaydedildi · {skipped} atlandı',
    'Attach .lrc File...': '.lrc Dosyası Ekle...',
    'Select .lrc file': '.lrc dosyası seç',
    'Share lyrics to LRCLIB': 'Sözleri LRCLIB ile paylaş',
    'Share Lyrics to LRCLIB': 'Sözleri LRCLIB ile Paylaş',
    'Cancel Sharing': 'Paylaşımı İptal Et',
    'Published to LRCLIB': 'LRCLIB\'de yayınlandı',
    'Already on LRCLIB': 'Zaten LRCLIB\'de mevcut',

    // Single-track metadata match
    'Match track metadata': 'Parça meta verisini eşleştir',
    'Match Track Metadata': 'Parça Meta Verisini Eşleştir',
    'No matching tracks found on MusicBrainz.':
        'MusicBrainz\'te eşleşen parça bulunamadı.',
    'Track Candidates': 'Parça Adayları',

    // About & Updates
    'About': 'Hakkında',
    'Version': 'Sürüm',
    'Check for updates': 'Güncellemeleri denetle',
    'Check for Updates': 'Güncellemeleri Denetle',
    'Checking for updates...': 'Güncellemeler denetleniyor...',
    'You are up to date': 'Uygulama güncel',
    'Update available: {version}': 'Güncelleme mevcut: {version}',
    'View Release': 'Sürümü Görüntüle',
  };
}

/// Translates [key] into the currently selected language, substituting `{param}`.
String t(String key, [Map<String, Object?>? params]) =>
    AppStrings.translate(key, params);
