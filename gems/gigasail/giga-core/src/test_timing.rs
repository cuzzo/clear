//! New-test timing for the diff "Tests" section: measure how long a change's
//! new tests take and compare against the recent per-stage baseline, reporting a
//! delta with a confidence interval that tightens as more repeat measurements
//! are taken. This module is the pure statistics; storage of the per-commit
//! history and the (background) measurement runner live elsewhere.
//!
//! Baseline uses the **median** of recent per-commit stage times - robust to the
//! occasional slow CI run that a mean would let skew the comparison. The CI
//! half-width comes from the repeat measurements of the new tests (Student-t
//! standard error for n>=2); with a single measurement it falls back to the
//! historical coefficient of variation, honestly reflecting that one run can't
//! bound its own noise.

/// The stage label new-test timings are stored under; the diff looks them up by
/// this label + test_set. Distinct from review stages: it identifies the "new
/// tests" measurement, independent of which review triggered it.
pub const TIMING_STAGE: &str = "new-tests";

#[derive(Debug, Clone, PartialEq)]
pub struct TimingDelta {
    /// Robust baseline (median of recent per-commit stage times), milliseconds.
    pub baseline_ms: f64,
    /// Measured new-test time (mean of the repeat samples), milliseconds.
    pub new_ms: f64,
    /// Percent change of new vs baseline (+ is slower).
    pub pct: f64,
    /// Confidence half-width in percentage points (the `+/-`).
    pub ci_pct: f64,
    /// Number of repeat measurements taken of the new tests.
    pub samples: usize,
    /// Number of historical commits behind the baseline.
    pub baseline_n: usize,
}

/// Human time: `7.3s` for a second or more, else `123ms`.
pub fn fmt_ms(ms: f64) -> String {
    if ms >= 1000.0 {
        format!("{:.1}s", ms / 1000.0)
    } else {
        format!("{ms:.0}ms")
    }
}

/// Median of a sample. `None` for an empty input.
pub fn median(mut xs: Vec<f64>) -> Option<f64> {
    if xs.is_empty() {
        return None;
    }
    xs.sort_by(|a, b| a.partial_cmp(b).unwrap_or(std::cmp::Ordering::Equal));
    let mid = xs.len() / 2;
    Some(if xs.len() % 2 == 0 {
        (xs[mid - 1] + xs[mid]) / 2.0
    } else {
        xs[mid]
    })
}

/// Two-sided 95% Student-t factor for `n-1` degrees of freedom, small-n table
/// with a large-n normal fallback (1.96). Used to widen the CI for few repeats.
fn t95(n: usize) -> f64 {
    match n {
        0 | 1 => 12.71, // df=1 (a lone pair would be unusual; conservative)
        2 => 12.71,     // df=1
        3 => 4.30,      // df=2
        4 => 3.18,      // df=3
        5 => 2.78,
        6 => 2.57,
        7 => 2.45,
        8 => 2.36,
        9 => 2.31,
        10 => 2.26,
        11..=16 => 2.13,
        17..=31 => 2.04,
        _ => 1.96,
    }
}

/// Coefficient of variation (stddev / median) of the baseline history. Used as
/// the uncertainty when only one new-test measurement exists.
fn historical_cv(baseline: &[f64]) -> f64 {
    let Some(m) = median(baseline.to_vec()) else {
        return 0.0;
    };
    if m <= 0.0 || baseline.len() < 2 {
        return 0.0;
    }
    let mean = baseline.iter().sum::<f64>() / baseline.len() as f64;
    let var =
        baseline.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (baseline.len() as f64 - 1.0);
    var.sqrt() / m
}

/// Compute the timing delta of the new-test measurements against the historical
/// per-stage baseline. `None` when there is no usable baseline or no samples.
pub fn timing_delta(baseline: &[f64], new_samples: &[f64]) -> Option<TimingDelta> {
    let baseline_ms = median(baseline.to_vec())?;
    if baseline_ms <= 0.0 || new_samples.is_empty() {
        return None;
    }
    let n = new_samples.len();
    let new_ms = new_samples.iter().sum::<f64>() / n as f64;
    let pct = (new_ms - baseline_ms) / baseline_ms * 100.0;
    let ci_pct = if n >= 2 {
        // Standard error of the new-sample mean, as a percent of baseline.
        let var = new_samples.iter().map(|x| (x - new_ms).powi(2)).sum::<f64>() / (n as f64 - 1.0);
        let se = var.sqrt() / (n as f64).sqrt();
        t95(n) * se / baseline_ms * 100.0
    } else {
        // One measurement can't bound its own noise; use the history's spread.
        historical_cv(baseline) * 100.0
    };
    Some(TimingDelta {
        baseline_ms,
        new_ms,
        pct,
        ci_pct,
        samples: n,
        baseline_n: baseline.len(),
    })
}

/// Like [`timing_delta`] but from the stored summary statistics (mean + stddev +
/// sample count) rather than raw samples - what a recorded measurement carries.
pub fn timing_delta_from_stats(
    baseline: &[f64],
    new_mean: f64,
    new_stddev: f64,
    n: usize,
) -> Option<TimingDelta> {
    let baseline_ms = median(baseline.to_vec())?;
    if baseline_ms <= 0.0 || n == 0 {
        return None;
    }
    let pct = (new_mean - baseline_ms) / baseline_ms * 100.0;
    let ci_pct = if n >= 2 {
        let se = new_stddev / (n as f64).sqrt();
        t95(n) * se / baseline_ms * 100.0
    } else {
        historical_cv(baseline) * 100.0
    };
    Some(TimingDelta {
        baseline_ms,
        new_ms: new_mean,
        pct,
        ci_pct,
        samples: n,
        baseline_n: baseline.len(),
    })
}

/// Sample mean and (population-corrected) standard deviation of measurements.
/// The runner stores these; `timing_delta_from_stats` consumes them.
pub fn mean_stddev(samples: &[f64]) -> (f64, f64) {
    let n = samples.len();
    if n == 0 {
        return (0.0, 0.0);
    }
    let mean = samples.iter().sum::<f64>() / n as f64;
    if n < 2 {
        return (mean, 0.0);
    }
    let var = samples.iter().map(|x| (x - mean).powi(2)).sum::<f64>() / (n as f64 - 1.0);
    (mean, var.sqrt())
}

#[cfg(test)]
mod tests {
    use super::*;

    fn approx(a: f64, b: f64, eps: f64) -> bool {
        (a - b).abs() < eps
    }

    #[test]
    fn median_is_robust_to_a_slow_outlier() {
        // A single slow run must not drag the baseline the way a mean would.
        assert_eq!(median(vec![100.0, 102.0, 98.0, 500.0]), Some(101.0));
        assert_eq!(median(vec![100.0]), Some(100.0));
        assert_eq!(median(vec![]), None);
    }

    #[test]
    fn delta_is_percent_over_the_median_baseline() {
        // baseline median 100ms (a slow 500ms run is ignored); new ~102ms -> +2%.
        let d = timing_delta(&[100.0, 98.0, 102.0, 100.0, 500.0], &[102.0, 102.0, 102.0]).unwrap();
        assert!(approx(d.baseline_ms, 100.0, 0.001));
        assert!(approx(d.pct, 2.0, 0.001));
        assert_eq!(d.samples, 3);
    }

    #[test]
    fn ci_tightens_with_more_repeat_measurements() {
        // Same spread of samples, more repeats -> a narrower confidence band.
        let few = timing_delta(&[100.0, 100.0, 100.0], &[100.0, 110.0]).unwrap();
        let many = timing_delta(
            &[100.0, 100.0, 100.0],
            &[100.0, 110.0, 100.0, 110.0, 100.0, 110.0],
        )
        .unwrap();
        assert!(
            many.ci_pct < few.ci_pct,
            "more samples should narrow CI: few={} many={}",
            few.ci_pct,
            many.ci_pct
        );
    }

    #[test]
    fn single_measurement_uses_historical_variability() {
        // With n=1 the CI reflects how noisy the history is, not zero.
        let noisy = timing_delta(&[80.0, 120.0, 90.0, 110.0], &[100.0]).unwrap();
        let steady = timing_delta(&[100.0, 100.0, 100.0, 100.0], &[100.0]).unwrap();
        assert_eq!(noisy.samples, 1);
        assert!(noisy.ci_pct > steady.ci_pct);
        assert!(approx(steady.ci_pct, 0.0, 0.001), "steady history -> tiny CI");
    }

    #[test]
    fn delta_from_stats_matches_raw_samples() {
        let baseline = [100.0, 100.0, 100.0];
        let samples = [98.0, 102.0, 100.0, 104.0];
        let (mean, sd) = mean_stddev(&samples);
        let raw = timing_delta(&baseline, &samples).unwrap();
        let stats = timing_delta_from_stats(&baseline, mean, sd, samples.len()).unwrap();
        assert!(approx(raw.pct, stats.pct, 1e-9));
        assert!(approx(raw.ci_pct, stats.ci_pct, 1e-9));
    }

    #[test]
    fn no_baseline_or_no_samples_is_none() {
        assert!(timing_delta(&[], &[100.0]).is_none());
        assert!(timing_delta(&[100.0], &[]).is_none());
    }
}
