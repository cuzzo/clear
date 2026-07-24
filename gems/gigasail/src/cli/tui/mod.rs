//! Terminal UI: state (`app`), rendering (`render`), tree flattening
//! (`tree_view`), and the crossterm event loop (`run`).

pub mod app;
pub mod render;
pub mod tree_view;

use anyhow::Result;
use app::App;
use crossterm::event::{self, Event, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    disable_raw_mode, enable_raw_mode, EnterAlternateScreen, LeaveAlternateScreen,
};
use ratatui::backend::CrosstermBackend;
use ratatui::Terminal;
use std::io;
use std::time::{Duration, Instant};

/// Whether the environment can render UTF-8 glyphs (else ASCII fallback).
pub fn detect_ascii() -> bool {
    let utf8 = ["LC_ALL", "LC_CTYPE", "LANG"].iter().any(|var| {
        std::env::var(var)
            .map(|v| v.to_uppercase().contains("UTF-8") || v.to_uppercase().contains("UTF8"))
            .unwrap_or(false)
    });
    !utf8
}

/// Whether to emit the subtle RGB diff row tints. Genuinely limited terminals
/// (16-color, `linux` console, `dumb`) downsample RGB to a loud bright green, so
/// the tint is dropped there in favor of the `+`/`-` gutter. Everything else —
/// including 256-color terminals and tmux/screen, which clear `COLORTERM` even
/// when truecolor passes through — keeps the tint, since that is how it has
/// always rendered.
pub fn detect_truecolor() -> bool {
    truecolor_from_env(
        std::env::var("COLORTERM").ok().as_deref(),
        std::env::var("TERM").ok().as_deref(),
    )
}

fn truecolor_from_env(colorterm: Option<&str>, term: Option<&str>) -> bool {
    if let Some(ct) = colorterm {
        let ct = ct.to_ascii_lowercase();
        if ct.contains("truecolor") || ct.contains("24bit") {
            return true;
        }
    }
    match term {
        // No TERM at all: assume a capable modern terminal.
        None => true,
        Some(term) => {
            let term = term.to_ascii_lowercase();
            !(term.is_empty()
                || term == "dumb"
                || term == "linux"
                || term.contains("16color")
                || term.contains("mono"))
        }
    }
}

/// Run the interactive review UI until the user quits, returning the final app
/// state (so background-stage durations can be persisted).
pub fn run(mut app: App) -> Result<App> {
    enable_raw_mode()?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen)?;
    let backend = CrosstermBackend::new(stdout);
    let mut terminal = Terminal::new(backend)?;

    let result = event_loop(&mut terminal, &mut app);

    disable_raw_mode()?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen)?;
    terminal.show_cursor()?;
    result.map(|()| app)
}

fn event_loop<B: ratatui::backend::Backend>(
    terminal: &mut Terminal<B>,
    app: &mut App,
) -> Result<()> {
    let start = Instant::now();
    loop {
        let now = start.elapsed().as_secs_f64();
        terminal.draw(|frame| render::render(frame, app, now))?;

        if event::poll(Duration::from_millis(120))? {
            if let Event::Key(key) = event::read()? {
                if key.kind == KeyEventKind::Press {
                    app.handle_key(key);
                }
            }
        }
        if app.should_quit {
            break;
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn detect_ascii_returns_a_bool_without_panic() {
        // Reads the ambient locale; just assert it evaluates cleanly.
        let _ = detect_ascii();
    }

    #[test]
    fn truecolor_keeps_the_tint_for_capable_terminals() {
        // Explicit truecolor.
        assert!(truecolor_from_env(Some("truecolor"), Some("xterm-256color")));
        assert!(truecolor_from_env(Some("24bit"), None));
        // tmux/screen clear COLORTERM but still render the tint.
        assert!(truecolor_from_env(None, Some("tmux-256color")));
        assert!(truecolor_from_env(None, Some("screen-256color")));
        assert!(truecolor_from_env(None, Some("xterm-256color")));
        assert!(truecolor_from_env(None, None));
        // Genuinely limited terminals drop the RGB tint.
        assert!(!truecolor_from_env(None, Some("dumb")));
        assert!(!truecolor_from_env(None, Some("linux")));
        assert!(!truecolor_from_env(None, Some("xterm-16color")));
        assert!(!truecolor_from_env(None, Some("")));
    }
}
