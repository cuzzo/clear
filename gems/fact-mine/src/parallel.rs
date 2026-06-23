use anyhow::{bail, Result};
use std::env;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::mpsc;
use std::thread;

static JOBS_OVERRIDE: AtomicUsize = AtomicUsize::new(0);
const DEFAULT_MAX_JOBS: usize = 8;

pub fn set_jobs_for_process(jobs: Option<usize>) -> Result<()> {
    let Some(jobs) = jobs else {
        return Ok(());
    };
    if jobs == 0 {
        bail!("--jobs must be greater than zero");
    }
    JOBS_OVERRIDE.store(jobs, Ordering::Relaxed);
    Ok(())
}

pub fn job_count() -> usize {
    let configured = JOBS_OVERRIDE.load(Ordering::Relaxed);
    if configured > 0 {
        return configured;
    }

    env_jobs()
        .unwrap_or_else(|| {
            thread::available_parallelism()
                .map(usize::from)
                .map(|jobs| jobs.min(DEFAULT_MAX_JOBS))
                .unwrap_or(1)
        })
        .max(1)
}

pub fn map_ordered<T, U, F>(items: &[T], func: F) -> Result<Vec<U>>
where
    T: Sync,
    U: Send,
    F: Fn(&T) -> Result<U> + Sync,
{
    let jobs = job_count();
    if jobs <= 1 || items.len() <= 1 {
        return items.iter().map(func).collect();
    }

    let worker_count = jobs.min(items.len());
    let next_index = AtomicUsize::new(0);
    let (tx, rx) = mpsc::channel();

    thread::scope(|scope| {
        for _ in 0..worker_count {
            let tx = tx.clone();
            let func = &func;
            let next_index = &next_index;
            scope.spawn(move || loop {
                let index = next_index.fetch_add(1, Ordering::Relaxed);
                if index >= items.len() {
                    break;
                }
                if tx.send((index, func(&items[index]))).is_err() {
                    break;
                }
            });
        }
        drop(tx);
    });

    let mut results = (0..items.len()).map(|_| None).collect::<Vec<_>>();
    for (index, result) in rx {
        results[index] = Some(result);
    }

    results
        .into_iter()
        .map(|slot| slot.expect("parallel worker did not return a result"))
        .collect()
}

fn env_jobs() -> Option<usize> {
    ["DECOMPLEX_RUST_JOBS", "DECOMPLEX_JOBS"]
        .into_iter()
        .find_map(|name| env::var(name).ok().and_then(|value| parse_jobs(&value)))
}

fn parse_jobs(value: &str) -> Option<usize> {
    let trimmed = value.trim();
    if trimmed.is_empty() {
        return None;
    }
    trimmed.parse::<usize>().ok().filter(|jobs| *jobs > 0)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parallel_map_preserves_input_order() {
        set_jobs_for_process(Some(4)).expect("jobs");
        let input = vec![3, 2, 1, 0];
        let output = map_ordered(&input, |item| Ok(item * 10)).expect("map");
        assert_eq!(output, vec![30, 20, 10, 0]);
    }

    #[test]
    fn rejects_zero_jobs_override() {
        assert!(set_jobs_for_process(Some(0)).is_err());
    }

    #[test]
    fn test_set_jobs_none() {
        assert!(set_jobs_for_process(None).is_ok());
    }

    #[test]
    fn test_parse_jobs() {
        assert_eq!(parse_jobs(""), None);
        assert_eq!(parse_jobs("   "), None);
        assert_eq!(parse_jobs("abc"), None);
        assert_eq!(parse_jobs("0"), None);
        assert_eq!(parse_jobs("4"), Some(4));
    }

    #[test]
    fn test_env_jobs() {
        std::env::set_var("DECOMPLEX_RUST_JOBS", "5");
        assert_eq!(env_jobs(), Some(5));
        std::env::remove_var("DECOMPLEX_RUST_JOBS");

        std::env::set_var("DECOMPLEX_JOBS", "6");
        assert_eq!(env_jobs(), Some(6));
        std::env::remove_var("DECOMPLEX_JOBS");
    }
}

