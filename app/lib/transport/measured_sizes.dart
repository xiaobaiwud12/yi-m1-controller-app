/// The byte counts this app's comments quote, in one place.
///
/// ## Why this file exists
///
/// `analysis/79` #19 and #20 are both about a number written into prose that its own
/// source does not support:
///
/// * the size of one `Original` JPEG was quoted as a single figure across five files, and
///   the source it cites records **4,897,837 B** while a second pass records
///   **5,565,238 B**. The quoted figure matched neither.
/// * `MidThumb` was quoted as having a size the two measurements do not give it: they are
///   **106,375 B** and **196,495 B**, a factor of nearly two apart.
///
/// A number in a comment cannot be tested, so it drifts — and these had drifted into
/// decisions: the thumbnail cache's cap is *argued* from the size of an `Original`, and a
/// cap derived from a wrong size is a wrong cap that looks argued. So the numbers live
/// here as **named constants with their provenance**, and two checks read them:
///
/// * `tool/verify_transport.dart` asserts the derived bounds (the cap against the smallest
///   measured `Original`, an entry against the cap) and spot-checks every byte count
///   against the figures the analysis records;
/// * `test/measured_sizes_test.dart` scans every `N MB` / `N KB` figure in `lib/` and
///   `tool/` and fails for one that is not one of these constants — which is what stops
///   the next invented size.
///
/// ## What is measured, and by whom
///
/// | file | rendition | bytes | where |
/// |---|---|---|---|
/// | `P9140002.JPG` | `Original` | 4,897,837 | `analysis/50` §2 |
/// | `P9140002.JPG` | `MidThumb` | 106,375 | `analysis/50` §2 |
/// | `P9140002.JPG` | `Thumbnail` | 3,552 | `analysis/50` §2 |
/// | `P9150034.JPG` | `Original` | 5,565,238 | `analysis/61` §1 |
/// | `P9150034.JPG` | `MidThumb` | 196,495 | `analysis/61` §1 |
/// | `P9150034.JPG` | `Thumbnail` | 6,785 | `analysis/61` §1 |
/// | `P9150034.DNG` | `Original` | 31,931,408 | `analysis/61` §1 |
///
/// Both passes are `GetFile` over the real body with `DIRECT_CAMERA=1`. **Two samples of
/// two different photographs** — which is why every size here exists twice, and why a
/// comment that quotes one exact figure as "the" size is overclaiming even when the figure
/// is right.
///
/// ## What is deliberately not here
///
/// **A transfer rate.** The download side has been quoted as a rate derived from one file
/// size over one wall-clock reading, and that derivation is unsupported three times over:
/// the size was wrong, the reading is a single sample, and nothing records whether the
/// live-view stream was running — which is the one variable that matters, since the whole
/// point of the pause seam is that the two share one link. `analysis/16` retracted the
/// *stream's* rate for being a single unrepresentative sample; the transfer's rate is the
/// same shape and has now been withdrawn on the same ground. What the tree can say is the
/// byte counts above, and that a download completes in seconds rather than minutes.
library;

/// One `Original` JPEG on this camera, in bytes — the two recorded samples.
///
/// Two, not one, on purpose: the smallest is what a thumbnail cache has to stay below
/// (`kSmallestMeasuredJpegOriginalBytes`), and a comment that quotes "the" size has to
/// pick one and say which.
const List<int> kMeasuredJpegOriginalBytes = <int>[4897837, 5565238];

/// One `MidThumb` JPEG, in bytes — the two recorded samples.
///
/// 106 KB and 196 KB: the spread is why the cache's entry limit is a *shape* (one small
/// rendition) rather than a size.
const List<int> kMeasuredMidThumbBytes = <int>[106375, 196495];

/// One grid `Thumbnail`, in bytes — the two recorded samples.
///
/// The larger is what the "a card of tiles costs this much" arithmetic uses, and it is the
/// safe direction: a card costs *at most* this.
const List<int> kMeasuredThumbnailBytes = <int>[3552, 6785];

/// One `Original` `.DNG` (RAW) on this camera, in bytes.
///
/// One value on two files: both passes report 31,931,408 B for a `.DNG` `Original`, which
/// is worth noting rather than rounding away — it suggests a fixed-size container rather
/// than a compressed image.
const int kMeasuredRawOriginalBytes = 31931408;

/// The smallest observed `Original` JPEG, in bytes.
///
/// The number the thumbnail cache's cap must sit below: a cache able to hold one
/// photograph's worth of room is a cache that can evict a card's thumbnails to store a
/// picture that is not a thumbnail.
const int kSmallestMeasuredJpegOriginalBytes = 4897837;

/// What a 1000-shot card of grid thumbnails costs, at the larger measured tile size.
///
/// 6,785,000 B. Quoted in the cache's comment as the card-sized figure, and asserted
/// there — **not** as a bound the cap satisfies, because the storage bound above it is
/// stricter and the two cannot both hold. See `kAlbumThumbnailCacheMaxBytes`.
const int kMeasuredCardOfThumbnailsBytes = 6785 * 1000;

/// [bytes] as the decimal megabytes a comment should quote — `4.9`, `5.6`, `31.9`.
///
/// Decimal, not binary: `analysis/50` and `analysis/61` write `31.9 MB` for 31,931,408 B,
/// and matching the recorded figures is the entire purpose. A MiB value would silently
/// disagree with every citation in `analysis/`.
String mbLabel(int bytes) => (bytes / 1000000).toStringAsFixed(1);

/// [bytes] as the whole kilobytes a comment should quote, rounded to nearest.
String kbLabel(int bytes) => '${(bytes / 1000).round()}';

/// What a full card's worth of grid thumbnails costs: **1000 shots at the larger measured
/// tile size**, which is what the thumbnail cache is sized against.
///
/// Derived rather than typed: `analysis/50` §2 measured 6,785 B for a `.JPG` at `Thumbnail`
/// on the real body, and the 1000 is the round card size the cache comment reasons about.
/// Writing the product out means the two cannot drift — change either measurement and this
/// moves with it, which is the whole point of keeping sizes in one file (`analysis/79` #19).
const int kThousandShotCardBytes = 1000 * 6785;