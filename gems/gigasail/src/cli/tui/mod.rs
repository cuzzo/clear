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

/// Whether the terminal advertises 24-bit color. Without it, crossterm's RGB
/// escapes are downsampled by the terminal to the nearest ANSI-16 color, which
/// turns the subtle diff background tints into a loud bright green/red. When
/// false the TUI drops the row tints and relies on the `+`/`-` gutter instead.
pub fn detect_truecolor() -> bool {
    std::env::var("COLORTERM")
        .map(|v| {
            let v = v.to_ascii_lowercase();
            v.contains("truecolor") || v.contains("24bit")
        })
        .unwrap_or(false)
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
}
