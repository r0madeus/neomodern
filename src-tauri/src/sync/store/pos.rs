//! Fractional indexes for playlist order.
//!
//! A position is a base-36 digit string (`0-9a-z`, compared as plain
//! strings) that never ends in `0`. Between any two distinct positions
//! there is always another one, so inserting or moving an entry re-stamps
//! only that entry, and two devices editing different parts of a playlist
//! do not conflict.

use super::MAX_STR_BYTES;

const BASE: u8 = 36;
const DIGITS: &[u8; 36] = b"0123456789abcdefghijklmnopqrstuvwxyz";

fn value(c: u8) -> Option<u8> {
    match c {
        b'0'..=b'9' => Some(c - b'0'),
        b'a'..=b'z' => Some(c - b'a' + 10),
        _ => None,
    }
}

fn encode(digits: &[u8]) -> String {
    digits
        .iter()
        .map(|&d| DIGITS[usize::from(d)] as char)
        .collect()
}

fn decode(s: &str) -> Vec<u8> {
    s.bytes().filter_map(value).collect()
}

/// Non-empty, base-36 digits only, not ending in `0`, at most 1 KiB.
pub fn is_valid(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_STR_BYTES
        && s.bytes().all(|b| value(b).is_some())
        && !s.ends_with('0')
}

/// A position strictly between `lo` and `hi` (`None` = open end).
///
/// Appending (`hi == None`) uses the shortest increment, so a playlist that
/// grows one song at a time grows its positions by one character per ~35
/// songs. When `lo >= hi` (only possible with corrupt input) the result is
/// simply after `lo`.
pub fn between(lo: Option<&str>, hi: Option<&str>) -> String {
    let a = lo.map(decode).unwrap_or_default();
    match hi {
        None if lo.is_none() => encode(&[BASE / 2]),
        None => encode(&after(&a)),
        Some(h) if lo.is_some_and(|l| l >= h) => encode(&after(&a)),
        Some(h) => encode(&midpoint(&a, Some(&decode(h)))),
    }
}

/// `n` increasing positions strictly between `lo` and `hi`, spread by
/// bisection so their length grows only with log(n).
pub fn spread(lo: Option<&str>, hi: Option<&str>, n: usize) -> Vec<String> {
    if n == 0 {
        return Vec::new();
    }
    if n == 1 {
        return vec![between(lo, hi)];
    }
    let mid = match (lo, hi) {
        (_, Some(h)) if lo.is_some_and(|l| l >= h) => between(lo, hi),
        _ => encode(&midpoint(
            &lo.map(decode).unwrap_or_default(),
            hi.map(decode).as_deref(),
        )),
    };
    let left = (n - 1) / 2;
    let mut out = spread(lo, Some(&mid), left);
    let right = spread(Some(&mid), hi, n - 1 - left);
    out.push(mid);
    out.extend(right);
    out
}

/// The shortest string greater than `a`.
fn after(a: &[u8]) -> Vec<u8> {
    for (i, &d) in a.iter().enumerate() {
        if d < BASE - 1 {
            let mut out = a[..i].to_vec();
            out.push(d + 1);
            return out;
        }
    }
    let mut out = a.to_vec();
    out.push(1);
    out
}

/// Classic fractional-index midpoint: requires `a < b` and neither ending
/// in zero; `b == None` is the open upper end.
fn midpoint(a: &[u8], b: Option<&[u8]>) -> Vec<u8> {
    if let Some(b) = b {
        // Skip the common prefix (`a` is padded with zeros).
        let mut n = 0;
        while n < b.len() && a.get(n).copied().unwrap_or(0) == b[n] {
            n += 1;
        }
        if n == b.len() {
            // Only reachable with a >= b (corrupt input): stay after `a`.
            return after(a);
        }
        if n > 0 {
            let mut out = b[..n].to_vec();
            out.extend(midpoint(a.get(n..).unwrap_or(&[]), Some(&b[n..])));
            return out;
        }
    }
    let da = a.first().copied().unwrap_or(0);
    let db = b.and_then(|b| b.first().copied()).unwrap_or(BASE);
    if db > da + 1 {
        return vec![(da + db) / 2];
    }
    if let Some(b) = b
        && b.len() > 1
    {
        return vec![b[0]];
    }
    let mut out = vec![da];
    out.extend(midpoint(a.get(1..).unwrap_or(&[]), None));
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn between_is_strictly_between() {
        let cases = [
            (None, None),
            (Some("i"), None),
            (None, Some("i")),
            (Some("1"), Some("2")),
            (Some("a"), Some("a1")),
            (Some("az"), Some("b")),
            (Some("zz"), None),
            (None, Some("01")),
            (Some("0001"), Some("0002")),
        ];
        for (lo, hi) in cases {
            let m = between(lo, hi);
            assert!(is_valid(&m), "{m}");
            if let Some(lo) = lo {
                assert!(lo < m.as_str(), "{lo} < {m}");
            }
            if let Some(hi) = hi {
                assert!(m.as_str() < hi, "{m} < {hi}");
            }
        }
    }

    #[test]
    fn spread_is_sorted_and_short() {
        let keys = spread(None, None, 5000);
        assert!(keys.windows(2).all(|w| w[0] < w[1]));
        assert!(keys.iter().all(|k| is_valid(k) && k.len() <= 6));
        let inner = spread(Some("a"), Some("a1"), 100);
        assert!(inner.windows(2).all(|w| w[0] < w[1]));
        assert!(inner.iter().all(|k| "a" < k.as_str() && k.as_str() < "a1"));
    }

    #[test]
    fn appending_one_at_a_time_stays_short() {
        let mut last: Option<String> = None;
        for _ in 0..20_000 {
            let next = between(last.as_deref(), None);
            if let Some(l) = &last {
                assert!(l < &next);
            }
            last = Some(next);
        }
        assert!(last.unwrap().len() < MAX_STR_BYTES);
    }
}
