//! Public usage dashboard for the OpenCrabs inference provider.
//!
//! The page renders one static JSON snapshot that a timer regenerates every
//! five minutes. It is deliberately dumb: fetch, parse, draw. Everything it
//! shows is already aggregated, and it has no way to ask for anything else.

use leptos::prelude::*;
use serde::Deserialize;

mod charts;
mod chrome;
mod format;

use charts::{CacheLine, HourBars, RequestsBars, TokenBars};
use format::{compact, pct, thousands, uptime};

/// Snapshot schema this build understands. A newer file is refused rather than
/// half-rendered, because a renamed field would otherwise show as a zero.
const SCHEMA: u32 = 1;

/// A snapshot older than this is reported as stale. The timer runs every five
/// minutes, so this tolerates several missed runs before crying wolf.
const STALE_AFTER_MINUTES: i64 = 30;

#[derive(Deserialize, Debug, Clone, Default)]
pub struct Snapshot {
    pub schema: u32,
    pub generated_at: String,
    pub history_since: Option<String>,
    pub totals: Totals,
    pub windows: Windows,
    pub daily: Vec<DailyPoint>,
    pub hourly: Vec<HourlyPoint>,
    pub capabilities: Vec<CapabilityCount>,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct Totals {
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_tokens: u64,
    pub cache_hit_pct: f64,
    pub reasoning_tokens: u64,
    pub median_latency_ms: u64,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct Window {
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_tokens: u64,
    pub cache_hit_pct: f64,
    pub median_latency_ms: u64,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct Windows {
    pub h24: Window,
    pub d7: Window,
    pub d30: Window,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct DailyPoint {
    pub date: String,
    pub requests: u64,
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cached_tokens: u64,
    pub median_latency_ms: u64,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct HourlyPoint {
    pub hour: u32,
    pub requests: u64,
}

#[derive(Deserialize, Debug, Clone, Default)]
pub struct CapabilityCount {
    pub kind: String,
    pub requests: u64,
}

/// Which slice of `daily` the charts show.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Range {
    Day,
    Week,
    Month,
    All,
}

impl Range {
    /// How many trailing daily points this range covers.
    fn days(self, total: usize) -> usize {
        match self {
            Range::Day => 1,
            Range::Week => 7,
            Range::Month => 30,
            Range::All => total,
        }
    }

    fn label(self) -> &'static str {
        match self {
            Range::Day => "24h",
            Range::Week => "7d",
            Range::Month => "30d",
            Range::All => "all",
        }
    }

    fn window<'a>(self, snap: &'a Snapshot) -> &'a Window {
        match self {
            Range::Day => &snap.windows.h24,
            Range::Week => &snap.windows.d7,
            Range::Month | Range::All => &snap.windows.d30,
        }
    }
}

fn main() {
    console_error_panic_hook::set_once();
    leptos::mount::mount_to_body(App);
}

#[component]
fn App() -> impl IntoView {
    let snapshot = LocalResource::new(|| async {
        let resp = gloo_net::http::Request::get("/stats-data/public.json")
            .send()
            .await
            .map_err(|e| format!("could not reach the stats file: {e}"))?;
        if !resp.ok() {
            return Err(format!("the stats file answered {}", resp.status()));
        }
        let snap: Snapshot = resp
            .json()
            .await
            .map_err(|e| format!("the stats file is not valid JSON: {e}"))?;
        if snap.schema != SCHEMA {
            return Err(format!(
                "this page understands schema {SCHEMA}, the file is schema {}",
                snap.schema
            ));
        }
        Ok(snap)
    });

    let range = RwSignal::new(Range::Week);
    let stars = chrome::star_signal();

    view! {
        <chrome::Nav stars=stars />
        <div class="stats-wrap">
            <div class="stats-head">
                <h1><span class="stats-logo">OpenCrabs</span> " provider stats"</h1>
            </div>
            <p class="stats-sub">
                "Live usage of the OpenCrabs inference endpoint. Requests, tokens, cache and latency, "
                "refreshed every five minutes. No routing, upstream or per-caller detail is published."
            </p>
            <Suspense fallback=|| view! { <Loading/> }>
                {move || Suspend::new(async move {
                    match snapshot.await {
                        Ok(snap) => view! { <Dashboard snap=snap range=range/> }.into_any(),
                        Err(e) => view! { <Failure message=e/> }.into_any(),
                    }
                })}
            </Suspense>
        </div>
        <chrome::Footer stars=stars />
    }
}

#[component]
fn Loading() -> impl IntoView {
    view! {
        <div class="stats-state">
            <strong>"Loading the snapshot"</strong>
            "Fetching the latest usage numbers."
        </div>
    }
}

#[component]
fn Failure(message: String) -> impl IntoView {
    view! {
        <div class="stats-state">
            <strong>"The snapshot could not be read"</strong>
            {message}
            <p class="stats-foot">"The page retries on the next reload."</p>
        </div>
    }
}

#[component]
fn Dashboard(snap: Snapshot, range: RwSignal<Range>) -> impl IntoView {
    let age_minutes = format::age_minutes(&snap.generated_at);
    let stale = age_minutes > STALE_AFTER_MINUTES;
    let generated = format::stamp(&snap.generated_at);
    let since = snap
        .history_since
        .clone()
        .unwrap_or_else(|| "no data yet".to_string());
    let totals = snap.totals.clone();
    let snap_for_cards = snap.clone();
    let caps = snap.capabilities.clone();
    let daily = snap.daily.clone();
    let hourly = snap.hourly.clone();

    view! {
        <div class="stats-meta">
            <span class=if stale { "stats-pill stale" } else { "stats-pill live" }>
                {if stale {
                    format!("stale, updated {age_minutes} min ago")
                } else {
                    format!("updated {age_minutes} min ago")
                }}
            </span>
            <span class="stats-pill">{format!("generated {generated} UTC")}</span>
            <span class="stats-pill">{format!("history since {since}")}</span>
        </div>

        {if stale {
            Some(view! {
                <div class="stats-state" style="margin-bottom:26px">
                    <strong>"This snapshot is stale"</strong>
                    "The timer that regenerates it has not run recently, so these numbers are older than "
                    {STALE_AFTER_MINUTES} " minutes."
                </div>
            })
        } else {
            None
        }}

        <div class="stats-cards">
            <Card k="Requests" v=thousands(totals.requests)
                s=format!("{} in the last 24h", thousands(snap_for_cards.windows.h24.requests))/>
            <Card k="Input tokens" v=compact(totals.input_tokens)
                s=format!("{} cached", compact(totals.cached_tokens))/>
            <Card k="Output tokens" v=compact(totals.output_tokens)
                s=format!("{} reasoning", compact(totals.reasoning_tokens))/>
            <Card k="Cache hit" v=pct(totals.cache_hit_pct)
                s=format!("{} in the last 24h", pct(snap_for_cards.windows.h24.cache_hit_pct))/>
            <Card k="Median latency" v=uptime(totals.median_latency_ms)
                s=format!("{} in the last 24h", uptime(snap_for_cards.windows.h24.median_latency_ms))/>
        </div>

        <div class="stats-cards">
            {caps.into_iter().map(|c| {
                let label = match c.kind.as_str() {
                    "chat" => "Chat requests",
                    "image" => "Image requests",
                    "audio" => "Voice requests",
                    _ => "Other requests",
                };
                view! { <Card k=label v=thousands(c.requests) s="lifetime".to_string()/> }
            }).collect_view()}
        </div>

        <RangePicker range=range/>

        {move || {
            let r = range.get();
            let days = r.days(daily.len());
            let start = daily.len().saturating_sub(days);
            let slice = daily[start..].to_vec();
            let w = r.window(&snap).clone();
            let totals_line = format!(
                "{} requests, {} in / {} out, {} cache hit, median {}",
                thousands(w.requests),
                compact(w.input_tokens),
                compact(w.output_tokens),
                pct(w.cache_hit_pct),
                uptime(w.median_latency_ms),
            );
            view! {
                <div class="stats-meta" style="margin-bottom:18px">
                    <span class="stats-pill">{totals_line}</span>
                </div>
                <div class="stats-charts">
                    <section class="stats-chart">
                        <h2>"Requests per day"</h2>
                        <RequestsBars points=slice.clone()/>
                    </section>
                    <section class="stats-chart">
                        <h2>"Tokens per day"</h2>
                        <TokenBars points=slice.clone()/>
                    </section>
                    <section class="stats-chart">
                        <h2>"Cache hit rate per day"</h2>
                        <CacheLine points=slice/>
                    </section>
                    <section class="stats-chart">
                        <h2>"Requests by hour of day (UTC, lifetime)"</h2>
                        <HourBars points=hourly.clone()/>
                    </section>
                </div>
            }
        }}

        <p class="stats-note">
            "Every figure is an aggregate of the last 90 days of proxy records. Providers, upstreams, "
            "callers, keys and failures are never published. Times are UTC."
        </p>
    }
}

#[component]
fn Card(k: &'static str, v: String, s: String) -> impl IntoView {
    view! {
        <div class="stats-card">
            <div class="k">{k}</div>
            <div class="v">{v}</div>
            <div class="s">{s}</div>
        </div>
    }
}

#[component]
fn RangePicker(range: RwSignal<Range>) -> impl IntoView {
    let options = [Range::Day, Range::Week, Range::Month, Range::All];
    view! {
        <div class="stats-ranges">
            {options.into_iter().map(|r| view! {
                <button
                    class=move || if range.get() == r { "on" } else { "" }
                    on:click=move |_| range.set(r)
                >{r.label()}</button>
            }).collect_view()}
        </div>
    }
}
