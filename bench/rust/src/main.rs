//! The Rust arm of `just bench-compare` (bench/README.md): scraper, which is
//! html5ever building an ego-tree DOM, parsing each corpus document from
//! memory into its tree.
//!
//! Usage, from the repository root:
//!
//!     parse-rust [--count N]   benchmark rows in the Go benchmark format
//!     parse-rust check         node counts per document, and one parse's allocations
//!
//! A row times `String::from_utf8_lossy` (scraper takes `&str`, and the
//! other arms take bytes) and `Html::parse_document`, and drops the tree,
//! in a loop sized the way Go's `testing.B` sizes one: about a second.

use std::alloc::{GlobalAlloc, Layout, System};
use std::hint::black_box;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering::Relaxed};
use std::time::{Duration, Instant};

use scraper::{Html, Node};

const CORPUS: &str = "bench/corpus-gen";

/// Counts allocations only while `check` asks it to. Outside that, each
/// allocation pays one relaxed load.
struct Counting;

static COUNTING: AtomicBool = AtomicBool::new(false);
static ALLOCS: AtomicU64 = AtomicU64::new(0);
static BYTES: AtomicU64 = AtomicU64::new(0);

unsafe impl GlobalAlloc for Counting {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        if COUNTING.load(Relaxed) {
            ALLOCS.fetch_add(1, Relaxed);
            BYTES.fetch_add(layout.size() as u64, Relaxed);
        }
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        if COUNTING.load(Relaxed) {
            ALLOCS.fetch_add(1, Relaxed);
            BYTES.fetch_add(new_size as u64, Relaxed);
        }
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}

#[global_allocator]
static GLOBAL: Counting = Counting;

struct Document {
    name: String,
    data: Vec<u8>,
}

fn load() -> Vec<Document> {
    let entries = std::fs::read_dir(CORPUS)
        .unwrap_or_else(|e| fail(&format!("read {CORPUS}: {e} (run `just bench-corpus`)")));
    let mut docs: Vec<Document> = entries
        .map(|entry| entry.unwrap().path())
        .filter(|path| path.extension().is_some_and(|ext| ext == "html"))
        .map(|path| Document {
            name: path.file_stem().unwrap().to_string_lossy().into_owned(),
            data: std::fs::read(&path).unwrap(),
        })
        .collect();
    docs.sort_by(|a, b| a.name.cmp(&b.name));
    docs
}

fn fail(message: &str) -> ! {
    eprintln!("parse-rust: {message}");
    std::process::exit(1);
}

fn parse(data: &[u8]) -> Html {
    Html::parse_document(&String::from_utf8_lossy(data))
}

fn run(data: &[u8], n: u64) -> Duration {
    let start = Instant::now();
    for _ in 0..n {
        black_box(parse(black_box(data)));
    }
    start.elapsed()
}

/// Go's `testing.B` loop sizing: grow `n` until a run takes a second.
fn bench(data: &[u8]) -> (u64, Duration) {
    let goal = Duration::from_secs(1);
    let mut n: u64 = 1;
    let mut elapsed = run(data, n);
    while elapsed < goal && n < 1_000_000_000 {
        let last = n;
        let prev_ns = elapsed.as_nanos().max(1);
        let mut next = (goal.as_nanos() * last as u128 / prev_ns) as u64;
        next += next / 5;
        n = next.min(100 * last).max(last + 1).min(1_000_000_000);
        elapsed = run(data, n);
    }
    (n, elapsed)
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let docs = load();
    if args.get(1).is_some_and(|a| a == "check") {
        return check(&docs);
    }
    let count: u32 = match args.iter().position(|a| a == "--count") {
        Some(i) => args.get(i + 1).and_then(|v| v.parse().ok()).unwrap_or_else(|| fail("--count needs a number")),
        None => 1,
    };
    for _ in 0..count {
        for doc in &docs {
            let (n, elapsed) = bench(&doc.data);
            let ns_per_op = elapsed.as_nanos() as f64 / n as f64;
            let mb_per_s = doc.data.len() as f64 * n as f64 / 1e6 / elapsed.as_secs_f64();
            println!("BenchmarkParse/{}\t{n}\t{ns_per_op:.0} ns/op\t{mb_per_s:.2} MB/s", doc.name);
        }
    }
}

#[derive(Default)]
struct Counts {
    elements: usize,
    attributes: usize,
    texts: usize,
    text_bytes: usize,
    comments: usize,
}

fn check(docs: &[Document]) {
    for doc in docs {
        ALLOCS.store(0, Relaxed);
        BYTES.store(0, Relaxed);
        COUNTING.store(true, Relaxed);
        let html = parse(&doc.data);
        COUNTING.store(false, Relaxed);
        let mut c = Counts::default();
        // The root's descendants, which in scraper include template contents.
        for node in html.tree.root().descendants().skip(1) {
            match node.value() {
                Node::Element(e) => {
                    c.elements += 1;
                    c.attributes += e.attrs().count();
                }
                Node::Text(t) => {
                    c.texts += 1;
                    c.text_bytes += t.len();
                }
                Node::Comment(_) => c.comments += 1,
                _ => {}
            }
        }
        println!(
            "{} elements={} attributes={} texts={} text_bytes={} comments={}\tallocs={} bytes={}",
            doc.name,
            c.elements,
            c.attributes,
            c.texts,
            c.text_bytes,
            c.comments,
            ALLOCS.load(Relaxed),
            BYTES.load(Relaxed)
        );
    }
}
