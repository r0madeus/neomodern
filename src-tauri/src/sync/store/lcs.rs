//! Sequence alignment used by playlist capture.

/// Above this many DP cells the alignment falls back to a greedy match
/// (keeps memory bounded; only affects which entries keep their uuid).
const MAX_DP_CELLS: usize = 4_000_000;

/// Index pairs `(i, j)` of a longest common subsequence of `a` and `b`,
/// increasing in both. Common prefix and suffix are matched directly, so
/// the usual small edit of a long playlist is cheap.
pub fn lcs<T: PartialEq>(a: &[T], b: &[T]) -> Vec<(usize, usize)> {
    let mut pre = 0;
    while pre < a.len() && pre < b.len() && a[pre] == b[pre] {
        pre += 1;
    }
    let mut suf = 0;
    while suf < a.len() - pre && suf < b.len() - pre && a[a.len() - 1 - suf] == b[b.len() - 1 - suf]
    {
        suf += 1;
    }
    let mid_a = &a[pre..a.len() - suf];
    let mid_b = &b[pre..b.len() - suf];
    let mut out: Vec<(usize, usize)> = (0..pre).map(|i| (i, i)).collect();
    let middle = if mid_a.len().saturating_mul(mid_b.len()) <= MAX_DP_CELLS {
        dp(mid_a, mid_b)
    } else {
        greedy(mid_a, mid_b)
    };
    out.extend(middle.into_iter().map(|(i, j)| (i + pre, j + pre)));
    out.extend((0..suf).map(|k| (a.len() - suf + k, b.len() - suf + k)));
    out
}

fn dp<T: PartialEq>(a: &[T], b: &[T]) -> Vec<(usize, usize)> {
    let (n, m) = (a.len(), b.len());
    let width = m + 1;
    // table[i][j] = LCS length of a[i..] and b[j..]
    let mut table = vec![0u32; (n + 1) * width];
    for i in (0..n).rev() {
        for j in (0..m).rev() {
            table[i * width + j] = if a[i] == b[j] {
                table[(i + 1) * width + j + 1] + 1
            } else {
                table[(i + 1) * width + j].max(table[i * width + j + 1])
            };
        }
    }
    let (mut i, mut j) = (0, 0);
    let mut out = Vec::new();
    while i < n && j < m {
        if a[i] == b[j] {
            out.push((i, j));
            i += 1;
            j += 1;
        } else if table[(i + 1) * width + j] >= table[i * width + j + 1] {
            i += 1;
        } else {
            j += 1;
        }
    }
    out
}

/// Matches each item of `a` with the next equal item of `b`.
fn greedy<T: PartialEq>(a: &[T], b: &[T]) -> Vec<(usize, usize)> {
    let mut out = Vec::new();
    let mut next = 0;
    for (i, x) in a.iter().enumerate() {
        if let Some(off) = b[next..].iter().position(|y| y == x) {
            out.push((i, next + off));
            next += off + 1;
        }
    }
    out
}

/// Indexes of a longest strictly increasing subsequence of the `Some`
/// items (`None` items are never part of it).
pub fn lis<K: Ord>(items: &[Option<K>]) -> Vec<usize> {
    // tails[k] = index of the smallest tail of an increasing run of length k+1
    let mut tails: Vec<usize> = Vec::new();
    let mut prev: Vec<Option<usize>> = vec![None; items.len()];
    for (i, item) in items.iter().enumerate() {
        let Some(key) = item else { continue };
        let at = tails.partition_point(|&t| items[t].as_ref().is_some_and(|k| k < key));
        if at > 0 {
            prev[i] = Some(tails[at - 1]);
        }
        if at == tails.len() {
            tails.push(i);
        } else {
            tails[at] = i;
        }
    }
    let mut out = Vec::with_capacity(tails.len());
    let mut cur = tails.last().copied();
    while let Some(i) = cur {
        out.push(i);
        cur = prev[i];
    }
    out.reverse();
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn lcs_finds_common_items() {
        let a = [1, 2, 3, 4, 5, 6];
        let b = [1, 3, 4, 9, 6];
        let m = lcs(&a, &b);
        let common: Vec<i32> = m.iter().map(|&(i, _)| a[i]).collect();
        assert_eq!(common, vec![1, 3, 4, 6]);
        assert!(m.iter().all(|&(i, j)| a[i] == b[j]));
    }

    #[test]
    fn lcs_handles_empty_and_duplicates() {
        assert!(lcs::<i32>(&[], &[1]).is_empty());
        let m = lcs(&[7, 7, 7], &[7, 7]);
        assert_eq!(m.len(), 2);
    }

    #[test]
    fn lis_is_strict() {
        let items = [Some(3), None, Some(1), Some(2), Some(2), Some(5)];
        let idx = lis(&items);
        let vals: Vec<i32> = idx.iter().map(|&i| items[i].unwrap()).collect();
        assert_eq!(vals, vec![1, 2, 5]);
    }
}
