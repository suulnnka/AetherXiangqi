// NNUE trainer for AetherXiangqi — standalone port of AetherChess3's
// trainer2.rs (minifish/bullet recipe):
//   * SigmoidMPE(2.6) loss, engine-faithful sigmoid (z = dot + c/400)
//   * score-fit defaults (WDL 0 -> 0): target = sigmoid(score/400)
//   * AdamW (decoupled decay 0.01) with hard weight clip ±1.98
//   * linear LR decay to 0, batch 16384, no warmup
//   * v4 i8 export: FT int8 @ QA=101 + lossless exception list, out i16 @
//     QV=160 — byte-compatible with the engine's nnue.zig parser
//
// Xiangqi deltas vs trainer2:
//   * INPUTS = 2*7*90 = 1260 (color x type x square, no king feature)
//   * perspective rotation sq -> 89-sq (180° on the 9x10 board)
//   * data = .aex2 (96 B/record): board[90] mailbox bytes (color*7+type,
//     0xFF empty), stm@90, score i16@92 (engine units, STM POV), result@94
//   * material bucket from the mailbox piece count (2..32 -> 0..7)
//   * no mirror arch (M0 only)
//
// Usage:
//   cargo run --release -- trainer --data <dir-or-files> --out aetherx.nnue
//            [--epochs 16] [--lr 0.0015] [--batch 16384] [--score-scale 0.4565]
//            [--ckpt path] [--probe-data file.aex2] [--requant aetherx.nnue]
use std::io::{BufRead, BufReader, Read, Write};

const HIDDEN: usize = 64;
const INPUTS: usize = 2 * 7 * 90;
const BUCKETS: usize = 8;
const REC: usize = 96;
const POW: f32 = 2.6;

const NET_VERSION_I8: u32 = 4;
const QA_I8: i32 = 101;
const QV_I8: i32 = 160;
const SCALE: i32 = 400;

type Board = [u8; 90];

struct Sample {
    feats: [[u16; 33]; 2],
    side: u8,
    score: f32, // net-cp (rescaled), stm POV
    result: f32,
    bucket: u8,
}

/// Feature index: own pieces in the low half, enemy in the high half; the
/// non-stm perspective sees the board rotated 180° (sq -> 89-sq).
#[inline]
fn feat(persp: usize, color: usize, ty: usize, sq: usize) -> usize {
    let rel = (color != persp) as usize;
    let sq2 = if persp == 0 { sq } else { 89 - sq };
    (rel * 7 + ty) * 90 + sq2
}

fn load_file(path: &str, out: &mut Vec<Sample>, score_scale: f32) {
    let n = (std::fs::metadata(path).expect("data path").len() as usize) / REC;
    out.reserve(n);
    let mut f = BufReader::with_capacity(1 << 22, std::fs::File::open(path).expect("open data"));
    let mut rec = [0u8; REC];
    let mut skipped = 0usize;
    let mut i = 0usize;
    while f.read_exact(&mut rec).is_ok() {
        let board: Board = rec[0..90].try_into().unwrap();
        let score_raw = i16::from_le_bytes(rec[92..94].try_into().unwrap());
        if score_raw <= -30000 {
            skipped += 1;
            i += 1;
            continue;
        }
        let result = match rec[94] {
            0 => 0.0f32,
            1 => 0.5,
            _ => 1.0,
        };
        let mut feats = [[0u16; 33]; 2];
        let mut n_all = 0usize;
        for sq in 0..90usize {
            let id = board[sq];
            if id == 0xFF {
                continue;
            }
            n_all += 1;
            let color = (id / 7) as usize;
            let ty = (id % 7) as usize;
            for persp in 0..2usize {
                let cnt = feats[persp][32] as usize;
                feats[persp][cnt] = feat(persp, color, ty, sq) as u16;
                feats[persp][32] = cnt as u16 + 1;
            }
        }
        let bucket = (n_all.saturating_sub(2) * (BUCKETS - 1) / 30).min(BUCKETS - 1);
        out.push(Sample {
            feats,
            side: rec[90],
            score: score_raw as f32 * score_scale,
            result,
            bucket: bucket as u8,
        });
        i += 1;
    }
    eprintln!(
        "loaded {} records from {} (skipped {}, total {})",
        i,
        path,
        skipped,
        out.len()
    );
}

struct Rng(u64);
impl Rng {
    fn next_f32(&mut self) -> f32 {
        let mut x = self.0;
        x ^= x >> 12;
        x ^= x << 25;
        x ^= x >> 27;
        self.0 = x;
        ((x.wrapping_mul(0x2545F4914F6CDD1D) >> 40) as f32) / (1u64 << 24) as f32
    }
    fn below(&mut self, n: usize) -> usize {
        (self.next_f32() * n as f32) as usize % n.max(1)
    }
}

#[derive(Clone)]
struct Master {
    w: Vec<f32>, // INPUTS x HIDDEN, feature-major
    b: [f32; HIDDEN],
    v: Vec<[f32; HIDDEN * 2]>,
    c: [f32; BUCKETS],
}

fn init_master(seed: u64) -> Master {
    let mut rng = Rng(seed);
    let s1 = (2.0 / INPUTS as f32).sqrt() * 1.4;
    let s2 = (2.0 / (HIDDEN * 2) as f32).sqrt() * 1.4;
    let mut m = Master {
        w: vec![0.0; INPUTS * HIDDEN],
        b: [0.0; HIDDEN],
        v: vec![[0.0; HIDDEN * 2]; BUCKETS],
        c: [0.0; BUCKETS],
    };
    for x in m.w.iter_mut() {
        *x = (rng.next_f32() * 2.0 - 1.0) * s1;
    }
    for bkt in m.v.iter_mut() {
        for x in bkt.iter_mut() {
            *x = (rng.next_f32() * 2.0 - 1.0) * s2;
        }
    }
    m
}

// ---- f32 checkpoint ("AECK") -------------------------------------------
fn ckpt_bytes() -> usize {
    16 + (INPUTS * HIDDEN + HIDDEN + BUCKETS * HIDDEN * 2 + BUCKETS) * 4
}

fn write_ckpt(m: &Master, path: &str, epochs_trained: u32, val_loss: f32) {
    let mut bytes = Vec::with_capacity(ckpt_bytes());
    bytes.extend_from_slice(b"AECK");
    bytes.extend_from_slice(&1u32.to_le_bytes());
    bytes.extend_from_slice(&epochs_trained.to_le_bytes());
    bytes.extend_from_slice(&val_loss.to_le_bytes());
    for &x in &m.w {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for &x in m.b.iter() {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for bk in 0..BUCKETS {
        for k in 0..HIDDEN * 2 {
            bytes.extend_from_slice(&m.v[bk][k].to_le_bytes());
        }
    }
    for bk in 0..BUCKETS {
        bytes.extend_from_slice(&m.c[bk].to_le_bytes());
    }
    std::fs::write(path, &bytes).expect("write ckpt");
    eprintln!("f32 checkpoint written to {} ({} bytes)", path, bytes.len());
}

fn load_master(path: &str) -> Master {
    let bytes = std::fs::read(path).expect("read net/checkpoint");
    if bytes.len() >= 4 && bytes[0..4] == *b"AECK" {
        assert_eq!(bytes.len(), ckpt_bytes(), "checkpoint size mismatch");
        let rd_f32 = |o: usize| f32::from_le_bytes(bytes[o..o + 4].try_into().unwrap());
        let mut off = 16;
        let mut m = Master {
            w: vec![0.0; INPUTS * HIDDEN],
            b: [0.0; HIDDEN],
            v: vec![[0.0; HIDDEN * 2]; BUCKETS],
            c: [0.0; BUCKETS],
        };
        for x in m.w.iter_mut() {
            *x = rd_f32(off);
            off += 4;
        }
        for x in m.b.iter_mut() {
            *x = rd_f32(off);
            off += 4;
        }
        for bk in 0..BUCKETS {
            for k in 0..HIDDEN * 2 {
                m.v[bk][k] = rd_f32(off);
                off += 4;
            }
        }
        for bk in 0..BUCKETS {
            m.c[bk] = rd_f32(off);
            off += 4;
        }
        return m;
    }
    // quantized v4 net -> f32 master
    let net = parse_v4(&bytes).expect("parse v4 net");
    Master {
        w: net.ft_w.iter().map(|&x| x as f32 / QA_I8 as f32).collect(),
        b: std::array::from_fn(|k| net.ft_b[k] as f32 / QA_I8 as f32),
        v: net
            .out_w
            .iter()
            .map(|row| row.map(|x| x as f32 / QV_I8 as f32))
            .collect(),
        c: std::array::from_fn(|bk| net.out_b[bk] as f32 * SCALE as f32 / (QA_I8 * QV_I8) as f32),
    }
}

struct Net {
    ft_w: Vec<i16>,
    ft_b: [i16; HIDDEN],
    out_w: [[i16; HIDDEN * 2]; BUCKETS],
    out_b: [i16; BUCKETS],
}

fn parse_v4(b: &[u8]) -> Option<Net> {
    let rd_u32 = |o: usize| -> Option<u32> {
        Some(u32::from_le_bytes(b.get(o..o + 4)?.try_into().ok()?))
    };
    if b.len() < 24 || rd_u32(0)? != 0x4E4E4541 || rd_u32(4)? != NET_VERSION_I8 {
        return None;
    }
    let n_exc = rd_u32(20)? as usize;
    let mut off = 24 + n_exc * 6;
    let mut net = Net {
        ft_w: vec![0; INPUTS * HIDDEN],
        ft_b: [0; HIDDEN],
        out_w: [[0; HIDDEN * 2]; BUCKETS],
        out_b: [0; BUCKETS],
    };
    for x in net.ft_w.iter_mut() {
        *x = *b.get(off)? as i8 as i16;
        off += 1;
    }
    for x in net.ft_b.iter_mut() {
        *x = *b.get(off)? as i8 as i16;
        off += 1;
    }
    for row in net.out_w.iter_mut() {
        for x in row.iter_mut() {
            *x = i16::from_le_bytes(b.get(off..off + 2)?.try_into().ok()?);
            off += 2;
        }
    }
    for x in net.out_b.iter_mut() {
        *x = i16::from_le_bytes(b.get(off..off + 2)?.try_into().ok()?);
        off += 2;
    }
    // exception overlay
    let mut eo = 24;
    for _ in 0..n_exc {
        let idx = rd_u32(eo)? as usize;
        let val = i16::from_le_bytes(b.get(eo + 4..eo + 6)?.try_into().ok()?);
        if idx < INPUTS * HIDDEN {
            net.ft_w[idx] = val;
        } else if idx < INPUTS * HIDDEN + HIDDEN {
            net.ft_b[idx - INPUTS * HIDDEN] = val;
        }
        eo += 6;
    }
    Some(net)
}

struct BatchGrads {
    gw: Vec<f32>,
    gb: [f32; HIDDEN],
    gv: Vec<f32>,
    gc: [f32; BUCKETS],
}

impl BatchGrads {
    fn new() -> Self {
        BatchGrads {
            gw: vec![0f32; INPUTS * HIDDEN],
            gb: [0f32; HIDDEN],
            gv: vec![0f32; BUCKETS * HIDDEN * 2],
            gc: [0f32; BUCKETS],
        }
    }
}

// Forward + backward for one sample (SigmoidMPE gradient; see trainer2.rs).
fn forward_sample(
    s: &Sample,
    wdl: f32,
    m: &Master,
    g: &mut BatchGrads,
    loss_acc: &mut f64,
    probe: Option<(&mut Vec<f32>, &mut Vec<f32>)>,
) {
    let mut acc = [[0.0f32; HIDDEN]; 2];
    for persp in 0..2 {
        let cnt = s.feats[persp][32] as usize;
        for k in 0..cnt {
            let f = s.feats[persp][k] as usize;
            let row = &m.w[f * HIDDEN..(f + 1) * HIDDEN];
            let a = &mut acc[persp];
            for i in 0..HIDDEN {
                a[i] += row[i];
            }
        }
        for i in 0..HIDDEN {
            acc[persp][i] += m.b[i];
        }
    }
    let bk = s.bucket as usize;
    let (pa, pb) = (s.side as usize, 1 - s.side as usize);
    let mut act = [0.0f32; HIDDEN * 2];
    for i in 0..HIDDEN {
        let x0 = acc[pa][i].clamp(0.0, 1.0);
        let x1 = acc[pb][i].clamp(0.0, 1.0);
        act[i] = x0 * x0;
        act[HIDDEN + i] = x1 * x1;
    }
    let mut dot = 0f32;
    for i in 0..HIDDEN * 2 {
        dot += m.v[bk][i] * act[i];
    }
    let c = m.c[bk];
    let z = dot + c / SCALE as f32;
    let pr = 1.0 / (1.0 + (-z).exp());
    let target =
        (1.0 - wdl) * (1.0 / (1.0 + (-(s.score / SCALE as f32)).exp())) + wdl * s.result;
    let err = pr - target;
    *loss_acc += (err.abs() as f64).powf(POW as f64);
    if let Some((preds, labels)) = probe {
        preds.push(SCALE as f32 * dot + c);
        labels.push(s.score);
    }
    let sgn = if err > 0.0 { 1.0 } else if err < 0.0 { -1.0 } else { 0.0 };
    let dz = POW * err.abs().powf(POW - 1.0) * sgn * pr * (1.0 - pr);
    for i in 0..HIDDEN * 2 {
        g.gv[bk * HIDDEN * 2 + i] += dz * act[i];
    }
    g.gc[bk] += dz / SCALE as f32;
    let dacc_off = |persp: usize| if persp == pa { 0 } else { HIDDEN };
    for persp in 0..2 {
        let cnt = s.feats[persp][32] as usize;
        let mut daccp = [0.0f32; HIDDEN];
        let off = dacc_off(persp);
        for i in 0..HIDDEN {
            let x = acc[persp][i];
            if x > 0.0 && x < 1.0 {
                daccp[i] = 2.0 * x * dz * m.v[bk][off + i];
            }
        }
        for k in 0..cnt {
            let f = s.feats[persp][k] as usize;
            let gr = &mut g.gw[f * HIDDEN..(f + 1) * HIDDEN];
            for i in 0..HIDDEN {
                gr[i] += daccp[i];
            }
        }
        for i in 0..HIDDEN {
            g.gb[i] += daccp[i];
        }
    }
}

fn spearman(preds: &[f32], labels: &[f32]) -> f64 {
    fn ranks(x: &[f32]) -> Vec<f64> {
        let mut idx: Vec<usize> = (0..x.len()).collect();
        idx.sort_by(|&a, &b| x[a].partial_cmp(&x[b]).unwrap());
        let mut r = vec![0f64; x.len()];
        let mut i = 0usize;
        while i < idx.len() {
            let mut j = i;
            while j + 1 < idx.len() && x[idx[j + 1]] == x[idx[i]] {
                j += 1;
            }
            let avg = (i + j) as f64 / 2.0 + 1.0;
            for k in i..=j {
                r[idx[k]] = avg;
            }
            i = j + 1;
        }
        r
    }
    let (rp, rl) = (ranks(preds), ranks(labels));
    let n = rp.len() as f64;
    let (mp, ml) = (rp.iter().sum::<f64>() / n, rl.iter().sum::<f64>() / n);
    let mut num = 0f64;
    let (mut dp, mut dl) = (0f64, 0f64);
    for k in 0..rp.len() {
        let a = rp[k] - mp;
        let b = rl[k] - ml;
        num += a * b;
        dp += a * a;
        dl += b * b;
    }
    num / (dp.sqrt() * dl.sqrt()).max(1e-12)
}

fn forward_cp(s: &Sample, m: &Master) -> f32 {
    let mut acc = [[0.0f32; HIDDEN]; 2];
    for persp in 0..2 {
        let cnt = s.feats[persp][32] as usize;
        for k in 0..cnt {
            let f = s.feats[persp][k] as usize;
            let row = &m.w[f * HIDDEN..(f + 1) * HIDDEN];
            let a = &mut acc[persp];
            for i in 0..HIDDEN {
                a[i] += row[i];
            }
        }
        for i in 0..HIDDEN {
            acc[persp][i] += m.b[i];
        }
    }
    let bk = s.bucket as usize;
    let (pa, pb) = (s.side as usize, 1 - s.side as usize);
    let mut dot = 0f32;
    for i in 0..HIDDEN {
        let x0 = acc[pa][i].clamp(0.0, 1.0);
        let x1 = acc[pb][i].clamp(0.0, 1.0);
        dot += m.v[bk][i] * (x0 * x0) + m.v[bk][HIDDEN + i] * (x1 * x1);
    }
    SCALE as f32 * dot + m.c[bk]
}

fn probe_master(m: &Master, data_path: &str, score_scale: f32) {
    let mut samples = Vec::new();
    load_file(data_path, &mut samples, score_scale);
    let n = samples.len();
    let mut preds = Vec::with_capacity(n);
    let mut labels = Vec::with_capacity(n);
    for s in &samples {
        preds.push(forward_cp(s, m));
        labels.push(s.score);
    }
    let mae = preds
        .iter()
        .zip(labels.iter())
        .map(|(p, l)| (p - l).abs() as f64)
        .sum::<f64>()
        / n.max(1) as f64;
    let mp = preds.iter().sum::<f32>() / n.max(1) as f32;
    let ml = labels.iter().sum::<f32>() / n.max(1) as f32;
    let (mut cov, mut vp, mut vl) = (0f64, 0f64, 0f64);
    for (p, l) in preds.iter().zip(labels.iter()) {
        cov += ((p - mp) * (l - ml)) as f64;
        vp += ((p - mp) * (p - mp)) as f64;
        vl += ((l - ml) * (l - ml)) as f64;
    }
    eprintln!(
        "f32 probe: {} records  spearman {:.4}  pearson {:.4}  mae {:.0} cp  (label scale {})",
        n,
        spearman(&preds, &labels),
        cov / (vp.sqrt() * vl.sqrt()).max(1e-12),
        mae,
        score_scale
    );
}

fn eval_val(val: &[Sample], wdl: f32, master: &Master, probe_n: usize) -> (f64, f64) {
    let vn = val.len().min(probe_n);
    let mut preds = Vec::with_capacity(vn);
    let mut labels = Vec::with_capacity(vn);
    let mut g = BatchGrads::new();
    let mut vloss = 0f64;
    for s in val.iter().take(vn) {
        forward_sample(s, wdl, master, &mut g, &mut vloss, Some((&mut preds, &mut labels)));
    }
    (vloss / vn.max(1) as f64, spearman(&preds, &labels))
}

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let mut data_paths: Vec<String> = Vec::new();
    let mut out_path = String::from("aetherx.nnue");
    let mut epochs = 16usize;
    let mut lr = 0.0015f32;
    let mut batch = 16384usize;
    let mut val_frac = 0.01f32;
    let mut probe_n = 32768usize;
    let mut seed = 7u64;
    let mut resume = String::new();
    let mut wd = 0.01f32;
    let mut maxw = 1.98f32;
    let mut score_scale = 1.0f32;
    let mut wdl_start = 0.0f32;
    let mut wdl_end = 0.0f32;
    let mut keep_last = false;
    let mut ckpt = String::new();
    let mut probe_data = String::new();
    let mut requant = String::new();
    let mut beta1 = 0.9f32;
    let mut i = 1;
    while i + 1 < args.len() {
        match args[i].as_str() {
            "--data" => data_paths.push(args[i + 1].clone()),
            "--out" => out_path = args[i + 1].clone(),
            "--epochs" => epochs = args[i + 1].parse().unwrap_or(epochs),
            "--lr" => lr = args[i + 1].parse().unwrap_or(lr),
            "--batch" => batch = args[i + 1].parse().unwrap_or(batch),
            "--val-frac" => val_frac = args[i + 1].parse().unwrap_or(val_frac),
            "--probe" => probe_n = args[i + 1].parse().unwrap_or(probe_n),
            "--seed" => seed = args[i + 1].parse().unwrap_or(seed),
            "--resume" => resume = args[i + 1].clone(),
            "--wd" => wd = args[i + 1].parse().unwrap_or(wd),
            "--maxw" => maxw = args[i + 1].parse().unwrap_or(maxw),
            "--score-scale" => score_scale = args[i + 1].parse().unwrap_or(score_scale),
            "--wdl-start" => wdl_start = args[i + 1].parse().unwrap_or(wdl_start),
            "--wdl-end" => wdl_end = args[i + 1].parse().unwrap_or(wdl_end),
            "--keep-last" => keep_last = true,
            "--ckpt" => ckpt = args[i + 1].clone(),
            "--probe-data" => probe_data = args[i + 1].clone(),
            "--requant" => requant = args[i + 1].clone(),
            "--beta1" => beta1 = args[i + 1].parse().unwrap_or(beta1),
            _ => {}
        }
        i += 2;
    }
    if !requant.is_empty() {
        let master = load_master(&requant);
        if !probe_data.is_empty() {
            probe_master(&master, &probe_data, score_scale);
            return;
        }
        write_net(&master, &out_path);
        return;
    }
    if data_paths.is_empty() {
        eprintln!("trainer: no --data given");
        std::process::exit(1);
    }
    eprintln!("xiangqi trainer: seed {} beta1 {}", seed, beta1);

    let shard_mode = data_paths.len() == 1 && std::path::Path::new(&data_paths[0]).is_dir();

    let t0 = std::time::Instant::now();
    let mut rng = Rng(seed.wrapping_mul(7919));
    let mut master = if resume.is_empty() { init_master(seed) } else { load_master(&resume) };
    let n_w = INPUTS * HIDDEN;
    let n_v = BUCKETS * HIDDEN * 2;
    let mut am = [vec![0f32; n_w], vec![0f32; HIDDEN], vec![0f32; n_v], vec![0f32; BUCKETS]];
    let mut av = [vec![0f32; n_w], vec![0f32; HIDDEN], vec![0f32; n_v], vec![0f32; BUCKETS]];
    let mut step = 0usize;
    let mut best_val = f64::MAX;
    let mut best = master.clone();

    macro_rules! adamw_step {
        ($g:expr, $inv:expr, $cur_lr:expr) => {{
            let bc1 = 1.0 - beta1.powi(step as i32);
            let bc2 = 1.0 - 0.999f32.powi(step as i32);
            let upd = |p: &mut f32,
                       gr: f32,
                       m: &mut f32,
                       v: &mut f32,
                       lr: f32,
                       wd: f32,
                       bc1: f32,
                       bc2: f32| {
                *m = beta1 * *m + (1.0 - beta1) * gr;
                *v = 0.999 * *v + 0.001 * gr * gr;
                *p -= lr * ((*m / bc1) / ((*v / bc2).sqrt() + 1e-8) + wd * *p);
            };
            let inv: f32 = $inv;
            let cur_lr: f32 = $cur_lr;
            for k in 0..n_w {
                upd(&mut master.w[k], $g.gw[k] * inv, &mut am[0][k], &mut av[0][k], cur_lr, wd, bc1, bc2);
            }
            for k in 0..HIDDEN {
                upd(&mut master.b[k], $g.gb[k] * inv, &mut am[1][k], &mut av[1][k], cur_lr, wd, bc1, bc2);
            }
            for bk in 0..BUCKETS {
                for k in 0..HIDDEN * 2 {
                    upd(
                        &mut master.v[bk][k],
                        $g.gv[bk * HIDDEN * 2 + k] * inv,
                        &mut am[2][bk * HIDDEN * 2 + k],
                        &mut av[2][bk * HIDDEN * 2 + k],
                        cur_lr,
                        wd,
                        bc1,
                        bc2,
                    );
                }
            }
            for k in 0..BUCKETS {
                upd(&mut master.c[k], $g.gc[k] * inv, &mut am[3][k], &mut av[3][k], cur_lr, wd, bc1, bc2);
            }
            for x in master.w.iter_mut() {
                *x = x.clamp(-maxw, maxw);
            }
            for x in master.b.iter_mut() {
                *x = x.clamp(-maxw, maxw);
            }
            for bkt in master.v.iter_mut() {
                for x in bkt.iter_mut() {
                    *x = x.clamp(-maxw, maxw);
                }
            }
            for x in master.c.iter_mut() {
                *x = x.clamp(-maxw, maxw);
            }
        }};
    }

    let mut total_steps = 1usize;
    if shard_mode {
        let mut shard_paths: Vec<String> = std::fs::read_dir(&data_paths[0])
            .expect("read shard dir")
            .filter_map(|e| {
                let p = e.ok()?.path();
                (p.extension()?.to_str()? == "aex2").then(|| p.to_string_lossy().into_owned())
            })
            .collect();
        shard_paths.sort();
        assert!(!shard_paths.is_empty(), "no .aex2 shards in {}", data_paths[0]);
        let est: Vec<usize> = shard_paths
            .iter()
            .map(|p| (std::fs::metadata(p).expect("shard size").len() as usize) / REC)
            .collect();
        let mut known: Vec<Option<usize>> = vec![None; shard_paths.len()];
        let mut skip_rate = 0.0f32;
        total_steps = est.iter().map(|&e| e.div_ceil(batch)).sum::<usize>() * epochs;
        eprintln!(
            "shard mode: {} shards, ~{} records total (est), {} passes",
            shard_paths.len(),
            est.iter().sum::<usize>(),
            epochs
        );
        for epoch in 0..epochs {
            let wdl = if epochs > 1 {
                wdl_start + (wdl_end - wdl_start) * (epoch as f32 / (epochs - 1) as f32)
            } else {
                wdl_end
            };
            let mut sorder: Vec<usize> = (0..shard_paths.len()).collect();
            for i in (1..sorder.len()).rev() {
                let j = rng.below(i + 1);
                sorder.swap(i, j);
            }
            for (sh_i, &si) in sorder.iter().enumerate() {
                let t_sh = std::time::Instant::now();
                let mut all: Vec<Sample> = Vec::new();
                load_file(&shard_paths[si], &mut all, score_scale);
                let n_rec = (std::fs::metadata(&shard_paths[si]).unwrap().len() as usize) / REC;
                if n_rec > 0 {
                    skip_rate = (n_rec - all.len()) as f32 / n_rec as f32;
                }
                known[si] = Some(all.len());
                let steps_per_pass: usize = known
                    .iter()
                    .zip(est.iter())
                    .map(|(k, &e)| {
                        let n = k.unwrap_or((e as f32 * (1.0 - skip_rate)) as usize);
                        n.div_ceil(batch)
                    })
                    .sum();
                total_steps = steps_per_pass * epochs;
                for i in (1..all.len()).rev() {
                    let j = rng.below(i + 1);
                    all.swap(i, j);
                }
                let n_val = (all.len() as f32 * val_frac) as usize;
                let (train, val) = all.split_at(all.len() - n_val);
                let mut loss_sum = 0f64;
                let mut loss_n = 0usize;
                for chunk in train.chunks(batch) {
                    let prog = step as f32 / total_steps as f32;
                    let cur_lr = lr * (1.0 - prog);
                    let mut g = BatchGrads::new();
                    let mut l2 = 0f64;
                    for s in chunk {
                        forward_sample(s, wdl, &master, &mut g, &mut l2, None);
                    }
                    loss_sum += l2;
                    loss_n += chunk.len();
                    let inv = 1.0 / chunk.len() as f32;
                    step += 1;
                    adamw_step!(g, inv, cur_lr);
                }
                let (vloss, sp) = eval_val(val, wdl, &master, probe_n);
                if vloss < best_val {
                    best_val = vloss;
                    best = master.clone();
                }
                eprintln!(
                    "epoch {} shard {}/{} loss {:.6} val {:.6} sp {:.4} lr {:.6} {} ({:.1}s load+train, total {:.1}m)",
                    epoch,
                    sh_i + 1,
                    shard_paths.len(),
                    loss_sum / loss_n.max(1) as f64,
                    vloss,
                    sp,
                    lr * (1.0 - step as f32 / total_steps as f32),
                    shard_paths[si].rsplit('/').next().unwrap_or(""),
                    t_sh.elapsed().as_secs_f64(),
                    t0.elapsed().as_secs_f64() / 60.0
                );
            }
        }
    } else {
        let mut all: Vec<Sample> = Vec::new();
        for p in &data_paths {
            load_file(p, &mut all, score_scale);
        }
        eprintln!("dataset: {} samples in {:.1}s", all.len(), t0.elapsed().as_secs_f64());
        for i in (1..all.len()).rev() {
            let j = rng.below(i + 1);
            all.swap(i, j);
        }
        let n_val = (all.len() as f32 * val_frac) as usize;
        let (train, val) = all.split_at(all.len() - n_val);
        eprintln!("train {} val {}", train.len(), val.len());
        total_steps = (train.len() / batch + 1) * epochs;
        for epoch in 0..epochs {
            let wdl = if epochs > 1 {
                wdl_start + (wdl_end - wdl_start) * (epoch as f32 / (epochs - 1) as f32)
            } else {
                wdl_end
            };
            let mut order: Vec<usize> = (0..train.len()).collect();
            for i in (1..order.len()).rev() {
                let j = rng.below(i + 1);
                order.swap(i, j);
            }
            let mut loss_sum = 0f64;
            let mut loss_n = 0usize;
            let t_ep = std::time::Instant::now();
            for chunk in order.chunks(batch) {
                let prog = step as f32 / total_steps as f32;
                let cur_lr = lr * (1.0 - prog);
                let mut g = BatchGrads::new();
                let mut l2 = 0f64;
                for &si in chunk {
                    forward_sample(&train[si], wdl, &master, &mut g, &mut l2, None);
                }
                loss_sum += l2;
                loss_n += chunk.len();
                if std::env::var("TRACE").is_ok() && loss_n % (batch * 25) == 0 {
                    let (vl, sp) = eval_val(val, wdl, &master, 8192);
                    eprintln!(
                        "  step {} loss {:.6} val {:.6} sp {:.4}",
                        step,
                        l2 / chunk.len() as f64,
                        vl,
                        sp
                    );
                }
                let inv = 1.0 / chunk.len() as f32;
                step += 1;
                adamw_step!(g, inv, cur_lr);
            }
            let (vloss, sp) = eval_val(val, wdl, &master, probe_n);
            let max_w = master.w.iter().fold(0f32, |a, &x| a.max(x.abs()));
            eprintln!(
                "epoch {} wdl {:.3} loss {:.6} val {:.6} spearman {:.4} max|w| {:.3} lr {:.6} {:.1}s",
                epoch,
                wdl,
                loss_sum / loss_n.max(1) as f64,
                vloss,
                sp,
                max_w,
                lr * (1.0 - step as f32 / total_steps as f32),
                t_ep.elapsed().as_secs_f64()
            );
            if vloss < best_val {
                best_val = vloss;
                best = master.clone();
            }
        }
    }
    if keep_last {
        best = master;
    }
    master = best;
    eprintln!("best val {:.6}", best_val);
    if !ckpt.is_empty() {
        write_ckpt(&master, &ckpt, epochs as u32, best_val as f32);
    }
    write_net(&master, &out_path);
}

// v4 i8 quantized export (byte-compatible with the engine's parseV4).
fn write_net(master: &Master, out_path: &str) {
    let q8 = |x: f32| (x * QA_I8 as f32).round() as i32;
    let mut qw = Vec::with_capacity(INPUTS * HIDDEN);
    let mut qb = [0i8; HIDDEN];
    let mut except: Vec<(u32, i16)> = Vec::new();
    for k in 0..INPUTS * HIDDEN {
        let q = q8(master.w[k]);
        if q > 127 || q < -128 {
            except.push((k as u32, q as i16));
        }
        qw.push(q.clamp(-128, 127) as i8);
    }
    for k in 0..HIDDEN {
        let q = q8(master.b[k]);
        if q > 127 || q < -128 {
            except.push(((INPUTS * HIDDEN + k) as u32, q as i16));
        }
        qb[k] = q.clamp(-128, 127) as i8;
    }
    let mut bytes = Vec::with_capacity(24 + except.len() * 6 + INPUTS * HIDDEN + HIDDEN + (BUCKETS + 1) * HIDDEN * 2 * 2);
    bytes.extend_from_slice(&0x4E4E4541u32.to_le_bytes()); // "AENN"
    bytes.extend_from_slice(&NET_VERSION_I8.to_le_bytes());
    bytes.extend_from_slice(&0u32.to_le_bytes()); // arch 0 (no mirror)
    bytes.extend_from_slice(&(QA_I8 as u32).to_le_bytes());
    bytes.extend_from_slice(&(QV_I8 as u32).to_le_bytes());
    bytes.extend_from_slice(&(except.len() as u32).to_le_bytes());
    for (idx, val) in &except {
        bytes.extend_from_slice(&idx.to_le_bytes());
        bytes.extend_from_slice(&val.to_le_bytes());
    }
    for &x in &qw {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for &x in qb.iter() {
        bytes.extend_from_slice(&x.to_le_bytes());
    }
    for bk in 0..BUCKETS {
        for k in 0..HIDDEN * 2 {
            bytes.extend_from_slice(&((master.v[bk][k] * QV_I8 as f32).round() as i16).to_le_bytes());
        }
    }
    for bk in 0..BUCKETS {
        let cb = master.c[bk] * (QA_I8 * QV_I8) as f32 / SCALE as f32;
        bytes.extend_from_slice(&(cb.round() as i16).to_le_bytes());
    }
    std::fs::write(out_path, &bytes).expect("write net");
    eprintln!(
        "net written to {} ({} bytes, v4 i8: {} FT exceptions)",
        out_path,
        bytes.len(),
        except.len()
    );
}
