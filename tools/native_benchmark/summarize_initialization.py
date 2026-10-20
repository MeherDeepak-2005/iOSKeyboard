#!/usr/bin/env python3
"""Summarize matched mapped-seed setup timings; preserve the earlier baseline."""
import json
import re
import statistics
from pathlib import Path

root = Path(__file__).resolve().parents[2]
results = root / 'tools/evaluation/results/native-initialization'
summary = {
    'date': '2026-10-06',
    'host': {'cpu': 'Apple M2', 'model': 'Mac14,2', 'ram_bytes': 8589934592},
    'production_backend': 'Swift; mapped native seed sessions are internal opt-in paths',
    'physical_iphone': 'not_measured',
    'seed_scope': 'static English corpus without personalization boosts',
    'memory_scope': 'five isolated macOS processes/backend; vocabulary retained throughout each session in all backends; peak RSS includes runtime, transients and resident vocabulary pages; not iPhone RAM',
    'timings': {}, 'macos_peak_rss': {},
    'vocabulary_disk_bytes_unchanged': (root / 'keyboard/langdata.bin').stat().st_size,
}
for platform in ('macos', 'simulator'):
    setup = json.loads((results / f'{platform}-initialization.json').read_text())
    for row in setup['rows']:
        native = row['native_mapped_p50_ms']
        row['native_mapped_vs_swift_speedup'] = row['swift_p50_ms'] / native
        row['native_mapped_vs_swift_latency_reduction_percent'] = 100 * (1 - native / row['swift_p50_ms'])
        if 'native_boxed_p50_ms' in row:
            row['native_mapped_vs_boxed_speedup'] = row['native_boxed_p50_ms'] / native
            row['native_mapped_vs_boxed_latency_reduction_percent'] = 100 * (1 - native / row['native_boxed_p50_ms'])
    summary['timings'][platform] = {
        'initialization': setup,
        'kernels': json.loads((results / f'{platform}-kernels.json').read_text()),
    }
for backend in ('swift', 'native', 'native_mapped'):
    rss = []
    for trial in range(1, 6):
        raw = (results / f'memory-{backend}-{trial}.txt').read_text()
        match = re.search(r'(\d+)\s+maximum resident set size', raw)
        if not match:
            raise ValueError(f'missing Darwin peak RSS: {backend} trial {trial}')
        report = json.loads((results / f'memory-{backend}-{trial}.json').read_text())
        if report['seeds'] != 9228 or report['candidate_count'] != 2:
            raise ValueError(f'unmatched workload: {backend} trial {trial}')
        rss.append(int(match.group(1)))
    summary['macos_peak_rss'][backend] = {'samples_bytes': rss, 'median_bytes': statistics.median(rss)}
for baseline in ('swift', 'native'):
    summary['macos_peak_rss'][f'mapped_minus_{baseline}_median_bytes'] = (
        summary['macos_peak_rss']['native_mapped']['median_bytes'] - summary['macos_peak_rss'][baseline]['median_bytes'])
(results / 'summary.json').write_text(json.dumps(summary, indent=2, sort_keys=True) + '\n')
print(json.dumps({'simulator_initialization': summary['timings']['simulator']['initialization']['rows'],
                  'macos_peak_rss': summary['macos_peak_rss']}, indent=2))
