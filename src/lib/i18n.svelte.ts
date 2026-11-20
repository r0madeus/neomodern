// UI translations. The English text is the key; a missing translation
// falls back to English. Placeholders are written {name}.
//
// The language follows the system (Turkish if the system language is
// Turkish, English otherwise) unless chosen in Settings.

export type Lang = 'en' | 'tr'
export type LangChoice = 'system' | Lang
type Params = Record<string, string | number>

const KEY = 'neomodern.lang'

function loadChoice(): LangChoice {
  try {
    const v = localStorage.getItem(KEY)
    if (v === 'en' || v === 'tr' || v === 'system') return v
  } catch {
    // storage unavailable
  }
  return 'system'
}

function systemLang(): Lang {
  const langs = navigator.languages?.length ? navigator.languages : [navigator.language]
  return langs.some((l) => l?.toLowerCase().startsWith('tr')) ? 'tr' : 'en'
}

class I18n {
  choice = $state<LangChoice>(loadChoice())
  lang = $derived<Lang>(this.choice === 'system' ? systemLang() : this.choice)
  /** Locale for numbers and dates. */
  locale = $derived(this.lang === 'tr' ? 'tr-TR' : 'en-US')

  setChoice(next: LangChoice): void {
    this.choice = next
    try {
      localStorage.setItem(KEY, next)
    } catch {
      // ignore
    }
  }
}

export const i18n = new I18n()

/** Translates `en` into the current language and fills in {placeholders}. */
export function t(en: string, params?: Params): string {
  const text = i18n.lang === 'tr' ? (TR[en] ?? en) : en
  if (!params) return text
  return text.replace(/\{(\w+)\}/g, (m, k: string) => (k in params ? String(params[k]) : m))
}

/** `n` with the singular or plural key, e.g. count(3, '{n} song', '{n} songs'). */
export function count(n: number, one: string, many: string): string {
  return t(n === 1 ? one : many, { n: n.toLocaleString(i18n.locale) })
}

const TR: Record<string, string> = {
  // Navigation and views
  Songs: 'Şarkılar',
  Albums: 'Albümler',
  Queue: 'Sıra',
  Folders: 'Klasörler',
  Playlists: 'Çalma listeleri',
  Settings: 'Ayarlar',
  Library: 'Kütüphane',
  'Your Library': 'Kütüphanen',
  Search: 'Ara',
  Main: 'Ana menü',
  Lyrics: 'Şarkı sözleri',
  'Now playing': 'Şimdi çalıyor',
  '← Albums': '← Albümler',
  Back: 'Geri',

  // Player
  Play: 'Çal',
  Pause: 'Duraklat',
  Next: 'Sonraki',
  Previous: 'Önceki',
  Seek: 'Konum',
  Volume: 'Ses',
  Mute: 'Sesi kapat',
  Unmute: 'Sesi aç',
  Shuffle: 'Karıştır',
  'Shuffle play': 'Karışık çal',
  'Shuffle on': 'Karıştırma açık',
  'Shuffle off': 'Karıştırma kapalı',
  'Shuffle: On': 'Karıştır: Açık',
  'Shuffle: Off': 'Karıştır: Kapalı',
  'Repeat: One': 'Tekrarla: Tek şarkı',
  'Repeat: All': 'Tekrarla: Tümü',
  'Repeat: Off': 'Tekrarla: Kapalı',
  'Repeat one': 'Tek şarkıyı tekrarla',
  'Repeat all': 'Tümünü tekrarla',
  'Repeat off': 'Tekrar kapalı',
  'Nothing playing': 'Çalan bir şey yok',
  'Nothing playing.': 'Çalan bir şey yok.',
  Playing: 'Çalıyor',
  'Unknown artist': 'Bilinmeyen sanatçı',
  'Open now playing': '"Şimdi çalıyor" ekranını aç',
  'Close now playing': '"Şimdi çalıyor" ekranını kapat',
  'Close (Esc)': 'Kapat (Esc)',
  'Open player': 'Oynatıcıyı aç',
  'Close player': 'Oynatıcıyı kapat',
  '{i} of {n}': '{i} / {n}',

  // Lyrics
  'Full-screen lyrics': 'Tam ekran sözler',
  'Close lyrics': 'Sözleri kapat',
  'Refresh lyrics': 'Sözleri yenile',
  'Load .lrc file': '.lrc dosyası yükle',
  'Load .lrc': '.lrc yükle',
  'Local .lrc': 'Yerel .lrc',
  'Looking for lyrics…': 'Sözler aranıyor…',
  'No lyrics for this song.': 'Bu şarkının sözleri yok.',
  'No lyrics found.': 'Söz bulunamadı.',
  '♪ Instrumental': '♪ Enstrümantal',
  'Play a track to see lyrics.': 'Sözleri görmek için bir şarkı çal.',
  Sync: 'Senkronize et',
  Retry: 'Tekrar dene',
  'Embedded tag': 'Gömülü etiket',
  NetEase: 'NetEase',
  'Save lyrics': 'Sözleri kaydet',
  'Next to the song (.lrc file)': 'Şarkının yanına (.lrc dosyası)',
  'Inside the song file (tag)': 'Şarkı dosyasının içine (etiket)',
  'Only in the app': 'Yalnız uygulamada',
  "Lyrics found online are also saved permanently, so they work offline and in other players. An existing .lrc file or lyrics tag is never replaced. Lyrics in a song's tag are written once the song is no longer the one playing.":
    'Çevrimiçi bulunan sözler kalıcı olarak da kaydedilir; böylece çevrimdışı ve başka oynatıcılarda da çalışır. Var olan bir .lrc dosyası ya da söz etiketi asla değiştirilmez. Etikete yazma, şarkı çalan şarkı olmaktan çıkınca yapılır.',
  'NetEase Cloud Music': 'NetEase Cloud Music',
  'Also search NetEase Cloud Music (unofficial; used when LRCLIB has nothing)':
    'NetEase Cloud Music’te de ara (resmî olmayan; LRCLIB’de bir şey yoksa kullanılır)',
  'Save cached lyrics to songs': 'Önbellekteki sözleri şarkılara kaydet',
  'Writes the lyrics already found for your library with the setting above. Songs that already have lyrics are skipped.':
    'Kütüphanen için daha önce bulunan sözleri yukarıdaki ayara göre yazar. Sözü olan şarkılar atlanır.',
  '{saved} saved, {skipped} skipped': '{saved} kaydedildi, {skipped} atlandı',
  'Lyrics coverage': 'Söz kapsamı',
  'How many songs of your library have lyrics.': 'Kütüphanendeki kaç şarkının sözü var.',
  '{with} with lyrics · {without} checked, none found · {unchecked} not looked up yet':
    '{with} şarkının sözü var · {without} arandı, bulunamadı · {unchecked} henüz aranmadı',
  'Counting…': 'Sayılıyor…',
  Count: 'Say',
  'Share on LRCLIB': 'LRCLIB’de paylaş',
  'Your lyrics will be published publicly on lrclib.net. Sending takes a few minutes of processor work (LRCLIB requires it against spam).':
    'Sözlerin lrclib.net’te herkese açık olarak yayınlanacak. Gönderim birkaç dakika işlemci kullanır (LRCLIB istenmeyen gönderilere karşı bunu şart koşuyor).',
  Publish: 'Yayınla',
  'Sharing… (this can take a few minutes)': 'Paylaşılıyor… (birkaç dakika sürebilir)',
  'Shared on LRCLIB. Thank you!': 'LRCLIB’de paylaşıldı. Teşekkürler!',
  'Sharing cancelled.': 'Paylaşım iptal edildi.',
  'Could not share: {error}': 'Paylaşılamadı: {error}',
  'No lyrics of your own to share.': 'Paylaşılacak kendi sözün yok.',
  'Needs title, artist, album and duration in the tags.': 'Etiketlerde başlık, sanatçı, albüm ve süre gerekir.',
  'LRCLIB already has these lyrics.': 'LRCLIB’de bu sözler zaten var.',
  'These lyrics came from another service.': 'Bu sözler başka bir servisten geldi.',
  'Could not reach LRCLIB.': 'LRCLIB’ye ulaşılamadı.',
  'Another share is running.': 'Başka bir paylaşım sürüyor.',

  // Lists and sorting
  'Sort by': 'Sırala',
  Artist: 'Sanatçı',
  Title: 'Başlık',
  Album: 'Albüm',
  Time: 'Süre',
  'Recently added': 'Son eklenenler',
  Recent: 'Yeni',
  '{n} matching': '{n} sonuç',
  'No songs match “{q}”.': '“{q}” ile eşleşen şarkı yok.',
  'No albums match “{q}”.': '“{q}” ile eşleşen albüm yok.',
  'Clear search': 'Aramayı temizle',
  Clear: 'Temizle',
  'Search…': 'Ara…',
  'Search library': 'Kütüphanede ara',
  'Search songs, artists, albums…': 'Şarkı, sanatçı, albüm ara…',
  'Search albums, artists, songs…': 'Albüm, sanatçı, şarkı ara…',
  'Songs, artists or albums': 'Şarkı, sanatçı veya albüm',
  'Search your library': 'Kütüphanende ara',
  'Filter your library…': 'Kütüphanende ara…',
  'Clear filter': 'Filtreyi temizle',
  Mixes: 'Karışımlar',
  Recents: 'Son eklenenler',
  Alphabetical: 'Alfabetik',
  'Grid view': 'Izgara görünümü',
  'List view': 'Liste görünümü',
  'Toggle sort': 'Sıralamayı değiştir',
  'Find songs, artists and albums by name.': 'Şarkıları, sanatçıları ve albümleri adıyla bul.',
  'No results for “{q}”': '“{q}” için sonuç yok',
  'Check the spelling or try fewer words.': 'Yazımı kontrol et ya da daha az kelime dene.',
  '{n} song': '{n} şarkı',
  '{n} songs': '{n} şarkı',
  '{n} track': '{n} parça',
  '{n} tracks': '{n} parça',
  '{n} album': '{n} albüm',
  '{n} albums': '{n} albüm',
  'Album · {details}': 'Albüm · {details}',
  'Playlist · {count}': 'Çalma listesi · {count}',
  Loading: 'Yükleniyor',
  'Loading…': 'Yükleniyor…',

  // Library and folders
  'Your library is empty.': 'Kütüphanen boş.',
  'Add a music folder': 'Müzik klasörü ekle',
  'Add folder': 'Klasör ekle',
  'Music folders': 'Müzik klasörleri',
  'No folders yet. Add a folder to build your library.': 'Henüz klasör yok. Kütüphaneni oluşturmak için bir klasör ekle.',
  Rescan: 'Yeniden tara',
  Remove: 'Kaldır',
  'Scanning your music folders…': 'Müzik klasörlerin taranıyor…',
  'Scanning…': 'Taranıyor…',
  'Scanning · {n}': 'Taranıyor · {n}',
  'Scanning · {n} files': 'Taranıyor · {n} dosya',
  'Reading tags…': 'Etiketler okunuyor…',

  // Queue
  'The queue is empty.': 'Sıra boş.',
  'Open files': 'Dosya aç',
  'Add to queue': 'Sıraya ekle',
  'Save as playlist': 'Çalma listesi olarak kaydet',
  'Remove from queue': 'Sıradan kaldır',
  'Remove “{title}” from queue': '“{title}” sıradan kaldırılsın',
  'Close queue': 'Sırayı kapat',
  'Next up': 'Sıradaki',
  'Nothing after this song.': 'Bu şarkıdan sonra bir şey yok.',
  Audio: 'Ses',

  // Playlists
  Playlist: 'Çalma listesi',
  'New playlist': 'Yeni çalma listesi',
  'See more': 'Daha fazla göster',
  Autoplay: 'Otomatik çalma',
  'When your music ends, similar songs from your library keep playing. Songs already played this session are not repeated. Not with repeat on.':
    'Müziğin bitince kütüphanenden benzer şarkılar çalmaya devam eder. Bu dinlemede çalınan şarkılar tekrar çalınmaz. Tekrarlama açıkken çalışmaz.',
  'Delete playlist': 'Çalma listesini sil',
  'Delete “{name}”?': '“{name}” silinsin mi?',
  'The songs stay in your library.': 'Şarkılar kütüphanende kalır.',
  'Timer': 'Zamanlayıcı',
  'Edit': 'Düzenle',
  'Repeat': 'Tekrarla',
  'More actions': 'Diğer işlemler',
  'Add files to the queue': 'Sıraya dosya ekle',
  'Drag to reorder': 'Sürükleyip sırala',
  'Date added': 'Eklenme tarihi',
  'Remove from this playlist': 'Bu çalma listesinden çıkar',
  'Go to queue': 'Sıraya git',
  'Next in queue': 'Sıradaki',
  'Open queue': 'Kuyruğu aç',
  'Build a playlist with songs': 'Şarkılarla bir çalma listesi oluştur',
  'New playlist…': 'Yeni çalma listesi…',
  'New playlist name': 'Yeni çalma listesinin adı',
  'Playlist name': 'Çalma listesi adı',
  'No playlists yet.': 'Henüz çalma listesi yok.',
  'Create a playlist': 'Çalma listesi oluştur',
  Create: 'Oluştur',
  'Add to playlist': 'Çalma listesine ekle',
  'Add album to playlist': 'Albümü çalma listesine ekle',
  Rename: 'Yeniden adlandır',
  Delete: 'Sil',
  'Delete this playlist?': 'Bu çalma listesi silinsin mi?',
  Cancel: 'Vazgeç',
  Save: 'Kaydet',
  'Saving…': 'Kaydediliyor…',
  Close: 'Kapat',
  Export: 'Dışa aktar',
  'Export…': 'Dışa aktar…',
  'Save as an M3U file, e.g. to open on another device': 'M3U dosyası olarak kaydet (örneğin başka bir cihazda açmak için)',
  'Import playlist': 'Çalma listesi içe aktar',
  'Import playlist (M3U)': 'Çalma listesi içe aktar (M3U)',
  'An M3U file exported from NeoModern on another device': 'Başka bir cihazdaki NeoModern’den dışa aktarılmış M3U dosyası',
  'Playlist not found.': 'Çalma listesi bulunamadı.',
  'This playlist is empty. Use the “…” button on a song or album to add tracks.':
    'Bu çalma listesi boş. Şarkı eklemek için bir şarkının ya da albümün “…” düğmesini kullan.',
  'This playlist is empty. Use the ⋯ menu on a song or album to add tracks.':
    'Bu çalma listesi boş. Şarkı eklemek için bir şarkının ya da albümün ⋯ menüsünü kullan.',
  'More actions for “{title}”': '“{title}” için diğer işlemler',
  'Remove “{title}” from playlist': '“{title}” çalma listesinden kaldırılsın',
  '{n} selected': '{n} seçili',
  'Select all': 'Tümünü seç',
  'Clear selection': 'Seçimi temizle',
  'Select “{title}”': '“{title}” parçasını seç',
  'Move “{title}” up': '“{title}” yukarı taşınsın',
  'Move “{title}” down': '“{title}” aşağı taşınsın',
  '{path}\nDouble-click or Enter to play. Alt+Up/Down moves, Delete removes.':
    '{path}\nÇalmak için çift tıkla ya da Enter. Alt+Yukarı/Aşağı taşır, Delete kaldırır.',
  'Added {count} to “{name}”': '“{name}” listesine {count} eklendi',
  'Added album to “{name}”': 'Albüm “{name}” listesine eklendi',
  'Added {count} to new playlist “{name}”': 'Yeni “{name}” listesine {count} eklendi',
  'Saved “{name}” with {count}': '“{name}” {count} ile kaydedildi',
  ' ({n} not in the library, skipped)': ' ({n} tanesi kütüphanede yok, atlandı)',
  'Exported “{name}”': '“{name}” dışa aktarıldı',
  'Imported “{name}” with {count}': '“{name}” {count} ile içe aktarıldı',
  ' ({n} not found in this library)': ' ({n} tanesi bu kütüphanede bulunamadı)',
  Imported: 'İçe aktarılan',

  // Find info (MusicBrainz)
  'Find info': 'Bilgileri bul',
  'Find info for this track': 'Bu parça için bilgileri bul',
  Recommended: 'Önerilen',
  Check: 'Kontrol et',
  Apply: 'Uygula',
  'Applying…': 'Uygulanıyor…',
  Undo: 'Geri al',
  'Undoing…': 'Geri alınıyor…',
  'Searching MusicBrainz…': 'MusicBrainz aranıyor…',
  'MusicBrainz could not be reached': 'MusicBrainz\'e ulaşılamadı',
  'No matching release was found on MusicBrainz.': 'MusicBrainz\'te eşleşen bir sürüm bulunamadı.',
  'Matches from MusicBrainz. Nothing is written until you apply.':
    'MusicBrainz eşleşmeleri. Sen uygulamadan hiçbir şey yazılmaz.',
  Matches: 'Eşleşmeler',
  Changes: 'Değişiklikler',
  'Match score {score}': 'Eşleşme puanı {score}',
  'No matching track on this release; left unchanged.': 'Bu sürümde eşleşen parça yok; değiştirilmedi.',
  'No visible changes': 'Görünür değişiklik yok',
  'MusicBrainz ids are saved in the tags too, and a cover is added if the album has none.':
    'MusicBrainz kimlikleri de etiketlere yazılır; albümün kapağı yoksa kapak eklenir.',
  'The changes were undone.': 'Değişiklikler geri alındı.',
  'Cover added': 'Kapak eklendi',
  'Save or discard your edits first.': 'Önce düzenlemelerini kaydet ya da vazgeç.',

  // Tags
  'Edit tags': 'Etiketleri düzenle',
  'Edit tags…': 'Etiketleri düzenle…',
  'Edit album tags': 'Albüm etiketlerini düzenle',
  'Edit tags of {n} tracks': '{n} parçanın etiketlerini düzenle',
  'Album artist': 'Albüm sanatçısı',
  'Track number': 'Parça no',
  'Disc number': 'Disk no',
  Year: 'Yıl',
  Genre: 'Tür',
  'Browse all': 'Tümüne göz at',
  'No tracks found for this genre.': 'Bu türde şarkı bulunamadı.',
  '(multiple values)': '(farklı değerler)',
  'These tracks are no longer in the library.': 'Bu parçalar artık kütüphanede değil.',
  'Year must be between 1 and 9999.': 'Yıl 1 ile 9999 arasında olmalı.',
  'Updated tags of {count}': '{count} parçanın etiketleri güncellendi',
  '{n} file': '{n} dosya',
  '{n} files': '{n} dosya',
  'Only the fields you change are written.': 'Yalnızca değiştirdiğin alanlar yazılır.',
  '(will be cleared)': '(silinecek)',
  '{label} must be a whole number.': '{label} tam sayı olmalı.',
  'Clear {label} on all files': 'Tüm dosyalarda {label} alanını temizle',
  '{n} updated, ': '{n} güncellendi, ',
  '{count} could not be edited:': '{count} düzenlenemedi:',

  // Settings
  Playback: 'Çalma',
  ReplayGain: 'ReplayGain',
  'Evens out loudness using ReplayGain tags. Track levels every song; Album keeps the loudness differences inside an album.':
    'ReplayGain etiketleriyle ses yüksekliğini dengeler. "Parça" her şarkıyı eşitler; "Albüm" albüm içindeki ses farklarını korur.',
  Off: 'Kapalı',
  Track: 'Parça',
  'Show file extensions': 'Dosya uzantılarını göster',
  'Adds a small format badge (FLAC, MP3…) to song rows and album track lists.':
    'Şarkı satırlarına ve albüm parça listelerine küçük bir biçim rozeti (FLAC, MP3…) ekler.',
  Window: 'Pencere',
  'Keep playing in the tray when the window is closed': 'Pencere kapatılınca sistem tepsisinde çalmaya devam et',
  'Closing the window hides NeoModern to the system tray and playback continues. Use the tray menu to show the window again or to quit.':
    'Pencereyi kapatmak NeoModern’i sistem tepsisine gizler ve çalma sürer. Pencereyi geri getirmek ya da çıkmak için tepsi menüsünü kullan.',
  'No system tray is available here, so closing the window always quits.':
    'Burada sistem tepsisi yok, bu yüzden pencereyi kapatmak her zaman uygulamadan çıkar.',
  Storage: 'Depolama',
  'Access to all files': 'Tüm dosyalara erişim',
  'Needed to edit tags and to attach .lrc lyrics next to your songs. Playing music works without it.':
    'Etiket düzenlemek ve şarkıların yanına .lrc sözleri eklemek için gerekir. Müzik çalmak için gerekmez.',
  Allow: 'İzin ver',
  Allowed: 'İzin verildi',
  Language: 'Dil',
  'Language of the app. "System default" follows the device language.': 'Uygulamanın dili. "Sistem dili" cihazın dilini izler.',
  'System default': 'Sistem dili',
  About: 'Hakkında',
  ' · version {v}': ' · sürüm {v}',
  'Check for updates': 'Güncellemeleri denetle',
  'Checking…': 'Denetleniyor…',
  'You have the latest version.': 'En son sürümü kullanıyorsun.',
  'Could not reach GitHub.': 'GitHub’a ulaşılamadı.',
  'Version {v} is available.': '{v} sürümü çıktı.',
  Copy: 'Kopyala',
  Copied: 'Kopyalandı',

  // Updates
  'NeoModern {v} is available.': 'NeoModern {v} çıktı.',
  Download: 'İndir',
  Dismiss: 'Kapat',

  // Online search & downloads
  '← Search': '← Ara',
  'Download album': 'Albümü indir',
  'Download track': 'Parçayı indir',
  'Download “{title}”': '“{title}” parçasını indir',
  Downloaded: 'İndirildi',
  'Downloading…': 'İndiriliyor…',
  'Downloading {done}/{total}': 'İndiriliyor {done}/{total}',
  Queued: 'Sırada',
  Done: 'Bitti',
  Failed: 'Başarısız',
  Cancelled: 'İptal edildi',
  'Cancel download': 'İndirmeyi iptal et',
  'No tracks found for this album.': 'Bu albüm için parça bulunamadı.',
  'Search songs, albums, or paste a link…': 'Şarkı, albüm ara veya bağlantı yapıştır…',
  'Search music online': 'Çevrimiçi müzik ara',
  'Searching…': 'Aranıyor…',
  Refresh: 'Yenile',
  'yt-dlp was not found. You can still browse albums; install yt-dlp or set its path in Settings to stream and download.':
    'yt-dlp bulunamadı. Albümlere göz atmaya devam edebilirsin; dinlemek ve indirmek için yt-dlp kur veya Ayarlar’dan yolunu seç.',
  'Find albums and tracks, stream them right away, or download them straight into your library.':
    'Albüm ve şarkıları ara, hemen dinle ya da doğrudan kütüphanene indir.',
  Downloads: 'İndirilenler',
  '{n} active': '{n} etkin',
  'Clear finished': 'Bitenleri temizle',
  'Search & Downloads': 'Ara ve İndir',
  // Offline mode and internet switches
  Internet: 'İnternet',
  'Offline mode': 'Çevrimdışı mod',
  'Nothing connects to the internet': 'Hiçbir şey internete bağlanmaz',
  'Offline mode is on, so the switches above are off.':
    'Çevrimdışı mod açık, bu yüzden yukarıdaki anahtarlar kapalı.',
  'Turned off in Settings': 'Ayarlar’dan kapalı',
  'Not checked': 'Denetlenmedi',
  'Lyrics (LRCLIB, NetEase)': 'Şarkı sözleri (LRCLIB, NetEase)',
  'Looks up lyrics online and lets you share your own on LRCLIB. Lyrics next to your songs and in their tags keep working.':
    'Sözleri internetten arar ve kendi sözlerini LRCLIB’de paylaşmanı sağlar. Şarkıların yanındaki ve etiketlerindeki sözler çalışmaya devam eder.',
  'Online search and downloads (YouTube, iTunes)': 'Çevrimiçi arama ve indirme (YouTube, iTunes)',
  'Online search, streaming and downloads, including album search and covers through iTunes.':
    'Çevrimiçi arama, dinleme ve indirme; iTunes üzerinden albüm arama ve kapaklar dahil.',
  'Artist info (Deezer, Wikipedia, iTunes)': 'Sanatçı bilgisi (Deezer, Wikipedia, iTunes)',
  'Artist portraits, biographies and missing albums. Anything already saved is still shown.':
    'Sanatçı fotoğrafları, biyografiler ve eksik albümler. Daha önce kaydedilenler yine gösterilir.',
  'Find info (MusicBrainz, Cover Art Archive)': 'Bilgi bul (MusicBrainz, Cover Art Archive)',
  'Finds album and track tags and covers on MusicBrainz.':
    'Albüm ve şarkı etiketlerini ve kapaklarını MusicBrainz’de bulur.',
  'Update check (GitHub)': 'Güncelleme denetimi (GitHub)',
  'Checks once a day whether a new version of NeoModern is available.':
    'NeoModern’in yeni bir sürümü olup olmadığını günde bir kez denetler.',
  'Search your library…': 'Kütüphanende ara…',
  'Online search is turned off in Settings.': 'Çevrimiçi arama Ayarlar’dan kapalı.',
  'Type to search your local library.': 'Yerel kütüphanende aramak için yaz.',
  'Download folder': 'İndirme klasörü',
  'Choose download folder': 'İndirme klasörünü seç',
  'Locate yt-dlp executable': 'yt-dlp dosyasını seç',
  'Choose…': 'Seç…',
  Reset: 'Sıfırla',
  Ready: 'Hazır',
  'Not found': 'Bulunamadı',
  'ffmpeg available': 'ffmpeg hazır',
  'ffmpeg missing': 'ffmpeg yok',

  // Pinned sidebar items
  Pin: 'Sabitle',
  Pinned: 'Sabitlendi',
  'Pinned items': 'Sabitlenenler',
  Unpin: 'Sabitlemeyi kaldır',
  'Pin “{title}”': '“{title}” öğesini sabitle',
  'Unpin “{title}”': '“{title}” sabitlemesini kaldır',
  'Your library': 'Kitaplığın',
  'Pin album': 'Albümü sabitle',
  'Unpin album': 'Albüm sabitlemesini kaldır',
  'Create a playlist with +, or pin an album from its page or a song’s menu.':
    '+ ile çalma listesi oluştur ya da bir albümü sayfasından veya şarkı menüsünden sabitle.',

  // Unified search & filters
  'Filter…': 'Filtrele…',
  'Filter library': 'Kütüphaneyi filtrele',
  'Filter songs, artists, albums…': 'Şarkı, sanatçı, albüm filtrele…',
  'Filter albums, artists, songs…': 'Albüm, sanatçı, şarkı filtrele…',
  'Search your library & online (Enter for online)…':
    'Kütüphanede ve internette ara (çevrimiçi için Enter)…',
  'Search library and online': 'Kütüphanede ve internette ara',
  'Online search': 'İnternette ara',
  'Type to search your local library immediately, or press Enter to search, stream, and download online.':
    'Kütüphanende anında aramak için yaz; internette arama, dinleme ve indirme için Enter’a bas.',
  'In your library': 'Kütüphanende',
  'No matches in your library.': 'Kütüphanende eşleşme yok.',
  Online: 'Çevrimiçi',
  'Searching online…': 'İnternette aranıyor…',
  'No online results for “{q}”.': '“{q}” için çevrimiçi sonuç yok.',
  'In library': 'Kütüphanede',
  'Press Enter to search online for “{q}”.': '“{q}” için internette aramak üzere Enter’a bas.',

  // Favorites
  Favorites: 'Favoriler',
  'Add “{title}” to favorites': '“{title}” parçasını favorilere ekle',
  'Remove “{title}” from favorites': '“{title}” parçasını favorilerden kaldır',
  'No favorite tracks yet. Click the star on any song to save it here.':
    'Henüz favori şarkı yok. Buraya eklemek için herhangi bir şarkının yıldızına tıkla.',

  // Playlist & album covers
  'Change cover': 'Kapağı değiştir',
  Cover: 'Kapak',
  'Playlist cover': 'Çalma listesi kapağı',
  'Choose photo…': 'Fotoğraf seç…',
  'Choose playlist cover': 'Çalma listesi kapağını seç',
  'Choose album cover': 'Albüm kapağı seç',
  'Choose cover…': 'Kapak seç…',
  'Reset cover': 'Varsayılan kapağa dön',
  Images: 'Görseller',
  'Use automatic cover': 'Otomatik kapak kullan',
  Gradient: 'Gradyan',
  Icon: 'İkon',
  'Apply gradient & icon': 'Gradyan ve ikonu uygula',

  // Listening history & stats
  'Listening stats': 'Dinleme istatistikleri',
  'Your Wrapped': 'Dinleme Özeti',
  'Last 7 days': 'Son 7 gün',
  'Last 30 days': 'Son 30 gün',
  'All time': 'Tüm zamanlar',
  Custom: 'Özel aralık',
  From: 'Başlangıç',
  To: 'Bitiş',
  'Listening time': 'Dinleme süresi',
  Plays: 'Dinlenme',
  'Unique tracks': 'Farklı şarkı',
  'Unique artists': 'Farklı sanatçı',
  'Longest streak': 'En uzun seri',
  'Current streak': 'Aktif seri',
  '{n} day': '{n} gün',
  '{n} days': '{n} gün',
  'Completion rate': 'Tamamlama oranı',
  'Peak hour': 'En aktif saat',
  'Favorite day': 'Favori gün',
  'Morning listener': 'Sabah dinleyicisi',
  'Afternoon listener': 'Öğlen dinleyicisi',
  'Evening listener': 'Akşam dinleyicisi',
  'Night owl': 'Gece kuşu',
  '{done} finished · {skipped} skipped': '{done} tamamlandı · {skipped} atlandı',
  'Top tracks': 'En çok dinlenen şarkılar',
  'By time': 'Süreye göre',
  'By plays': 'Sayıya göre',
  'Top tracks · {period}': 'En çok dinlenenler · {period}',
  'Playlist “{name}” created': '“{name}” çalma listesi oluşturuldu',
  'Top artists': 'En çok dinlenen sanatçılar',
  'Top albums': 'En çok dinlenen albümler',
  'Top genres': 'En çok dinlenen türler',
  'Listening rhythm': 'Dinleme ritmin',
  'Hours of the day': 'Günün saatleri',
  'Days of the week': 'Haftanın günleri',
  'Monthly trend': 'Aylık gidişat',
  'Recent activity': 'Son dinlenenler',
  Completed: 'Tamamlandı',
  Skipped: 'Atlandı',
  Partial: 'Yarım kaldı',
  'Clear history': 'Geçmişi temizle',
  'Clear all listening history?': 'Tüm dinleme geçmişi silinsin mi?',
  'No listening history yet': 'Henüz dinleme geçmişi yok',
  'Play any song for a few seconds and NeoModern will build your listening summary here automatically.':
    'Herhangi bir şarkıyı birkaç saniye dinle; NeoModern dinleme özetini burada otomatik oluşturur.',
  'No tracks found in this period.': 'Bu aralıkta kayıtlı dinleme yok.',
  Mon: 'Pzt',
  Tue: 'Sal',
  Wed: 'Çar',
  Thu: 'Per',
  Fri: 'Cum',
  Sat: 'Cmt',
  Sun: 'Paz',
  Monday: 'Pazartesi',
  Tuesday: 'Salı',
  Wednesday: 'Çarşamba',
  Thursday: 'Perşembe',
  Friday: 'Cuma',
  Saturday: 'Cumartesi',
  Sunday: 'Pazar',
  '{h} hr {m} min': '{h} sa {m} dk',
  '{m} min': '{m} dk',
  '< 1 min': '< 1 dk',
  '{n} play': '{n} çalma',
  '{n} plays': '{n} çalma',
  Artists: 'Sanatçılar',
  '← Artists': '← Sanatçılar',
  'Filter artists…': 'Sanatçı filtrele…',
  'No artists match “{q}”.': '“{q}” ile eşleşen sanatçı yok.',
  'Your listens: {time} · {plays}': 'Dinlemen: {time} · {plays}',
  Popular: 'Popüler',
  'Albums in library': 'Kütüphanendeki albümler',
  'More albums (Online)': 'Diğer albümler (Çevrimiçi)',
  'All tracks': 'Tüm şarkılar',
  'Show less': 'Daha az göster',
  Home: 'Ana Menü',
  'Daily Mixes': 'Senin İçin Karışımlar',
  'Weekly Favorites': 'Haftanın Favorileri',
  'Most played and finished over the last 7 days':
    'Son 7 günde en çok dinlenen ve tamamlananlar',
  'On Repeat': 'Tekrar Tekrar',
  'Songs you kept coming back to this month': 'Bu ay dönüp dönüp çaldığın şarkılar',
  Rediscover: 'Yeniden Keşfet',
  "Favorites and past listens you haven't played lately":
    'Son zamanlarda çalmadığın favoriler ve eski dinlemelerin',
  '{name} Mix': '{name} Karışımı',
  'Inspired by what you played most lately': 'Son günlerde en çok dinlediklerinden esinlendi',
  'Recently played': 'Son çalınanlar',
  'Recently played tracks': 'Son çalınan şarkılar',
  'See all': 'Tümünü gör',
  'Mix saved as playlist “{name}”': 'Karışım “{name}” adıyla kaydedildi',
  'Mix could not be loaded.': 'Karışım yüklenemedi.',
  'Start playing some songs to unlock personalized mixes and recent history.':
    'Kişisel karışımların ve son dinlediklerinin oluşması için birkaç şarkı çal.',
  'Quick access': 'Hızlı erişim',
  'Dynamic mix': 'Dinamik karışım',
  'Good morning': 'Günaydın',
  'Good afternoon': 'İyi günler',
  'Good evening': 'İyi akşamlar',
  Appearance: 'Görünüm',
  Theme: 'Tema',
  Dark: 'Koyu',
  Light: 'Açık',
  'Choose whether NeoModern follows your system theme or stays dark or light.':
    'NeoModern’in sistem temasını mı izleyeceğini yoksa hep koyu ya da açık mı kalacağını seç.',
  All: 'Tümü',
  General: 'Genel',
  'Collapse sidebar': 'Kenar çubuğunu daralt',
  'Expand sidebar': 'Kenar çubuğunu genişlet',
  'Resize sidebar': 'Kenar çubuğunu yeniden boyutlandır',
  'Resize right panel': 'Sağ paneli yeniden boyutlandır',
  'Resize lyrics panel': 'Şarkı sözü panelini yeniden boyutlandır',
  'Lyrics preview': 'Şarkı sözü önizlemesi',
  'Show lyrics': 'Sözleri göster',
  'About the artist': 'Sanatçı hakkında',
  'Expand view': 'Tam ekran görünüm',
  'Close right panel': 'Sağ paneli kapat',
  'Gapless playback': 'Kesintisiz çalma (Gapless)',
  'Plays consecutive tracks without gaps or silence. Turn off to reset playback between tracks.':
    'Arka arkaya gelen parçaları arada boşluk ya da sessizlik olmadan çalar. Parçalar arasında çıkışın sıfırlanması için kapat.',
  'WASAPI exclusive mode': 'WASAPI özel (exclusive) modu',
  'Bypasses the Windows mixer for direct output at each track’s native format. Other apps cannot play sound while active.':
    'Windows ses karıştırıcısını atlayıp parçanın doğal biçimini doğrudan ses cihazına verir. Etkin olduğunda diğer uygulamalar ses çalamaz.',

  // Sort, context menu & bulk artist enrichment
  Duration: 'Süre',
  'Play next': 'Sıradaki olarak çal',
  'Queued to play next': 'Sıradaki şarkı olarak eklendi',
  'Added to queue': 'Sıraya eklendi',
  'Add to favorites': 'Favorilere ekle',
  'Remove from favorites': 'Favorilerden kaldır',
  'Remove from playlist': 'Çalma listesinden çıkar',
  'Go to artist': 'Sanatçıya git',
  'Go to album': 'Albüme git',
  'Show in folder': 'Klasörde göster',
  'Copy song info': 'Şarkı bilgisini kopyala',
  'Copied to clipboard': 'Panoya kopyalandı',
  'Artist profiles': 'Sanatçı profilleri',
  'Download artist photos and biographies from Deezer and Wikipedia for artists in your library.':
    'Kütüphanendeki sanatçılar için Deezer ve Wikipedia’dan fotoğraf ve biyografi indirir.',
  'Refresh missing': 'Eksikleri tamamla',
  'Rescan all': 'Tümünü yeniden tara',
  'All artist profiles are up to date.': 'Tüm sanatçı profilleri güncel.',
  'Updated {updated} of {total} artists.': '{total} sanatçıdan {updated} tanesi güncellendi.',
  'Artist scan cancelled ({done}/{total}).': 'Sanatçı taraması iptal edildi ({done}/{total}).',
  'Turn on “Artist profiles & albums” above to fetch artist info online.':
    'Çevrimiçi sanatçı bilgisi indirmek için yukarıdaki “Sanatçı profilleri ve albümleri” ayarını aç.',

  // Automatic yt-dlp / ffmpeg setup
  'Set up automatically': 'Otomatik kur',
  'Update yt-dlp': 'yt-dlp’yi güncelle',
  'Using the copies NeoModern downloaded.': 'NeoModern’in indirdiği kopyalar kullanılıyor.',
  'NeoModern can download the right version for your computer and keep it in its own folder.':
    'NeoModern bilgisayarına uygun sürümü indirip kendi klasöründe tutabilir.',
  'yt-dlp was not found. You can still browse albums; set it up with one click to stream and download.':
    'yt-dlp bulunamadı. Albümlere yine göz atabilirsin; dinlemek ve indirmek için tek tıkla kur.',
  'Downloading {name}…': '{name} indiriliyor…',
  'Downloading {name}: {got} / {total} MB': '{name} indiriliyor: {got} / {total} MB',
  'Checking {name}…': '{name} doğrulanıyor…',
  'Unpacking {name}…': '{name} açılıyor…',
  '{name} is ready': '{name} hazır',

  // Problem report
  'Report a problem': 'Sorun bildir',
  'The report has the app version, your system, your settings and the latest log lines. Your home folder is hidden.':
    'Rapor uygulama sürümünü, sistemini, ayarlarını ve son günlük satırlarını içerir. Kullanıcı klasörünün yolu gizlenir.',
  'Copy report': 'Raporu kopyala',
  'Report on GitHub': 'GitHub’da bildir',
  'Save report…': 'Raporu kaydet…',
  'Open log folder': 'Günlük klasörünü aç',
  'Save problem report': 'Sorun raporunu kaydet',
  'Text file': 'Metin dosyası',
  'Report saved.': 'Rapor kaydedildi.',
  'Report copied. Paste it wherever you ask for help.': 'Rapor kopyalandı. Yardım istediğin yere yapıştırabilirsin.',
  'Report copied. Paste it into the issue that just opened in your browser.':
    'Rapor kopyalandı. Tarayıcıda açılan sayfaya yapıştır.',

  // First-run welcome
  'Welcome to NeoModern': 'NeoModern’e hoş geldin',
  'Let’s find your music. It stays where it is; NeoModern only reads it.':
    'Önce müziklerini bulalım. Dosyalar yerinde kalır; NeoModern yalnızca okur.',
  'Optional: search and download music from the internet.': 'İsteğe bağlı: internetten müzik ara ve indir.',
  'Your Music folder': 'Müzik klasörün',
  'No songs found here yet.': 'Burada henüz şarkı yok.',
  'More than 5,000 songs found.': '5.000’den fazla şarkı bulundu.',
  '{n} song found': '{n} şarkı bulundu',
  '{n} songs found': '{n} şarkı bulundu',
  Added: 'Eklendi',
  'Use this folder': 'Bu klasörü kullan',
  'Add another folder…': 'Başka klasör ekle…',
  'Choose your music folder…': 'Müzik klasörünü seç…',
  'Scanning in the background, you can start listening right away.':
    'Arka planda taranıyor, hemen dinlemeye başlayabilirsin.',
  '{n} track in your library': 'Kütüphanende {n} şarkı var',
  '{n} tracks in your library': 'Kütüphanende {n} şarkı var',
  'Online search and download': 'Çevrimiçi arama ve indirme',
  'Needs two free tools, yt-dlp and ffmpeg. NeoModern can fetch the right version for your computer. You can also do this later in Settings.':
    'İki ücretsiz araç gerekir: yt-dlp ve ffmpeg. NeoModern bilgisayarına uygun sürümü indirebilir. Bunu daha sonra Ayarlar’dan da yapabilirsin.',
  Skip: 'Geç',
  'Start listening': 'Dinlemeye başla',
  'Pick the folder with your music. NeoModern asks for permission to read it, and only reads it.':
    'Müziklerinin olduğu klasörü seç. NeoModern okumak için izin ister ve yalnızca okur.',
  'Usually this is the Music or Download folder on your phone.':
    'Genellikle telefonundaki Music ya da Download klasörüdür.',

  // In-app update (Android)
  Update: 'Güncelle',
  'Downloading the update…': 'Güncelleme indiriliyor…',
  'Downloading the update… {p}%': 'Güncelleme indiriliyor… %{p}',
  'Allow NeoModern to install apps, then tap Update again.':
    'NeoModern’in uygulama yüklemesine izin ver, sonra yeniden Güncelle’ye dokun.',

  // Android open files
  '1 file could not be opened: it is not stored on this phone.':
    '1 dosya açılamadı: bu telefonda kayıtlı değil.',
  '{n} files could not be opened: they are not stored on this phone.':
    '{n} dosya açılamadı: bu telefonda kayıtlı değiller.',

  // Sleep timer, equalizer, crossfade (K16)
  'Sleep timer': 'Uyku zamanlayıcısı',
  'Sleep in {time}': '{time} sonra uyku',
  'Sleep at the end of this song': 'Bu şarkı bitince uyku',
  End: 'Son',
  '{n} minutes': '{n} dakika',
  '1 hour': '1 saat',
  '{h} hours': '{h} saat',
  'End of this song': 'Bu şarkı bitince',
  'Turn off timer': 'Zamanlayıcıyı kapat',
  Equalizer: 'Ekolayzer',
  'Ten bands from 31 Hz to 16 kHz. Lower the preamp when you boost, so loud parts do not distort.':
    '31 Hz ile 16 kHz arası on bant. Yükselttiğinde ön kazancı düşür ki yüksek yerler bozulmasın.',
  Presets: 'Hazır ayarlar',
  Flat: 'Düz',
  'Bass boost': 'Bas güçlendirme',
  'Treble boost': 'Tiz güçlendirme',
  Vocal: 'Vokal',
  Rock: 'Rock',
  Pop: 'Pop',
  Jazz: 'Caz',
  Classical: 'Klasik',
  Electronic: 'Elektronik',
  Acoustic: 'Akustik',
  Preamp: 'Ön kazanç',
  '{hz} Hz band': '{hz} Hz bandı',
  Crossfade: 'Geçiş (crossfade)',
  'Fades the end of a song into the start of the next one.':
    'Bir şarkının sonunu bir sonrakinin başıyla iç içe geçirir.',
  'Not available while WASAPI exclusive mode is on (it allows one sound at a time).':
    'WASAPI özel modu açıkken kullanılamaz (aynı anda tek ses çalınabilir).',
  '{s} s': '{s} sn',

  // Multi-select
  'Selected songs': 'Seçili şarkılar',
  'Playing {n}': '{n} çalınıyor',
  'Added to favorites': 'Favorilere eklendi',
  'Removed from favorites': 'Favorilerden çıkarıldı',
  Favorite: 'Favori',
  Experimental: 'Deneysel',
  'Online search, streaming & downloads (Experimental)':
    'Çevrimiçi arama, dinleme ve indirme (Deneysel)',
  'Built-in extractor (experimental) · downloads .m4a with tags & cover art':
    'Yerleşik çıkarıcı (deneysel) · etiketli ve kapaklı .m4a indirir',
  'Fades the end of a song into the start of the next one. Experimental: a short skip can be heard at the change, and gapless playback is not used while it is on.':
    'Bir şarkının sonunu bir sonrakinin başıyla iç içe geçirir. Deneysel: geçiş anında kısa bir atlama duyulabilir ve açıkken boşluksuz (gapless) çalma kullanılmaz.',

  // Save menu
  'Add “{title}” to a playlist': '“{title}” şarkısını bir listeye ekle',
  'Find a playlist': 'Liste ara',
  'Saved in': 'Kayıtlı olduğu yerler',
  'My playlist #{n}': 'Çalma listem #{n}',
  'Added to “{name}”': '“{name}” listesine eklendi',
  'Play “{title}”': '“{title}” çal',

  // Phone <-> computer sync and remote control
  Phone: 'Telefon',
  Computer: 'Bilgisayar',
  'Allow phone connections': 'Telefon bağlantılarına izin ver',
  'Your phone can sync favorites and playlists with this computer and control what it plays. Same Wi-Fi only; off by default. Windows may ask whether NeoModern may use the network.':
    'Telefonun favorilerini ve çalma listelerini bu bilgisayarla eşitleyebilir ve burada çalanı yönetebilir. Yalnızca aynı Wi-Fi ağında çalışır; varsayılan olarak kapalıdır. Windows, NeoModern’in ağı kullanmasına izin verip vermeyeceğini sorabilir.',
  'Waiting for phones on port {port}': '{port} numaralı bağlantı noktasında telefon bekleniyor',
  'Pair a phone': 'Telefon eşle',
  'Shows a code to type into NeoModern on your phone (Settings › Computer).':
    'Telefonundaki NeoModern’e yazacağın bir kod gösterir (Ayarlar › Bilgisayar).',
  'On your phone, enter this code': 'Telefonunda bu kodu gir',
  'and this address': 've bu adresi',
  'and one of these addresses': 've bu adreslerden birini',
  'No local network found. Connect this computer to Wi-Fi or a network cable.':
    'Yerel ağ bulunamadı. Bu bilgisayarı Wi-Fi’a ya da ağ kablosuna bağla.',
  'Expires in {time}': '{time} içinde geçersiz olur',
  'New code': 'Yeni kod',
  'The code has expired.': 'Kodun süresi doldu.',
  'Too many wrong codes were typed, so this code no longer works.':
    'Çok fazla yanlış kod girildi, bu kod artık geçerli değil.',
  'Paired phones': 'Eşlenmiş telefonlar',
  'No phones paired yet.': 'Henüz eşlenmiş telefon yok.',
  Connected: 'Bağlı',
  'Not connected': 'Bağlı değil',
  'Connecting…': 'Bağlanıyor…',
  'Syncing…': 'Eşitleniyor…',
  'Never synced': 'Hiç eşitlenmedi',
  'Synced just now': 'Az önce eşitlendi',
  'Synced {when}': 'Eşitlendi: {when}',
  '{sent} sent · {received} received · {changed} changed here':
    '{sent} gönderildi · {received} alındı · burada {changed} değişti',
  'Remove {device}? It can no longer sync or control this computer until you pair it again.':
    '{device} kaldırılsın mı? Yeniden eşleyene kadar bu bilgisayarla eşitleme yapamaz ve onu yönetemez.',
  'Computer name': 'Bilgisayar adı',
  'Your phone shows this name.': 'Telefonun bu adı gösterir.',
  'Phone name': 'Telefon adı',
  'The computer shows this name.': 'Bilgisayar bu adı gösterir.',
  'Connect to a computer': 'Bir bilgisayara bağlan',
  'Profiles': 'Profiller',
  'Profile: {name}': 'Profil: {name}',
  'Manage profiles': 'Profilleri yönet',
  'Each profile has its own favourites, playlists, listening history, statistics, pins and queue. The music library and settings are shared. Anyone using this device can switch profiles; there is no password.':
    'Her profilin kendi favorileri, çalma listeleri, dinleme geçmişi, istatistikleri, sabitlenenleri ve kuyruğu vardır. Müzik kütüphanesi ve ayarlar ortaktır. Bu cihazı kullanan herkes profil değiştirebilir; şifre yoktur.',
  'Profile name': 'Profil adı',
  'In use': 'Kullanımda',
  'Delete profile {name}': '{name} profilini sil',
  'Colour': 'Renk',
  'Up to {n} profiles': 'En çok {n} profil',
  'New profile name': 'Yeni profil adı',
  'Add profile': 'Profil ekle',
  'This removes its {favorites} favourites, {playlists} playlists and {listens} listens from this device. Music files are not touched.':
    'Bu, profilin {favorites} favorisini, {playlists} çalma listesini ve {listens} dinlemesini bu cihazdan siler. Müzik dosyalarına dokunulmaz.',
  'Delete profile': 'Profili sil',
  'On your phone, scan this code': 'Telefonunla bu kodu tara',
  'Pairing QR code': 'Eşleştirme QR kodu',
  'or enter this code': 'ya da bu kodu gir',
  'Scan the QR code': 'QR kodu tara',
  'or enter the address and code': 'ya da adresi ve kodu gir',
  'This is not a NeoModern pairing code. Scan the code shown in Settings › Phone on the computer.':
    'Bu bir NeoModern eşleştirme kodu değil. Bilgisayarda Ayarlar › Telefon’da görünen kodu tara.',
  'The code has no address. Connect the computer to Wi-Fi or a network cable and show a new code.':
    'Kodda adres yok. Bilgisayarı Wi-Fi’ye ya da kabloyla ağa bağla ve yeni bir kod göster.',
  'NeoModern needs the camera to scan the code. Allow it in the phone’s settings, or enter the code by hand.':
    'Kodu taramak için NeoModern’in kameraya ihtiyacı var. Telefonun ayarlarından izin ver ya da kodu elle gir.',
  'On the computer, open Settings › Phone, turn on “Allow phone connections” and choose “Pair a phone”. Both devices must be on the same Wi-Fi.':
    'Bilgisayarda Ayarlar › Telefon’u aç, “Telefon bağlantılarına izin ver”i aç ve “Telefon eşle”yi seç. İki cihaz da aynı Wi-Fi ağında olmalı.',
  'Computer address': 'Bilgisayarın adresi',
  Code: 'Kod',
  Connect: 'Bağlan',
  'Enter the address shown on the computer, e.g. 192.168.1.20.':
    'Bilgisayarda gösterilen adresi gir, örneğin 192.168.1.20.',
  'Use the computer’s local network address (it usually starts with 192.168. or 10.).':
    'Bilgisayarın yerel ağ adresini kullan (genellikle 192.168. ya da 10. ile başlar).',
  'Wrong code. Check the code on the computer and try again.':
    'Kod yanlış. Bilgisayardaki kodu kontrol edip yeniden dene.',
  'Too many wrong codes. Ask the computer for a new code.':
    'Çok fazla yanlış kod. Bilgisayardan yeni bir kod al.',
  'The code has expired. Ask the computer for a new code.':
    'Kodun süresi doldu. Bilgisayardan yeni bir kod al.',
  'The computer is not showing a code. Choose “Pair a phone” on the computer first.':
    'Bilgisayar bir kod göstermiyor. Önce bilgisayarda “Telefon eşle”yi seç.',
  'Another device is pairing right now. Try again in a moment.':
    'Şu anda başka bir cihaz eşleniyor. Biraz sonra yeniden dene.',
  'Cannot reach the computer. Check the address and that both devices are on the same Wi-Fi.':
    'Bilgisayara ulaşılamıyor. Adresi ve iki cihazın da aynı Wi-Fi ağında olduğunu kontrol et.',
  'The apps do not match. Update NeoModern on both devices.':
    'Uygulama sürümleri uyuşmuyor. İki cihazda da NeoModern’i güncelle.',
  'Enter the computer’s local address, e.g. 192.168.1.20.':
    'Bilgisayarın yerel adresini gir, örneğin 192.168.1.20.',
  'Remote control': 'Uzaktan kumanda',
  'Sync now': 'Şimdi eşitle',
  Forget: 'Unut',
  'Forget this computer': 'Bu bilgisayarı unut',
  'Forget {device}? Your music stays on both devices; to sync again you pair with a new code.':
    '{device} unutulsun mu? Müziklerin iki cihazda da kalır; yeniden eşitlemek için yeni bir kodla eşlersin.',
  '{device} wants to make big deletions here:': '{device} burada büyük silmeler yapmak istiyor:',
  'Remove {n} of your {m} favorites': '{m} favorinden {n} tanesini kaldırmak',
  'Delete the playlist {names}': '{names} listesini silmek',
  'Delete {n} playlists: {names}': '{n} çalma listesini silmek: {names}',
  'and {n} more': 've {n} tane daha',
  'Remove {n} of {m} songs from “{name}”': '“{name}” listesindeki {m} şarkıdan {n} tanesini kaldırmak',
  'Nothing was changed yet. Keep your data if this was not on purpose.':
    'Henüz hiçbir şey değişmedi. Bu bilerek yapılmadıysa verilerini koru.',
  'Keep my data': 'Verilerimi koru',
  'Playing on': 'Çalan cihaz',
  'Close remote control': 'Uzaktan kumandayı kapat',
  'Not connected to {device}': '{device} ile bağlantı yok',
  'No computer is paired': 'Eşlenmiş bilgisayar yok',
  'Make sure NeoModern is open on the computer, “Allow phone connections” is on, and both devices are on the same Wi-Fi.':
    'Bilgisayarda NeoModern’in açık, “Telefon bağlantılarına izin ver”in açık ve iki cihazın da aynı Wi-Fi ağında olduğundan emin ol.',
  'Pair with a computer in Settings › Computer.': 'Ayarlar › Bilgisayar’dan bir bilgisayarla eşle.',
  'Try again': 'Yeniden dene',
  'Nothing is playing': 'Hiçbir şey çalmıyor',
  'The queue changed on the computer. The list was reloaded; try again.':
    'Bilgisayardaki sıra değişti. Liste yenilendi; yeniden dene.',
  'Too many taps at once. Try again in a moment.': 'Aynı anda çok fazla dokunuş. Biraz sonra yeniden dene.',
  'Not connected to the computer.': 'Bilgisayara bağlı değil.',
  'The computer did not answer.': 'Bilgisayar yanıt vermedi.',
  'Nothing else in the queue.': 'Sırada başka şarkı yok.',
  'Show more': 'Daha fazla göster',
}
