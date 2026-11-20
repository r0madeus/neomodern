//! Alphabetical order for album titles and artist names ("A to Z").
//!
//! SQLite's `NOCASE` only folds ASCII, so "Çalgı", "Öykü" or "Şişe" sorted
//! after "Zeki". This collation, `neoalpha`, puts every letter where a reader
//! looks for it:
//!
//! - case does not matter;
//! - the Turkish letters sit in their own places of the Turkish alphabet
//!   (… c ç d …, … g ğ h ı i …, … o ö p …, … s ş t …, … u ü v …) while q, w
//!   and x keep their English places, so a library with both languages reads
//!   naturally;
//! - other accented Latin letters sort with their base letter (é with e);
//! - spaces and punctuation come first, then digits, then letters, then other
//!   scripts (Cyrillic, Japanese …) by code point;
//! - a leading "The " does not count ("The Bends" sits under B, like
//!   "Bends"); only "The", because "A" and "An" are real words in other
//!   languages. When two names differ only by that article, the one without
//!   it comes first;
//! - names that differ only in case are equal, as with `NOCASE`, which the
//!   title and artist columns use (so "Zed" and "zed" stay one artist);
//!   names that differ in accents keep a fixed order.
//!
//! Indexes are built with this collation (see schema v17), so the order must
//! never change without rebuilding them (`REINDEX`).
//!
//! It compares letter by letter without building keys, so sorting a few
//! thousand names costs nothing noticeable.

use std::cmp::Ordering;

/// The name the collation is registered under (see `db::init`).
pub const COLLATION: &str = "neoalpha";

/// The alphabet in order: Turkish and English letters interleaved.
const ALPHABET: &str = "abcçdefgğhıijklmnoöpqrsştuüvwxyz";

fn letter_weight(c: char) -> Option<u32> {
    ALPHABET
        .chars()
        .position(|l| l == c)
        .map(|i| 100 + i as u32)
}

/// Lower-case `c`, with accents of letters that are not part of the Turkish
/// alphabet folded onto their base letter.
fn fold(c: char) -> char {
    match c {
        'à' | 'á' | 'â' | 'ä' | 'ã' | 'å' | 'ā' | 'ă' | 'ą' | 'æ' => 'a',
        'ć' | 'č' | 'ĉ' | 'ċ' => 'c',
        'ď' | 'đ' => 'd',
        'è' | 'é' | 'ê' | 'ë' | 'ē' | 'ė' | 'ę' | 'ě' => 'e',
        'ĝ' | 'ġ' | 'ģ' => 'g',
        'ì' | 'í' | 'î' | 'ï' | 'ī' | 'į' => 'i',
        'ĺ' | 'ľ' | 'ł' | 'ļ' => 'l',
        'ñ' | 'ń' | 'ň' | 'ņ' => 'n',
        'ò' | 'ó' | 'ô' | 'õ' | 'ø' | 'ō' | 'ő' | 'œ' => 'o',
        'ŕ' | 'ř' => 'r',
        'ś' | 'š' | 'ß' => 's',
        'ť' | 'ţ' => 't',
        'ù' | 'ú' | 'û' | 'ū' | 'ů' | 'ű' | 'ų' => 'u',
        'ý' | 'ÿ' => 'y',
        'ź' | 'ż' | 'ž' => 'z',
        other => other,
    }
}

fn weight(c: char) -> u32 {
    if c.is_whitespace() {
        1
    } else if let Some(d) = c.to_digit(10).filter(|_| c.is_ascii_digit()) {
        10 + d
    } else if let Some(w) = letter_weight(fold(c)) {
        w
    } else if c.is_alphanumeric() {
        // Other scripts, and letters not folded above.
        1_000 + c as u32
    } else {
        // Punctuation and symbols.
        2
    }
}

/// The weights of `s`, case folded; combining marks (the dot `to_lowercase`
/// leaves on İ) count for nothing.
fn weights(s: &str) -> impl Iterator<Item = u32> + '_ {
    s.chars()
        .flat_map(char::to_lowercase)
        .filter(|c| !('\u{300}'..='\u{36f}').contains(c))
        .map(weight)
}

/// `s` without a leading "The " (when something follows it).
fn without_article(s: &str) -> &str {
    let trimmed = s.trim_start();
    match trimmed.get(..4) {
        Some(head) if head.eq_ignore_ascii_case("the ") && !trimmed[4..].trim().is_empty() => {
            trimmed[4..].trim_start()
        }
        _ => s,
    }
}

/// Compares two names alphabetically (see the module docs).
pub fn compare(a: &str, b: &str) -> Ordering {
    weights(without_article(a))
        .cmp(weights(without_article(b)))
        .then_with(|| weights(a).cmp(weights(b)))
        .then_with(|| a.to_lowercase().cmp(&b.to_lowercase()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sorted(mut names: Vec<&str>) -> Vec<&str> {
        names.sort_by(|a, b| compare(a, b));
        names
    }

    #[test]
    fn a_leading_the_does_not_count() {
        assert_eq!(
            sorted(vec![
                "The Smiths",
                "Tame Impala",
                "The Bends",
                "Bends",
                "Kid A",
                "the cure",
                "The",
                "The The",
                "Thee Oh Sees"
            ]),
            [
                "Bends",
                "The Bends",
                "the cure",
                "Kid A",
                "The Smiths",
                "Tame Impala",
                "The",
                "The The",
                "Thee Oh Sees"
            ]
        );
    }

    #[test]
    fn english_names_ignore_case() {
        assert_eq!(
            sorted(vec![
                "radiohead",
                "Daft Punk",
                "ABBA",
                "Kraftwerk",
                "abba2",
                "Air"
            ]),
            [
                "ABBA",
                "abba2",
                "Air",
                "Daft Punk",
                "Kraftwerk",
                "radiohead"
            ]
        );
    }

    #[test]
    fn turkish_letters_sit_in_the_turkish_alphabet() {
        let names = vec![
            "Zeki Müren",
            "Şebnem Ferah",
            "Sezen Aksu",
            "Çiğdem",
            "Cem Karaca",
            "Özdemir Erdoğan",
            "Orhan Gencebay",
            "Ümit Besen",
            "Ufuk",
            "İbrahim Tatlıses",
            "Işın Karaca",
            "Güneş",
            "Gülşen",
            "Ğ",
            "Haluk Levent",
            "Hakan",
        ];
        assert_eq!(
            sorted(names),
            [
                "Cem Karaca",
                "Çiğdem",
                "Gülşen",
                "Güneş",
                "Ğ",
                "Hakan",
                "Haluk Levent",
                "İbrahim Tatlıses",
                "Işın Karaca",
                "Orhan Gencebay",
                "Özdemir Erdoğan",
                "Sezen Aksu",
                "Şebnem Ferah",
                "Ufuk",
                "Ümit Besen",
                "Zeki Müren",
            ]
        );
    }

    #[test]
    fn other_accents_sort_with_their_base_letter() {
        assert_eq!(
            sorted(vec![
                "Fela Kuti",
                "Édith Piaf",
                "Daft Punk",
                "Eagles",
                "Ñandú",
                "Nirvana",
                "Zaz"
            ]),
            [
                "Daft Punk",
                "Eagles",
                "Édith Piaf",
                "Fela Kuti",
                "Ñandú",
                "Nirvana",
                "Zaz"
            ]
        );
    }

    #[test]
    fn symbols_digits_letters_then_other_scripts() {
        assert_eq!(
            sorted(vec![
                "Дюна",
                "Zeki",
                "2Pac",
                "(Sandy) Alex G",
                "10cc",
                "A",
                "!!!",
                "日本"
            ]),
            [
                "!!!",
                "(Sandy) Alex G",
                "10cc",
                "2Pac",
                "A",
                "Zeki",
                "Дюна",
                "日本"
            ]
        );
    }

    #[test]
    fn the_order_is_total_and_consistent() {
        let names = [
            "abc", "ABC", "Abc", "abç", "ÇABC", "cabc", "", " ", "İ", "i", "I", "ı",
        ];
        for a in names {
            assert_eq!(compare(a, a), Ordering::Equal, "{a:?}");
            for b in names {
                assert_eq!(compare(a, b), compare(b, a).reverse(), "{a:?} {b:?}");
                if a.to_lowercase() != b.to_lowercase() {
                    assert_ne!(compare(a, b), Ordering::Equal, "{a:?} {b:?}");
                } else {
                    assert_eq!(compare(a, b), Ordering::Equal, "{a:?} {b:?}");
                }
                for c in names {
                    if compare(a, b) != Ordering::Greater && compare(b, c) != Ordering::Greater {
                        assert_ne!(compare(a, c), Ordering::Greater, "{a:?} {b:?} {c:?}");
                    }
                }
            }
        }
    }
}
